const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const broker_mod = @import("broker.zig");
const session_mod = @import("session.zig");
const topic = @import("topic.zig");

/// Server configuration
pub const ServerConfig = struct {
    bind_address: []const u8 = "0.0.0.0",
    port: u16 = 1883,
    backlog: u31 = 128,
    recv_buffer_size: usize = 65536,
    send_buffer_size: usize = 65536,
};

/// TCP Server - spawns a thread per connection
pub const Server = struct {
    const Self = @This();

    allocator: Allocator,
    config: ServerConfig,
    broker: *broker_mod.Broker,
    listener: ?std.posix.socket_t = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: Allocator, config: ServerConfig, broker: *broker_mod.Broker) !*Self {
        const server = try allocator.create(Self);
        server.* = .{
            .allocator = allocator,
            .config = config,
            .broker = broker,
        };
        return server;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        const addr = try std.net.Address.parseIp4(self.config.bind_address, self.config.port);

        self.listener = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM,
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

        self.running.store(true, .seq_cst);

        std.debug.print("MQTT broker listening on {s}:{d}\n", .{ self.config.bind_address, self.config.port });
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .seq_cst);
        if (self.listener) |l| {
            std.posix.close(l);
            self.listener = null;
        }
    }

    /// Accept connections in a loop (blocking)
    pub fn acceptLoop(self: *Self) void {
        while (self.running.load(.seq_cst)) {
            const client_socket = std.posix.accept(self.listener.?, null, null, 0) catch |err| {
                if (!self.running.load(.seq_cst)) break;
                std.debug.print("Accept error: {}\n", .{err});
                continue;
            };

            // Spawn connection handler thread
            const thread = std.Thread.spawn(.{}, handleConnectionWrapper, .{ self, client_socket }) catch {
                std.posix.close(client_socket);
                continue;
            };
            thread.detach();
        }
    }

    /// Run server (blocking)
    pub fn run(self: *Self) !void {
        try self.start();
        self.acceptLoop();
    }
};

/// Wrapper for thread spawn
fn handleConnectionWrapper(server: *Server, socket: std.posix.socket_t) void {
    handleConnection(server, socket);
}

/// Handle a single client connection
fn handleConnection(server: *Server, socket: std.posix.socket_t) void {
    var handler = ConnectionHandler.init(server.allocator, server.broker, socket, server.config.recv_buffer_size) catch {
        std.posix.close(socket);
        return;
    };
    defer handler.deinit();

    handler.run() catch |err| {
        std.debug.print("Connection error: {}\n", .{err});
    };

    // Close socket if not already closed by disconnect
    if (handler.connection == null or !handler.connection.?.isDisconnected()) {
        std.posix.close(socket);
    }
}

