const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const topic = @import("topic.zig");

/// Pending QoS message for delivery
pub const PendingMessage = struct {
    packet_id: u16,
    topic: []const u8,
    payload: []const u8,
    qos: protocol.QoS,
    retain: bool,
    timestamp: i64,
    state: State,

    pub const State = enum {
        pending, // Waiting to be sent
        sent, // Sent, waiting for ack
        pubrec_received, // QoS 2: PUBREC received, need to send PUBREL
        pubrel_sent, // QoS 2: PUBREL sent, waiting for PUBCOMP
    };
};

// Global atomic counter for subscription IDs to ensure uniqueness across all sessions
var global_next_sub_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

/// Client session data
pub const Session = struct {
    const Self = @This();

    allocator: Allocator,
    client_id: []const u8,
    protocol_version: protocol.ProtocolVersion,
    clean_session: bool,
    keep_alive: u16,

    // Subscriptions (filter -> subscription data)
    subscriptions: std.StringHashMapUnmanaged(SubscriptionInfo) = .{},
    subscription_ids: std.ArrayListUnmanaged(topic.TopicTree.SubscriptionId) = .{},

    // QoS state
    pending_outgoing: std.AutoArrayHashMapUnmanaged(u16, PendingMessage) = .{},
    pending_incoming_qos2: std.AutoArrayHashMapUnmanaged(u16, void) = .{}, // QoS 2 packet IDs in flight
    next_packet_id: u16 = 1,

    // Will message
    will: ?WillMessage = null,

    // Connection state
    connected: bool = false,
    last_activity: i64 = 0,

    // v5.0 properties
    session_expiry_interval: u32 = 0,
    receive_maximum: u16 = 65535,

    pub const SubscriptionInfo = struct {
        qos: protocol.QoS,
        no_local: bool,
        retain_as_published: bool,
        retain_handling: u2,
        sub_id: topic.TopicTree.SubscriptionId,
    };

    pub const WillMessage = struct {
        topic: []const u8,
        payload: []const u8,
        qos: protocol.QoS,
        retain: bool,
        delay_interval: u32 = 0,
    };

    pub fn init(allocator: Allocator, client_id: []const u8) !*Self {
        const session = try allocator.create(Self);
        session.* = .{
            .allocator = allocator,
            .client_id = try allocator.dupe(u8, client_id),
            .protocol_version = .v3_1_1,
            .clean_session = true,
            .keep_alive = 0,
        };
        return session;
    }

    pub fn deinit(self: *Self) void {
        // Free subscription filters
        var sub_it = self.subscriptions.iterator();
        while (sub_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.subscriptions.deinit(self.allocator);
        self.subscription_ids.deinit(self.allocator);

        // Free pending messages
        var pending_it = self.pending_outgoing.iterator();
        while (pending_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.topic);
            self.allocator.free(entry.value_ptr.payload);
        }
        self.pending_outgoing.deinit(self.allocator);
        self.pending_incoming_qos2.deinit(self.allocator);

        // Free will
        if (self.will) |w| {
            self.allocator.free(w.topic);
            self.allocator.free(w.payload);
        }

        self.allocator.free(self.client_id);
        self.allocator.destroy(self);
    }

    pub fn generatePacketId(self: *Self) u16 {
        const id = self.next_packet_id;
        self.next_packet_id +%= 1;
        if (self.next_packet_id == 0) self.next_packet_id = 1;
        return id;
    }

    pub fn addSubscription(
        self: *Self,
        filter: []const u8,
        qos: protocol.QoS,
        no_local: bool,
        retain_as_published: bool,
        retain_handling: u2,
    ) !topic.TopicTree.SubscriptionId {
        // Use global atomic counter for subscription IDs to ensure uniqueness across sessions
        const sub_id = global_next_sub_id.fetchAdd(1, .monotonic);

        // Remove old subscription if exists
        if (self.subscriptions.get(filter)) |old| {
            // Subscription exists, update it
            const entry = self.subscriptions.getEntry(filter).?;
            entry.value_ptr.* = .{
                .qos = qos,
                .no_local = no_local,
                .retain_as_published = retain_as_published,
                .retain_handling = retain_handling,
                .sub_id = sub_id,
            };
            // Remove old sub_id and add new one
            for (self.subscription_ids.items, 0..) |sid, i| {
                if (sid == old.sub_id) {
                    _ = self.subscription_ids.swapRemove(i);
                    break;
                }
            }
        } else {
            const key = try self.allocator.dupe(u8, filter);
            try self.subscriptions.put(self.allocator, key, .{
                .qos = qos,
                .no_local = no_local,
                .retain_as_published = retain_as_published,
                .retain_handling = retain_handling,
                .sub_id = sub_id,
            });
        }

        try self.subscription_ids.append(self.allocator, sub_id);
        return sub_id;
    }

    pub fn removeSubscription(self: *Self, filter: []const u8) ?topic.TopicTree.SubscriptionId {
        if (self.subscriptions.fetchRemove(filter)) |kv| {
            self.allocator.free(kv.key);
            // Remove from subscription_ids
            for (self.subscription_ids.items, 0..) |sid, i| {
                if (sid == kv.value.sub_id) {
                    _ = self.subscription_ids.swapRemove(i);
                    break;
                }
            }
            return kv.value.sub_id;
        }
        return null;
    }

    pub fn setWill(
        self: *Self,
        will_topic: []const u8,
        will_payload: []const u8,
        qos: protocol.QoS,
        retain: bool,
        delay_interval: u32,
    ) !void {
        if (self.will) |w| {
            self.allocator.free(w.topic);
            self.allocator.free(w.payload);
        }
        self.will = .{
            .topic = try self.allocator.dupe(u8, will_topic),
            .payload = try self.allocator.dupe(u8, will_payload),
            .qos = qos,
            .retain = retain,
            .delay_interval = delay_interval,
        };
    }

    pub fn clearWill(self: *Self) void {
        if (self.will) |w| {
            self.allocator.free(w.topic);
            self.allocator.free(w.payload);
            self.will = null;
        }
    }

    pub fn queueOutgoingMessage(
        self: *Self,
        pkt_topic: []const u8,
        payload: []const u8,
        qos: protocol.QoS,
        retain: bool,
    ) !u16 {
        const packet_id = if (qos != .at_most_once) self.generatePacketId() else 0;

        if (qos != .at_most_once) {
            try self.pending_outgoing.put(self.allocator, packet_id, .{
                .packet_id = packet_id,
                .topic = try self.allocator.dupe(u8, pkt_topic),
                .payload = try self.allocator.dupe(u8, payload),
                .qos = qos,
                .retain = retain,
                .timestamp = std.time.timestamp(),
                .state = .pending,
            });
        }

        return packet_id;
    }

    pub fn acknowledgeOutgoing(self: *Self, packet_id: u16) bool {
        if (self.pending_outgoing.fetchSwapRemove(packet_id)) |kv| {
            self.allocator.free(kv.value.topic);
            self.allocator.free(kv.value.payload);
            return true;
        }
        return false;
    }

    pub fn recordIncomingQos2(self: *Self, packet_id: u16) !void {
        try self.pending_incoming_qos2.put(self.allocator, packet_id, {});
    }

    pub fn hasIncomingQos2(self: *Self, packet_id: u16) bool {
        return self.pending_incoming_qos2.contains(packet_id);
    }

    pub fn completeIncomingQos2(self: *Self, packet_id: u16) bool {
        return self.pending_incoming_qos2.swapRemove(packet_id);
    }

    pub fn clear(self: *Self) void {
        // Clear subscriptions
        var sub_it = self.subscriptions.iterator();
        while (sub_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.subscriptions.clearRetainingCapacity();
        self.subscription_ids.clearRetainingCapacity();

        // Clear pending messages
        var pending_it = self.pending_outgoing.iterator();
        while (pending_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.topic);
            self.allocator.free(entry.value_ptr.payload);
        }
        self.pending_outgoing.clearRetainingCapacity();
        self.pending_incoming_qos2.clearRetainingCapacity();

        self.next_packet_id = 1;
    }
};

