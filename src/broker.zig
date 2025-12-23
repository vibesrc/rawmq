const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const topic_mod = @import("topic.zig");
const session_mod = @import("session.zig");

/// Broker configuration
pub const Config = struct {
    max_connections: u32 = 10000,
    max_packet_size: u32 = 256 * 1024 * 1024, // 256MB
    max_inflight_messages: u16 = 65535,
    default_keep_alive: u16 = 60,
    max_keep_alive: u16 = 65535,
    allow_anonymous: bool = true,
    max_qos: protocol.QoS = .exactly_once,
    retain_available: bool = true,
    wildcard_subscription_available: bool = true,
    subscription_identifier_available: bool = true,
    shared_subscription_available: bool = true,
    // Thread pool size (0 = auto-detect CPU count)
    worker_threads: u32 = 0,
};

/// Retained message
pub const RetainedMessage = struct {
    topic: []const u8,
    payload: []const u8,
    qos: protocol.QoS,
    timestamp: i64,
};

/// Message to be delivered to a client
pub const DeliveryMessage = struct {
    topic: []const u8,
    payload: []const u8,
    qos: protocol.QoS,
    retain: bool,
    packet_id: u16,
};

/// Broker - central coordinator for message routing
pub const Broker = struct {
    const Self = @This();

    allocator: Allocator,
    config: Config,

    // Topic tree for subscription matching
    topic_tree: topic_mod.TopicTree,

    // Session store
    sessions: session_mod.SessionStore,

    // Retained messages (topic -> message)
    retained: std.StringHashMapUnmanaged(RetainedMessage) = .{},
    retained_lock: std.Thread.RwLock = .{},

    // Connected clients (client_id -> connection handle)
    connections: std.StringHashMapUnmanaged(*Connection) = .{},
    connections_lock: std.Thread.RwLock = .{},

    // Statistics
    stats: Stats = .{},

    pub const Stats = struct {
        total_connections: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        messages_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        messages_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        bytes_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        bytes_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    };

    pub fn init(allocator: Allocator, config: Config) !*Self {
        const broker = try allocator.create(Self);
        broker.* = .{
            .allocator = allocator,
            .config = config,
            .topic_tree = try topic_mod.TopicTree.init(allocator),
            .sessions = session_mod.SessionStore.init(allocator),
        };
        return broker;
    }

    pub fn deinit(self: *Self) void {
        // Clean up retained messages
        self.retained_lock.lock();
        var ret_it = self.retained.iterator();
        while (ret_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.payload);
        }
        self.retained.deinit(self.allocator);
        self.retained_lock.unlock();

        // Clean up connections
        self.connections_lock.lock();
        self.connections.deinit(self.allocator);
        self.connections_lock.unlock();

        self.topic_tree.deinit();
        self.sessions.deinit();
        self.allocator.destroy(self);
    }

    /// Register a new connection
    pub fn registerConnection(self: *Self, conn: *Connection) !void {
        self.connections_lock.lock();
        defer self.connections_lock.unlock();

        // Use stored client_id copy to avoid dangling session pointer issues
        const client_id = conn.clientId();

        // Check if client already connected
        if (self.connections.get(client_id)) |existing| {
            // Disconnect existing connection (session takeover)
            existing.disconnect(.session_taken_over);
            // IMPORTANT: Remove old entry first! HashMap.put keeps the OLD key pointer,
            // which would become dangling when the old connection is freed.
            _ = self.connections.remove(client_id);
        }

        try self.connections.put(self.allocator, client_id, conn);
        _ = self.stats.active_connections.fetchAdd(1, .monotonic);
        _ = self.stats.total_connections.fetchAdd(1, .monotonic);
    }

    /// Unregister a connection
    pub fn unregisterConnection(self: *Self, conn: *Connection) void {
        self.connections_lock.lock();
        defer self.connections_lock.unlock();

        // Use stored client_id (not session pointer) to avoid dangling pointer issues
        const client_id = conn.clientId();

        // Only remove if this connection is still the registered one
        // (avoids removing a new connection after session takeover)
        if (self.connections.get(client_id)) |registered| {
            if (registered == conn) {
                _ = self.connections.remove(client_id);
                _ = self.stats.active_connections.fetchSub(1, .monotonic);
            }
        }
    }

    /// Subscribe a client to topics
    pub fn subscribe(
        self: *Self,
        session: *session_mod.Session,
        filters: []const protocol.TopicFilter,
        properties: ?protocol.Properties,
    ) ![]u8 {
        var return_codes = try self.allocator.alloc(u8, filters.len);

        // Extract subscription identifier from properties (v5.0)
        var subscription_id: ?u32 = null;
        if (properties) |props| {
            var iter = props.iterator();
            while (iter.next()) |prop| {
                if (prop.id == .subscription_identifier) {
                    subscription_id = prop.value.var_int;
                    break;
                }
            }
        }

        for (filters, 0..) |filter, i| {
            if (!topic_mod.validateTopicFilter(filter.filter)) {
                return_codes[i] = 0x80; // Failure
                continue;
            }

            // Check QoS limit
            const granted_qos: protocol.QoS = @enumFromInt(@min(@intFromEnum(filter.qos), @intFromEnum(self.config.max_qos)));

            // Add to session
            const sub_id = try session.addSubscription(
                filter.filter,
                granted_qos,
                filter.no_local,
                filter.retain_as_published,
                filter.retain_handling,
            );

            // Add to topic tree
            try self.topic_tree.subscribe(filter.filter, sub_id, .{
                .client_id = session.client_id,
                .qos = @intFromEnum(granted_qos),
                .no_local = filter.no_local,
                .retain_as_published = filter.retain_as_published,
                .retain_handling = filter.retain_handling,
                .subscription_id = subscription_id,
            });

            return_codes[i] = @intFromEnum(granted_qos);

            // Send retained messages if applicable
            if (filter.retain_handling != 2) { // 2 = don't send retained
                self.sendRetainedMessages(session, filter.filter);
            }
        }

        return return_codes;
    }

    /// Unsubscribe a client from topics
    pub fn unsubscribe(
        self: *Self,
        session: *session_mod.Session,
        filters: []const []const u8,
    ) void {
        for (filters) |filter| {
            if (session.removeSubscription(filter)) |sub_id| {
                _ = self.topic_tree.unsubscribe(filter, sub_id);
            }
        }
    }

    /// Publish a message
    pub fn publish(
        self: *Self,
        publisher_session: ?*session_mod.Session,
        pkt_topic: []const u8,
        payload: []const u8,
        qos: protocol.QoS,
        retain: bool,
    ) !void {
        return self.publishWithProps(publisher_session, pkt_topic, payload, qos, retain, null);
    }

    /// Publish a message with v5.0 properties
    pub fn publishWithProps(
        self: *Self,
        publisher_session: ?*session_mod.Session,
        pkt_topic: []const u8,
        payload: []const u8,
        qos: protocol.QoS,
        retain: bool,
        properties: ?[]const u8,
    ) !void {
        _ = self.stats.messages_received.fetchAdd(1, .monotonic);

        // Handle retained message
        if (retain and self.config.retain_available) {
            try self.storeRetainedMessage(pkt_topic, payload, qos);
        }

        // Route to subscribers
        const publisher_client_id = if (publisher_session) |s| s.client_id else null;
        const ctx = RouteContext{
            .broker = self,
            .topic = pkt_topic,
            .payload = payload,
            .publisher_client_id = publisher_client_id,
            .original_retain = retain,
            .properties = properties,
        };

        self.topic_tree.match(pkt_topic, ctx, routeCallback);
    }

    const RouteContext = struct {
        broker: *Self,
        topic: []const u8,
        payload: []const u8,
        publisher_client_id: ?[]const u8,
        original_retain: bool,
        properties: ?[]const u8, // v5.0 properties to forward
    };

    fn routeCallback(ctx: RouteContext, _: topic_mod.TopicTree.SubscriptionId, sub_data: topic_mod.TopicTree.SubscriptionData) void {
        // Skip if no_local and same client
        if (sub_data.no_local) {
            if (ctx.publisher_client_id) |pub_id| {
                if (std.mem.eql(u8, pub_id, sub_data.client_id)) return;
            }
        }

        const deliver_qos: protocol.QoS = @enumFromInt(@min(sub_data.qos, @intFromEnum(protocol.QoS.exactly_once)));

        // Per MQTT-3.8.3-4: If Retain As Published is 1, preserve the original RETAIN flag
        // Otherwise, MQTT-3.3.1-9 says RETAIN should be 0 for established subscriptions
        const deliver_retain = sub_data.retain_as_published and ctx.original_retain;

        // Get connection and deliver
        ctx.broker.connections_lock.lockShared();
        const conn = ctx.broker.connections.get(sub_data.client_id);
        ctx.broker.connections_lock.unlockShared();

        if (conn) |c| {
            // Build properties with subscription identifier if present
            var props_buf: [256]u8 = undefined;
            var props_data: ?[]const u8 = null;

            if (sub_data.subscription_id != null or ctx.properties != null) {
                var pos: usize = 0;

                // Add subscription identifier if present
                if (sub_data.subscription_id) |sub_id| {
                    props_buf[pos] = 0x0B; // Subscription Identifier property ID
                    pos += 1;
                    pos += protocol.encodeVarInt(sub_id, props_buf[pos..]);
                }

                // Forward original properties
                if (ctx.properties) |p| {
                    if (pos + p.len <= props_buf.len) {
                        @memcpy(props_buf[pos..][0..p.len], p);
                        pos += p.len;
                    }
                }

                if (pos > 0) {
                    props_data = props_buf[0..pos];
                }
            }

            c.deliverMessageWithProps(ctx.topic, ctx.payload, deliver_qos, deliver_retain, props_data) catch {};
        } else {
            // Client is offline - queue the message if QoS > 0 and session exists
            if (deliver_qos != .at_most_once) {
                if (ctx.broker.sessions.get(sub_data.client_id)) |session| {
                    if (!session.clean_session) {
                        // Queue the message for later delivery
                        _ = session.queueOutgoingMessage(ctx.topic, ctx.payload, deliver_qos, deliver_retain) catch {};
                    }
                }
            }
        }
    }

    fn storeRetainedMessage(self: *Self, pkt_topic: []const u8, payload: []const u8, qos: protocol.QoS) !void {
        self.retained_lock.lock();
        defer self.retained_lock.unlock();

        if (payload.len == 0) {
            // Empty payload = delete retained message
            if (self.retained.fetchRemove(pkt_topic)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.payload);
            }
        } else {
            // Store/update retained message
            if (self.retained.getEntry(pkt_topic)) |entry| {
                // Update existing
                self.allocator.free(entry.value_ptr.payload);
                entry.value_ptr.payload = try self.allocator.dupe(u8, payload);
                entry.value_ptr.qos = qos;
                entry.value_ptr.timestamp = std.time.timestamp();
            } else {
                // New retained message
                const key = try self.allocator.dupe(u8, pkt_topic);
                try self.retained.put(self.allocator, key, .{
                    .topic = key,
                    .payload = try self.allocator.dupe(u8, payload),
                    .qos = qos,
                    .timestamp = std.time.timestamp(),
                });
            }
        }
    }

    fn sendRetainedMessages(self: *Self, session: *session_mod.Session, filter: []const u8) void {
        self.retained_lock.lockShared();
        defer self.retained_lock.unlockShared();

        self.connections_lock.lockShared();
        const conn = self.connections.get(session.client_id);
        self.connections_lock.unlockShared();

        if (conn == null) return;

        var it = self.retained.iterator();
        while (it.next()) |entry| {
            if (topic_mod.topicMatchesFilter(entry.key_ptr.*, filter)) {
                conn.?.deliverMessage(
                    entry.value_ptr.topic,
                    entry.value_ptr.payload,
                    entry.value_ptr.qos,
                    true, // retain flag
                ) catch {};
            }
        }
    }

    /// Publish will message for a client
    pub fn publishWill(self: *Self, session: *session_mod.Session) void {
        if (session.will) |will| {
            self.publish(null, will.topic, will.payload, will.qos, will.retain) catch {};
        }
    }

    /// Clear all subscriptions for a session from the topic tree
    pub fn clearSessionSubscriptions(self: *Self, session: *session_mod.Session) void {
        // Remove all subscriptions from the topic tree
        self.topic_tree.removeClient(session.subscription_ids.items);
    }

    /// Deliver queued messages to a reconnected client
    pub fn deliverQueuedMessages(self: *Self, conn: *Connection) void {
        const session = conn.session;

        // Re-send pending outgoing messages (QoS 1/2 that weren't acknowledged)
        var it = session.pending_outgoing.iterator();
        while (it.next()) |entry| {
            const msg = entry.value_ptr.*;
            const is_dup = msg.state == .sent or msg.state == .pubrel_sent;

            var buf: [65536]u8 = undefined;
            var encoder = protocol.Encoder.init(&buf);

            if (msg.state == .pubrel_sent) {
                // QoS 2: we sent PUBREL, client didn't get it, resend
                const pkt = encoder.pubrel(msg.packet_id) catch continue;
                conn.sendPacket(pkt) catch continue;
            } else {
                // Resend the PUBLISH
                const pkt = encoder.publish(msg.topic, msg.payload, msg.qos, msg.retain, is_dup, msg.packet_id) catch continue;
                conn.sendPacket(pkt) catch continue;
                entry.value_ptr.state = .sent;
            }

            _ = self.stats.messages_sent.fetchAdd(1, .monotonic);
        }
    }
};