/// Connection handler - processes packets for a single connection
pub const ConnectionHandler = struct {
    const Self = @This();

    allocator: Allocator,
    broker: *broker_mod.Broker,
    socket: std.posix.socket_t,
    recv_buffer: []u8,
    recv_pos: usize = 0,
    parser: protocol.Parser = .{},
    session: ?*session_mod.Session = null,
    connection: ?broker_mod.Connection = null,
    connected: bool = false,
    clean_disconnect: bool = false, // Set true only when DISCONNECT received
    encode_buffer: [65536]u8 = undefined,

    pub fn init(
        allocator: Allocator,
        broker: *broker_mod.Broker,
        socket: std.posix.socket_t,
        buffer_size: usize,
    ) !Self {
        return .{
            .allocator = allocator,
            .broker = broker,
            .socket = socket,
            .recv_buffer = try allocator.alloc(u8, buffer_size),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.connection) |*conn| {
            self.broker.unregisterConnection(conn);

            // Publish will message if not clean disconnect and not session takeover
            // Session takeover (another client with same ID connected) should not trigger will
            if (self.session) |session| {
                if (!self.clean_disconnect and conn.disconnect_reason != .session_taken_over) {
                    self.broker.publishWill(session);
                }
                self.broker.sessions.maybeRemove(session);
            }
        } else if (self.session) |session| {
            // Connection was never established, clean up session if needed
            self.broker.sessions.maybeRemove(session);
        }

        self.allocator.free(self.recv_buffer);
    }

    pub fn run(self: *Self) !void {
        while (true) {
            // Check if disconnected
            if (self.connection) |*conn| {
                if (conn.isDisconnected()) break;
            }

            // Read data
            const n = std.posix.recv(self.socket, self.recv_buffer[self.recv_pos..], 0) catch |err| {
                if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) break;
                return err;
            };

            if (n == 0) break; // Connection closed

            self.recv_pos += n;
            _ = self.broker.stats.bytes_received.fetchAdd(n, .monotonic);

            // Process complete packets
            try self.processPackets();
        }
    }

    fn processPackets(self: *Self) !void {
        while (self.recv_pos > 0) {
            // Check if we have a complete packet
            const pkt_len = protocol.packetLength(self.recv_buffer[0..self.recv_pos]) catch |err| {
                if (err == error.IncompletePacket) return; // Need more data
                return err;
            };

            if (pkt_len > self.recv_pos) return; // Need more data

            // Parse and handle packet
            const pkt_data = self.recv_buffer[0..pkt_len];
            try self.handlePacket(pkt_data);

            // Shift remaining data
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
            // Second CONNECT is protocol error
            if (self.connection) |*conn| {
                conn.disconnect(.protocol_error);
            }
            return;
        }

        var encoder = protocol.Encoder.init(&self.encode_buffer);

        // Validate client ID
        var client_id = connect.client_id;
        if (client_id.len == 0) {
            if (!connect.flags.clean_session) {
                // Empty client ID with clean_session=0 is rejected
                const pkt = try encoder.connack(false, @intFromEnum(protocol.ConnackReturnCode.identifier_rejected));
                _ = try std.posix.send(self.socket, pkt, 0);
                return;
            }
            // Generate client ID for clean session
            client_id = "auto-generated"; // TODO: generate unique ID
        }

        // Get or create session
        const result = try self.broker.sessions.getOrCreate(client_id, connect.flags.clean_session);
        self.session = result.session;

        // If clean_session=true, clear subscriptions from topic tree and reset session state
        // Must clear topic tree BEFORE calling session.clear() since we need the subscription IDs
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

        // Set up will message
        if (connect.flags.will_flag) {
            if (connect.will_topic) |wt| {
                try self.session.?.setWill(
                    wt,
                    connect.will_payload orelse "",
                    @enumFromInt(connect.flags.will_qos),
                    connect.flags.will_retain,
                    0, // will delay
                );
            }
        }

        // Create connection handle
        self.connection = broker_mod.Connection.init(self.broker, self.session.?, self.socket);
        try self.broker.registerConnection(&self.connection.?);
        self.connected = true;

        // Send CONNACK
        if (connect.protocol_version == .v5_0) {
            const pkt = try encoder.connackV5(result.existed, .success, null);
            _ = try std.posix.send(self.socket, pkt, 0);
        } else {
            const pkt = try encoder.connack(result.existed, 0x00);
            _ = try std.posix.send(self.socket, pkt, 0);
        }

        // Deliver any queued messages for this session (for persistent sessions)
        if (result.existed and !connect.flags.clean_session) {
            self.broker.deliverQueuedMessages(&self.connection.?);
        }
    }

    fn handlePublish(self: *Self, publish: protocol.PublishPacket) !void {
        if (!self.connected or self.session == null) return;

        const session = self.session.?;
        session.last_activity = std.time.timestamp();

        // Validate topic name
        if (!topic.validateTopicName(publish.topic)) {
            if (self.connection) |*conn| {
                conn.disconnect(.topic_name_invalid);
            }
            return;
        }

        var encoder = protocol.Encoder.init(&self.encode_buffer);

        // Extract properties data for v5.0
        const props_data: ?[]const u8 = if (publish.properties) |p| p.data else null;

        switch (publish.qos) {
            .at_most_once => {
                // QoS 0: Just publish
                try self.broker.publishWithProps(session, publish.topic, publish.payload, publish.qos, publish.retain, props_data);
            },
            .at_least_once => {
                // QoS 1: Publish and acknowledge
                try self.broker.publishWithProps(session, publish.topic, publish.payload, publish.qos, publish.retain, props_data);
                const pkt = try encoder.puback(publish.packet_id.?);
                try self.connection.?.sendPacket(pkt);
            },
            .exactly_once => {
                // QoS 2: Check for duplicate, store, send PUBREC
                if (!session.hasIncomingQos2(publish.packet_id.?)) {
                    try session.recordIncomingQos2(publish.packet_id.?);
                    try self.broker.publishWithProps(session, publish.topic, publish.payload, publish.qos, publish.retain, props_data);
                }
                const pkt = try encoder.pubrec(publish.packet_id.?);
                try self.connection.?.sendPacket(pkt);
            },
        }
    }

    fn handlePuback(self: *Self, ack: protocol.AckPacket) void {
        if (self.session) |session| {
            _ = session.acknowledgeOutgoing(ack.packet_id);
        }
    }

    fn handlePubrec(self: *Self, ack: protocol.AckPacket) !void {
        if (self.session == null) return;
        var encoder = protocol.Encoder.init(&self.encode_buffer);
        const pkt = try encoder.pubrel(ack.packet_id);
        try self.connection.?.sendPacket(pkt);
    }

    fn handlePubrel(self: *Self, ack: protocol.AckPacket) !void {
        if (self.session) |session| {
            _ = session.completeIncomingQos2(ack.packet_id);
        }
        var encoder = protocol.Encoder.init(&self.encode_buffer);
        const pkt = try encoder.pubcomp(ack.packet_id);
        try self.connection.?.sendPacket(pkt);
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
        try self.connection.?.sendPacket(pkt);
    }

    fn handleUnsubscribe(self: *Self, unsub: protocol.UnsubscribePacket) !void {
        if (!self.connected or self.session == null) return;

        const session = self.session.?;
        session.last_activity = std.time.timestamp();

        // For v5.0, we need reason codes for each filter
        var reason_codes: [64]u8 = undefined;
        var i: usize = 0;
        for (unsub.filters) |filter| {
            if (i >= reason_codes.len) break;
            // 0x00 = Success, 0x11 = No subscription existed
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
        try self.connection.?.sendPacket(pkt);
    }

    fn handlePingreq(self: *Self) !void {
        if (self.session) |session| {
            session.last_activity = std.time.timestamp();
        }
        var encoder = protocol.Encoder.init(&self.encode_buffer);
        const pkt = try encoder.pingresp();
        try self.connection.?.sendPacket(pkt);
    }

    fn handleDisconnect(self: *Self, disc: protocol.DisconnectPacket) void {
        _ = disc;
        self.clean_disconnect = true; // Mark as clean disconnect
        if (self.session) |session| {
            session.clearWill(); // Clean disconnect = no will
        }
        if (self.connection) |*conn| {
            conn.disconnect(.success); // success = normal_disconnection
        }
    }

    fn handleAuth(_: *Self, _: protocol.AuthPacket) !void {
        // AUTH packet handling for v5.0 enhanced authentication
        // TODO: Implement enhanced auth when needed
    }
};

// Tests
test "Server init/deinit" {
    const broker = try broker_mod.Broker.init(std.testing.allocator, .{});
    defer broker.deinit();

    const server = try Server.init(std.testing.allocator, .{}, broker);
    defer server.deinit();
}