/// Session store - manages all client sessions
pub const SessionStore = struct {
    const Self = @This();

    allocator: Allocator,
    sessions: std.StringHashMapUnmanaged(*Session) = .{},
    lock: std.Thread.RwLock = .{},

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.lock.lock();
        defer self.lock.unlock();

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.sessions.deinit(self.allocator);
    }

    /// Get or create a session
    /// Note: Does NOT clear the session - caller must handle clean_session logic
    pub fn getOrCreate(self: *Self, client_id: []const u8, clean_session: bool) !struct { session: *Session, existed: bool } {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.sessions.get(client_id)) |existing| {
            // Note: session present flag is false if clean_session is true
            return .{ .session = existing, .existed = !clean_session };
        }

        const session = try Session.init(self.allocator, client_id);
        session.clean_session = clean_session;
        try self.sessions.put(self.allocator, session.client_id, session);
        return .{ .session = session, .existed = false };
    }

    /// Get existing session
    pub fn get(self: *Self, client_id: []const u8) ?*Session {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.sessions.get(client_id);
    }

    /// Remove a session
    pub fn remove(self: *Self, client_id: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.sessions.fetchRemove(client_id)) |kv| {
            kv.value.deinit();
        }
    }

    /// Remove session if clean_session was set
    pub fn maybeRemove(self: *Self, session: *Session) void {
        if (session.clean_session) {
            self.remove(session.client_id);
        }
    }
};

// Tests
test "Session packet ID generation" {
    const session = try Session.init(std.testing.allocator, "test");
    defer session.deinit();

    const id1 = session.generatePacketId();
    const id2 = session.generatePacketId();
    try std.testing.expect(id1 != id2);
}

test "Session subscription management" {
    const session = try Session.init(std.testing.allocator, "test");
    defer session.deinit();

    const sub_id = try session.addSubscription("test/topic", .at_least_once, false, false, 0);
    try std.testing.expect(session.subscriptions.count() == 1);
    try std.testing.expect(session.subscription_ids.items.len == 1);

    const removed = session.removeSubscription("test/topic");
    try std.testing.expect(removed != null);
    try std.testing.expect(removed.? == sub_id);
    try std.testing.expect(session.subscriptions.count() == 0);
}

test "SessionStore" {
    var store = SessionStore.init(std.testing.allocator);
    defer store.deinit();

    const result = try store.getOrCreate("client1", false);
    try std.testing.expect(!result.existed);

    const result2 = try store.getOrCreate("client1", false);
    try std.testing.expect(result2.existed);
    try std.testing.expect(result.session == result2.session);
}