/// Connection handle - represents a connected client
pub const Connection = struct {
    const Self = @This();

    broker: *Broker,
    session: *session_mod.Session,
    socket: std.posix.socket_t,
    // Store client_id directly to avoid dangling session pointer during unregister
    client_id_buf: [256]u8 = undefined,
    client_id_len: u8 = 0,
    send_lock: std.Thread.Mutex = .{},
    disconnected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    disconnect_reason: protocol.ReasonCode = .success, // success = normal_disconnection = 0x00

    pub fn init(broker: *Broker, session: *session_mod.Session, socket: std.posix.socket_t) Self {
        var conn = Self{
            .broker = broker,
            .session = session,
            .socket = socket,
        };
        // Copy client_id to avoid dangling pointer issues
        const len: u8 = @intCast(@min(session.client_id.len, 256));
        @memcpy(conn.client_id_buf[0..len], session.client_id[0..len]);
        conn.client_id_len = len;
        return conn;
    }

    pub fn clientId(self: *const Self) []const u8 {
        return self.client_id_buf[0..self.client_id_len];
    }

    pub fn disconnect(self: *Self, reason: protocol.ReasonCode) void {
        if (self.disconnected.swap(true, .seq_cst)) return; // Already disconnected
        self.disconnect_reason = reason;
        // Shutdown socket to signal disconnect - use raw syscalls as these may race
        // with the event loop's close (io_uring batched events)
        _ = std.os.linux.shutdown(self.socket, std.os.linux.SHUT.RDWR);
        _ = std.os.linux.close(self.socket);
    }

    pub fn isDisconnected(self: *Self) bool {
        return self.disconnected.load(.seq_cst);
    }

    /// Deliver a message to this client
    pub fn deliverMessage(
        self: *Self,
        pkt_topic: []const u8,
        payload: []const u8,
        qos: protocol.QoS,
        retain: bool,
    ) !void {
        return self.deliverMessageWithProps(pkt_topic, payload, qos, retain, null);
    }

    /// Deliver a message with optional v5.0 properties
    pub fn deliverMessageWithProps(
        self: *Self,
        pkt_topic: []const u8,
        payload: []const u8,
        qos: protocol.QoS,
        retain: bool,
        props: ?[]const u8,
    ) !void {
        if (self.isDisconnected()) return;

        var buf: [65536]u8 = undefined;
        var encoder = protocol.Encoder.init(&buf);

        // For QoS 1/2, track the message in pending_outgoing for acknowledgment
        const packet_id: ?u16 = if (qos != .at_most_once) blk: {
            const id = self.session.generatePacketId();
            // Track for acknowledgment - use empty topic/payload since we don't need to resend
            // (the message is already being sent, we just need to track the packet_id)
            self.session.pending_outgoing.put(self.broker.allocator, id, .{
                .packet_id = id,
                .topic = "", // Don't dupe - just tracking packet_id for ack
                .payload = "",
                .qos = qos,
                .retain = retain,
                .timestamp = std.time.timestamp(),
                .state = .sent,
            }) catch {};
            break :blk id;
        } else null;

        const pkt = if (self.session.protocol_version == .v5_0)
            try encoder.publishV5(pkt_topic, payload, qos, retain, false, packet_id, props)
        else
            try encoder.publish(pkt_topic, payload, qos, retain, false, packet_id);

        self.send_lock.lock();
        defer self.send_lock.unlock();

        _ = std.posix.send(self.socket, pkt, 0) catch |err| {
            if (err == error.BrokenPipe or err == error.ConnectionResetByPeer) {
                self.disconnect(.unspecified_error);
            }
            return err;
        };

        _ = self.broker.stats.messages_sent.fetchAdd(1, .monotonic);
    }

    /// Send raw packet data
    pub fn sendPacket(self: *Self, data: []const u8) !void {
        if (self.isDisconnected()) return;

        self.send_lock.lock();
        defer self.send_lock.unlock();

        _ = std.posix.send(self.socket, data, 0) catch |err| {
            if (err == error.BrokenPipe or err == error.ConnectionResetByPeer) {
                self.disconnect(.unspecified_error);
            }
            return err;
        };
    }
};

// Tests
test "Broker init/deinit" {
    const broker = try Broker.init(std.testing.allocator, .{});
    defer broker.deinit();
}
