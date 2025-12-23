const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const broker_mod = @import("broker.zig");
const session_mod = @import("session.zig");
const topic = @import("topic.zig");
const io = @import("io/backend.zig");

/// Server configuration
pub const ServerConfig = struct {
    bind_address: []const u8 = "0.0.0.0",
    port: u16 = 1883,
    backlog: u31 = 4096,
    recv_buffer_size: usize = 65536,
    max_events: u32 = 4096,
    workers: u32 = 0, // 0 = auto-detect CPU count
};

/// TCP Server - event-driven with io_uring/epoll backend
pub const Server = struct {
    const Self = @This();
    const LISTENER_ID: usize = 0;

    allocator: Allocator,
    config: ServerConfig,
    broker: *broker_mod.Broker,
    listener: ?std.posix.socket_t = null,
    backend: ?io.Backend = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Connection management
    connections: std.AutoHashMap(std.posix.socket_t, *ConnectionHandler),
    next_conn_id: usize = 1,

    // Event buffer
    events: []io.Event,

    pub fn init(allocator: Allocator, config: ServerConfig, broker: *broker_mod.Broker) !*Self {
        const server = try allocator.create(Self);
        errdefer allocator.destroy(server);

        const events = try allocator.alloc(io.Event, config.max_events);
        errdefer allocator.free(events);

        server.* = .{
            .allocator = allocator,
            .config = config,
            .broker = broker,
            .connections = std.AutoHashMap(std.posix.socket_t, *ConnectionHandler).init(allocator),
            .events = events,
        };

        return server;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        // Clean up all connections
        var it = self.connections.valueIterator();
        while (it.next()) |handler| {
            handler.*.deinit();
            self.allocator.destroy(handler.*);
        }
        self.connections.deinit();

        self.allocator.free(self.events);
        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        // Initialize I/O backend (io_uring with epoll fallback)
        self.backend = try io.detectBest(self.allocator, self.config.max_events);
        errdefer if (self.backend) |b| b.deinit();

        // Create listener socket
        const addr = try std.net.Address.parseIp4(self.config.bind_address, self.config.port);

        self.listener = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
            0,
        );
        errdefer if (self.listener) |l| std.posix.close(l);

        // Set SO_REUSEADDR
        try std.posix.setsockopt(
            self.listener.?,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        );

        try std.posix.bind(self.listener.?, @ptrCast(&addr.any), addr.getOsSockLen());
        try std.posix.listen(self.listener.?, self.config.backlog);

        // Add listener to backend for accept events
        try self.backend.?.addSocket(self.listener.?, LISTENER_ID);

        self.running.store(true, .seq_cst);

        std.debug.print("MQTT broker listening on {s}:{d} (backend: {s})\n", .{
            self.config.bind_address,
            self.config.port,
            self.backend.?.name(),
        });
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .seq_cst);
        if (self.backend) |b| {
            b.deinit();
            self.backend = null;
        }
        if (self.listener) |l| {
            std.posix.close(l);
            self.listener = null;
        }
    }

    /// Main event loop
    pub fn eventLoop(self: *Self) void {
        while (self.running.load(.seq_cst)) {
            const ready = self.backend.?.wait(self.events, 100) catch |err| {
                if (!self.running.load(.seq_cst)) break;
                std.debug.print("Event wait error: {}\n", .{err});
                continue;
            };

            for (ready) |event| {
                if (event.user_data == LISTENER_ID) {
                    // Accept new connections
                    self.handleAccept();
                } else {
                    // Handle client event
                    self.handleClientEvent(event);
                }
            }
        }
    }

    fn handleAccept(self: *Self) void {
        // Accept all pending connections
        while (true) {
            const client_socket = std.posix.accept(
                self.listener.?,
                null,
                null,
                std.posix.SOCK.NONBLOCK,
            ) catch |err| {
                if (err == error.WouldBlock) break;
                std.debug.print("Accept error: {}\n", .{err});
                break;
            };

            // Create connection handler
            const handler = ConnectionHandler.init(
                self.allocator,
                self.broker,
                client_socket,
                self.config.recv_buffer_size,
            ) catch {
                std.posix.close(client_socket);
                continue;
            };

            const conn_id = self.next_conn_id;
            self.next_conn_id +%= 1;
            if (self.next_conn_id == LISTENER_ID) self.next_conn_id = 1;

            handler.conn_id = conn_id;

            self.connections.put(client_socket, handler) catch {
                handler.deinit();
                self.allocator.destroy(handler);
                std.posix.close(client_socket);
                continue;
            };

            // Add to backend for read events
            self.backend.?.addSocket(client_socket, conn_id) catch {
                _ = self.connections.remove(client_socket);
                handler.deinit();
                self.allocator.destroy(handler);
                std.posix.close(client_socket);
                continue;
            };
        }
    }

    fn handleClientEvent(self: *Self, event: io.Event) void {
        const handler = self.connections.get(event.socket) orelse return;

        // Idempotency check - skip if already being closed (io_uring batched events)
        if (handler.closed) return;

        // Verify conn_id matches - socket descriptors can be reused, so stale events
        // from old connections may arrive for a new connection on the same fd
        if (event.user_data != handler.conn_id) return;

        switch (event.event_type) {
            .read => {
                handler.handleRead() catch |err| {
                    if (err != error.WouldBlock) {
                        self.closeConnection(event.socket, handler);
                        return;
                    }
                };
            },
            .write => {
                handler.handleWrite() catch {
                    self.closeConnection(event.socket, handler);
                    return;
                };
            },
            .close, .error_event => {
                self.closeConnection(event.socket, handler);
                return;
            },
        }

        // Check if connection was closed by protocol
        if (handler.connection) |*conn| {
            if (conn.isDisconnected()) {
                self.closeConnection(event.socket, handler);
            }
        }
    }

    fn closeConnection(self: *Self, socket: std.posix.socket_t, handler: *ConnectionHandler) void {
        // Idempotency - prevent double-close from batched events
        if (handler.closed) return;
        handler.closed = true;

        self.backend.?.removeSocket(socket);
        _ = self.connections.remove(socket);
        handler.deinit();
        self.allocator.destroy(handler);
        // Use raw syscall - std.posix.close panics on BADF which can happen
        // with io_uring batched events (multiple events for same socket)
        _ = std.os.linux.close(socket);
    }

    /// Run server (blocking)
    pub fn run(self: *Self) !void {
        try self.start();
        self.eventLoop();
    }
};

/// Connection handler - processes packets for a single connection
pub const ConnectionHandler = struct {
    const Self = @This();

    allocator: Allocator,
    broker: *broker_mod.Broker,
    socket: std.posix.socket_t,
    recv_buffer: []u8,
    recv_pos: usize = 0,
    send_buffer: std.ArrayListUnmanaged(u8) = .{},
    send_pos: usize = 0,
    parser: protocol.Parser = .{},
    session: ?*session_mod.Session = null,
    connection: ?broker_mod.Connection = null,
    connected: bool = false,
    clean_disconnect: bool = false,
    closed: bool = false, // Idempotency flag for io_uring batched events
    encode_buffer: [65536]u8 = undefined,
    conn_id: usize = 0,

    pub fn init(
        allocator: Allocator,
        broker: *broker_mod.Broker,
        socket: std.posix.socket_t,
        buffer_size: usize,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .broker = broker,
            .socket = socket,
            .recv_buffer = try allocator.alloc(u8, buffer_size),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.connection) |*conn| {
            self.broker.unregisterConnection(conn);

            if (self.session) |session| {
                // Don't publish will or remove session during session takeover -
                // the new connection is using this session
                if (conn.disconnect_reason != .session_taken_over) {
                    if (!self.clean_disconnect) {
                        self.broker.publishWill(session);
                    }
                    self.broker.sessions.maybeRemove(session);
                }
            }
        } else if (self.session) |session| {
            self.broker.sessions.maybeRemove(session);
        }

        self.allocator.free(self.recv_buffer);
        self.send_buffer.deinit(self.allocator);
    }

    /// Handle read-ready event
    pub fn handleRead(self: *Self) !void {
        while (true) {
            if (self.recv_pos >= self.recv_buffer.len) {
                // Buffer full, can't read more
                return error.BufferFull;
            }

            // Use raw syscall to handle EBADF gracefully (can happen with io_uring batched events)
            const buf = self.recv_buffer[self.recv_pos..];
            const rc = std.os.linux.recvfrom(self.socket, buf.ptr, buf.len, 0, null, null);
            if (rc == 0) return error.ConnectionClosed;

            if (@as(isize, @bitCast(rc)) < 0) {
                const err: std.posix.E = @enumFromInt(@as(u16, @truncate(@as(usize, @bitCast(-@as(isize, @bitCast(rc)))))));
                return switch (err) {
                    .AGAIN => return, // WouldBlock
                    .BADF, .NOTCONN, .NOTSOCK => error.ConnectionClosed, // Socket already closed
                    .CONNRESET, .CONNREFUSED => error.ConnectionReset,
                    .INTR => continue,
                    else => error.RecvError,
                };
            }

            const n: usize = rc;
            self.recv_pos += n;
            _ = self.broker.stats.bytes_received.fetchAdd(n, .monotonic);

            // Process complete packets
            try self.processPackets();
        }
    }

    /// Handle write-ready event
    pub fn handleWrite(self: *Self) !void {
        while (self.send_pos < self.send_buffer.items.len) {
            const buf = self.send_buffer.items[self.send_pos..];
            const rc = std.os.linux.sendto(self.socket, buf.ptr, buf.len, 0, null, 0);

            if (@as(isize, @bitCast(rc)) < 0) {
                const err: std.posix.E = @enumFromInt(@as(u16, @truncate(@as(usize, @bitCast(-@as(isize, @bitCast(rc)))))));
                return switch (err) {
                    .AGAIN => return, // WouldBlock
                    .BADF, .NOTCONN, .NOTSOCK, .PIPE => error.ConnectionClosed,
                    .CONNRESET, .CONNREFUSED => error.ConnectionReset,
                    .INTR => continue,
                    else => error.SendError,
                };
            }

            self.send_pos += rc;
        }

        // All data sent, clear buffer
        self.send_buffer.clearRetainingCapacity();
        self.send_pos = 0;
    }

    /// Queue data to be sent
    pub fn queueSend(self: *Self, data: []const u8) !void {
        try self.send_buffer.appendSlice(self.allocator, data);
        // Try to send immediately
        self.handleWrite() catch {};
    }

    fn processPackets(self: *Self) !void {
        while (self.recv_pos > 0) {
            const pkt_len = protocol.packetLength(self.recv_buffer[0..self.recv_pos]) catch |err| {
                if (err == error.IncompletePacket) return;
                return err;
            };

            if (pkt_len > self.recv_pos) return;

            const pkt_data = self.recv_buffer[0..pkt_len];
            try self.handlePacket(pkt_data);

            if (pkt_len < self.recv_pos) {
                std.mem.copyForwards(u8, self.recv_buffer, self.recv_buffer[pkt_len..self.recv_pos]);
            }
            self.recv_pos -= pkt_len;
        }
    }

    fn handlePacket(self: *Self, data: []const u8) !void {
        const packet = self.parser.parse(data) catch |err| {
            std.debug.print("Parse error: {}\n", .{err});
            return err;
        };

        switch (packet) {
            .connect => |connect| try self.handleConnect(connect),
            .publish => |publish| try self.handlePublish(publish),
            .puback => |ack| self.handlePuback(ack),
            .pubrec => |ack| try self.handlePubrec(ack),
            .pubrel => |ack| try self.handlePubrel(ack),
            .pubcomp => |ack| self.handlePubcomp(ack),
            .subscribe => |sub| try self.handleSubscribe(sub),
            .unsubscribe => |unsub| try self.handleUnsubscribe(unsub),
            .pingreq => try self.handlePingreq(),
            .disconnect => |disc| self.handleDisconnect(disc),
            .auth => |auth| try self.handleAuth(auth),
            else => {},
        }
    }

    fn handleConnect(self: *Self, connect: protocol.ConnectPacket) !void {
        if (self.connected) {
            if (self.connection) |*conn| {
                conn.disconnect(.protocol_error);
            }
            return;
        }

        var encoder = protocol.Encoder.init(&self.encode_buffer);

        var client_id = connect.client_id;
        if (client_id.len == 0) {
            if (!connect.flags.clean_session) {
                const pkt = try encoder.connack(false, @intFromEnum(protocol.ConnackReturnCode.identifier_rejected));
                try self.queueSend(pkt);
                return;
            }
            client_id = "auto-generated";
        }

        const result = try self.broker.sessions.getOrCreate(client_id, connect.flags.clean_session);
        self.session = result.session;

        if (connect.flags.clean_session) {
            self.broker.clearSessionSubscriptions(self.session.?);
            self.session.?.clear();
        }

        self.session.?.clean_session = connect.flags.clean_session;
        self.session.?.protocol_version = connect.protocol_version;
        self.session.?.keep_alive = connect.keep_alive;
        self.session.?.connected = true;
        self.session.?.last_activity = std.time.timestamp();
        self.parser.version = connect.protocol_version;

        if (connect.flags.will_flag) {
            if (connect.will_topic) |wt| {
                try self.session.?.setWill(
                    wt,
                    connect.will_payload orelse "",
                    @enumFromInt(connect.flags.will_qos),
                    connect.flags.will_retain,
                    0,
                );
            }
        }

        self.connection = broker_mod.Connection.init(self.broker, self.session.?, self.socket);
        try self.broker.registerConnection(&self.connection.?);
        self.connected = true;

        if (connect.protocol_version == .v5_0) {
            const pkt = try encoder.connackV5(result.existed, .success, null);
            try self.queueSend(pkt);
        } else {
            const pkt = try encoder.connack(result.existed, 0x00);
            try self.queueSend(pkt);
        }

        if (result.existed and !connect.flags.clean_session) {
            self.broker.deliverQueuedMessages(&self.connection.?);
        }
    }

    fn handlePublish(self: *Self, publish: protocol.PublishPacket) !void {
        if (!self.connected or self.session == null) return;

        const session = self.session.?;
        session.last_activity = std.time.timestamp();

        if (!topic.validateTopicName(publish.topic)) {
            if (self.connection) |*conn| {
                conn.disconnect(.topic_name_invalid);
            }
            return;
        }

        var encoder = protocol.Encoder.init(&self.encode_buffer);
        const props_data: ?[]const u8 = if (publish.properties) |p| p.data else null;

        switch (publish.qos) {
            .at_most_once => {
                try self.broker.publishWithProps(session, publish.topic, publish.payload, publish.qos, publish.retain, props_data);
            },
            .at_least_once => {
                try self.broker.publishWithProps(session, publish.topic, publish.payload, publish.qos, publish.retain, props_data);
                const pkt = try encoder.puback(publish.packet_id.?);
                try self.queueSend(pkt);
            },
            .exactly_once => {
                if (!session.hasIncomingQos2(publish.packet_id.?)) {
                    try session.recordIncomingQos2(publish.packet_id.?);
                    try self.broker.publishWithProps(session, publish.topic, publish.payload, publish.qos, publish.retain, props_data);
                }
                const pkt = try encoder.pubrec(publish.packet_id.?);
                try self.queueSend(pkt);
            },
        }
    }

    fn handlePuback(self: *Self, ack: protocol.AckPacket) void {
        if (self.session) |session| {
            _ = session.acknowledgeOutgoing(ack.packet_id);
        }
    }

    fn handlePubrec(self: *Self, ack: protocol.AckPacket) !void {
        const session = self.session orelse return;
        // Only send PUBREL if we have this packet in pending_outgoing (QoS 2 state machine)
        if (!session.updateOutgoingQos2State(ack.packet_id)) return;
        var encoder = protocol.Encoder.init(&self.encode_buffer);
        const pkt = try encoder.pubrel(ack.packet_id);
        try self.queueSend(pkt);
    }

    fn handlePubrel(self: *Self, ack: protocol.AckPacket) !void {
        if (self.session) |session| {
            _ = session.completeIncomingQos2(ack.packet_id);
        }
        var encoder = protocol.Encoder.init(&self.encode_buffer);
        const pkt = try encoder.pubcomp(ack.packet_id);
        try self.queueSend(pkt);
    }

    fn handlePubcomp(self: *Self, ack: protocol.AckPacket) void {
        if (self.session) |session| {
            _ = session.acknowledgeOutgoing(ack.packet_id);
        }
    }

    fn handleSubscribe(self: *Self, sub: protocol.SubscribePacket) !void {
        if (!self.connected or self.session == null) return;

        const session = self.session.?;
        session.last_activity = std.time.timestamp();

        const return_codes = try self.broker.subscribe(session, sub.filters, sub.properties);
        defer self.allocator.free(return_codes);

        var encoder = protocol.Encoder.init(&self.encode_buffer);
        const pkt = if (session.protocol_version == .v5_0)
            try encoder.subackV5(sub.packet_id, return_codes, null)
        else
            try encoder.suback(sub.packet_id, return_codes);
        try self.queueSend(pkt);
    }

    fn handleUnsubscribe(self: *Self, unsub: protocol.UnsubscribePacket) !void {
        if (!self.connected or self.session == null) return;

        const session = self.session.?;
        session.last_activity = std.time.timestamp();

        var reason_codes: [64]u8 = undefined;
        var i: usize = 0;
        for (unsub.filters) |filter| {
            if (i >= reason_codes.len) break;
            reason_codes[i] = if (session.removeSubscription(filter)) |sub_id| blk: {
                _ = self.broker.topic_tree.unsubscribe(filter, sub_id);
                break :blk 0x00;
            } else 0x11;
            i += 1;
        }

        var encoder = protocol.Encoder.init(&self.encode_buffer);
        const pkt = if (session.protocol_version == .v5_0)
            try encoder.unsubackV5(unsub.packet_id, reason_codes[0..i], null)
        else
            try encoder.unsuback(unsub.packet_id);
        try self.queueSend(pkt);
    }

    fn handlePingreq(self: *Self) !void {
        if (self.session) |session| {
            session.last_activity = std.time.timestamp();
        }
        var encoder = protocol.Encoder.init(&self.encode_buffer);
        const pkt = try encoder.pingresp();
        try self.queueSend(pkt);
    }

    fn handleDisconnect(self: *Self, disc: protocol.DisconnectPacket) void {
        _ = disc;
        self.clean_disconnect = true;
        if (self.session) |session| {
            session.clearWill();
        }
        if (self.connection) |*conn| {
            conn.disconnect(.success);
        }
    }

    fn handleAuth(_: *Self, _: protocol.AuthPacket) !void {
        // TODO: Implement enhanced auth when needed
    }
};

// Tests
test "Server init/deinit" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const broker = try broker_mod.Broker.init(std.testing.allocator, .{});
    defer broker.deinit();

    const server = try Server.init(std.testing.allocator, .{}, broker);
    defer server.deinit();
}
