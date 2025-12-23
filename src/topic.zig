const std = @import("std");
const Allocator = std.mem.Allocator;

/// Topic matching engine using a trie structure
/// Supports MQTT wildcards: + (single level) and # (multi-level)
/// Also supports shared subscriptions ($share/group/topic)
pub const TopicTree = struct {
    const Self = @This();

    allocator: Allocator,
    root: *Node,
    // Shared subscription groups: group_name -> (topic_filter -> subscribers)
    shared_groups: std.StringHashMapUnmanaged(SharedGroup) = .{},
    shared_groups_lock: std.Thread.Mutex = .{},
    // Round-robin counter for load balancing
    round_robin_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub const SubscriptionId = u64;

    pub const SharedGroup = struct {
        // Topic filter -> list of subscribers
        filters: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(SharedSubscriber)) = .{},
    };

    pub const SharedSubscriber = struct {
        sub_id: SubscriptionId,
        data: SubscriptionData,
    };

    const Node = struct {
        children: std.StringHashMapUnmanaged(*Node) = .{},
        // Subscriptions at this exact node (for filters ending here)
        subscriptions: std.AutoArrayHashMapUnmanaged(SubscriptionId, SubscriptionData) = .{},
        // Single-level wildcard child (+)
        single_wildcard: ?*Node = null,
        // Multi-level wildcard subscriptions (#)
        multi_wildcard_subs: std.AutoArrayHashMapUnmanaged(SubscriptionId, SubscriptionData) = .{},

        fn deinit(self: *Node, allocator: Allocator) void {
            var it = self.children.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(allocator);
                allocator.destroy(entry.value_ptr.*);
            }
            self.children.deinit(allocator);

            // Free owned client_ids from subscriptions
            var sub_it = self.subscriptions.iterator();
            while (sub_it.next()) |entry| {
                allocator.free(entry.value_ptr.client_id);
            }
            self.subscriptions.deinit(allocator);

            var mw_it = self.multi_wildcard_subs.iterator();
            while (mw_it.next()) |entry| {
                allocator.free(entry.value_ptr.client_id);
            }
            self.multi_wildcard_subs.deinit(allocator);

            if (self.single_wildcard) |sw| {
                sw.deinit(allocator);
                allocator.destroy(sw);
            }
        }
    };

    pub const SubscriptionData = struct {
        client_id: []const u8,
        qos: u2,
        no_local: bool = false,
        retain_as_published: bool = false,
        retain_handling: u2 = 0,
        subscription_id: ?u32 = null, // v5.0
    };

    pub fn init(allocator: Allocator) !Self {
        const root = try allocator.create(Node);
        root.* = .{};
        return .{
            .allocator = allocator,
            .root = root,
        };
    }

    pub fn deinit(self: *Self) void {
        self.root.deinit(self.allocator);
        self.allocator.destroy(self.root);

        // Clean up shared groups
        self.shared_groups_lock.lock();
        defer self.shared_groups_lock.unlock();
        var group_it = self.shared_groups.iterator();
        while (group_it.next()) |group_entry| {
            self.allocator.free(group_entry.key_ptr.*);
            var filter_it = group_entry.value_ptr.filters.iterator();
            while (filter_it.next()) |filter_entry| {
                self.allocator.free(filter_entry.key_ptr.*);
                for (filter_entry.value_ptr.items) |sub| {
                    self.allocator.free(sub.data.client_id);
                }
                filter_entry.value_ptr.deinit(self.allocator);
            }
            group_entry.value_ptr.filters.deinit(self.allocator);
        }
        self.shared_groups.deinit(self.allocator);
    }

    /// Subscribe to a topic filter
    pub fn subscribe(
        self: *Self,
        filter: []const u8,
        sub_id: SubscriptionId,
        data: SubscriptionData,
    ) !void {
        // Check for shared subscription ($share/group/topic)
        if (parseSharedSubscription(filter)) |shared| {
            return self.subscribeShared(shared.group, shared.topic_filter, sub_id, data);
        }

        // Duplicate client_id to own the memory
        var owned_data = data;
        owned_data.client_id = try self.allocator.dupe(u8, data.client_id);
        errdefer self.allocator.free(owned_data.client_id);

        var current = self.root;
        var iter = TopicIterator.init(filter);

        while (iter.next()) |level| {
            if (std.mem.eql(u8, level, "#")) {
                // Multi-level wildcard - must be last
                try current.multi_wildcard_subs.put(self.allocator, sub_id, owned_data);
                return;
            } else if (std.mem.eql(u8, level, "+")) {
                // Single-level wildcard
                if (current.single_wildcard == null) {
                    current.single_wildcard = try self.allocator.create(Node);
                    current.single_wildcard.?.* = .{};
                }
                current = current.single_wildcard.?;
            } else {
                // Literal level
                if (current.children.get(level)) |child| {
                    current = child;
                } else {
                    const key = try self.allocator.dupe(u8, level);
                    const child = try self.allocator.create(Node);
                    child.* = .{};
                    try current.children.put(self.allocator, key, child);
                    current = child;
                }
            }
        }

        // Reached end of filter - add subscription here
        try current.subscriptions.put(self.allocator, sub_id, owned_data);
    }

    /// Subscribe to a shared subscription
    fn subscribeShared(
        self: *Self,
        group_name: []const u8,
        topic_filter: []const u8,
        sub_id: SubscriptionId,
        data: SubscriptionData,
    ) !void {
        self.shared_groups_lock.lock();
        defer self.shared_groups_lock.unlock();

        // Duplicate client_id
        var owned_data = data;
        owned_data.client_id = try self.allocator.dupe(u8, data.client_id);
        errdefer self.allocator.free(owned_data.client_id);

        // Get or create group
        const group_entry = self.shared_groups.getEntry(group_name);
        const group: *SharedGroup = if (group_entry) |e| e.value_ptr else blk: {
            const key = try self.allocator.dupe(u8, group_name);
            try self.shared_groups.put(self.allocator, key, .{});
            break :blk self.shared_groups.getEntry(key).?.value_ptr;
        };

        // Get or create filter entry
        const filter_entry = group.filters.getEntry(topic_filter);
        const subs: *std.ArrayListUnmanaged(SharedSubscriber) = if (filter_entry) |e| e.value_ptr else blk: {
            const key = try self.allocator.dupe(u8, topic_filter);
            try group.filters.put(self.allocator, key, .{});
            break :blk group.filters.getEntry(key).?.value_ptr;
        };

        // Add subscriber
        try subs.append(self.allocator, .{ .sub_id = sub_id, .data = owned_data });
    }

    /// Unsubscribe from a topic filter
    pub fn unsubscribe(self: *Self, filter: []const u8, sub_id: SubscriptionId) bool {
        // Check for shared subscription
        if (parseSharedSubscription(filter)) |shared| {
            return self.unsubscribeShared(shared.group, shared.topic_filter, sub_id);
        }

        var current = self.root;
        var iter = TopicIterator.init(filter);

        while (iter.next()) |level| {
            if (std.mem.eql(u8, level, "#")) {
                if (current.multi_wildcard_subs.fetchSwapRemove(sub_id)) |kv| {
                    self.allocator.free(kv.value.client_id);
                    return true;
                }
                return false;
            } else if (std.mem.eql(u8, level, "+")) {
                current = current.single_wildcard orelse return false;
            } else {
                current = current.children.get(level) orelse return false;
            }
        }

        if (current.subscriptions.fetchSwapRemove(sub_id)) |kv| {
            self.allocator.free(kv.value.client_id);
            return true;
        }
        return false;
    }

    /// Unsubscribe from a shared subscription
    fn unsubscribeShared(self: *Self, group_name: []const u8, topic_filter: []const u8, sub_id: SubscriptionId) bool {
        self.shared_groups_lock.lock();
        defer self.shared_groups_lock.unlock();

        const group = self.shared_groups.getPtr(group_name) orelse return false;
        const subs = group.filters.getPtr(topic_filter) orelse return false;

        for (subs.items, 0..) |sub, i| {
            if (sub.sub_id == sub_id) {
                self.allocator.free(sub.data.client_id);
                _ = subs.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Remove all subscriptions for a client
    pub fn removeClient(self: *Self, client_sub_ids: []const SubscriptionId) void {
        for (client_sub_ids) |sub_id| {
            self.removeSubscriptionRecursive(self.root, sub_id);
        }
    }

    fn removeSubscriptionRecursive(self: *Self, node: *Node, sub_id: SubscriptionId) void {
        if (node.subscriptions.fetchSwapRemove(sub_id)) |kv| {
            self.allocator.free(kv.value.client_id);
        }
        if (node.multi_wildcard_subs.fetchSwapRemove(sub_id)) |kv| {
            self.allocator.free(kv.value.client_id);
        }

        if (node.single_wildcard) |sw| {
            self.removeSubscriptionRecursive(sw, sub_id);
        }

        var it = node.children.iterator();
        while (it.next()) |entry| {
            self.removeSubscriptionRecursive(entry.value_ptr.*, sub_id);
        }
    }

    /// Match a topic name against all subscriptions
    /// Returns matching subscriptions via callback to avoid allocation
    pub fn match(
        self: *Self,
        topic_name: []const u8,
        context: anytype,
        callback: fn (@TypeOf(context), SubscriptionId, SubscriptionData) void,
    ) void {
        // Per MQTT spec 4.7.2: Topics starting with $ should not be matched by wildcards at root level
        const skip_root_wildcards = topic_name.len > 0 and topic_name[0] == '$';
        self.matchRecursive(self.root, TopicIterator.init(topic_name), context, callback, skip_root_wildcards, true);

        // Also match shared subscriptions
        self.matchShared(topic_name, context, callback);
    }

    /// Match shared subscriptions and deliver to one subscriber per group
    fn matchShared(
        self: *Self,
        topic_name: []const u8,
        context: anytype,
        callback: fn (@TypeOf(context), SubscriptionId, SubscriptionData) void,
    ) void {
        self.shared_groups_lock.lock();
        defer self.shared_groups_lock.unlock();

        var group_it = self.shared_groups.iterator();
        while (group_it.next()) |group_entry| {
            var filter_it = group_entry.value_ptr.filters.iterator();
            while (filter_it.next()) |filter_entry| {
                // Check if topic matches this filter
                if (topicMatchesFilter(topic_name, filter_entry.key_ptr.*)) {
                    const subs = filter_entry.value_ptr.items;
                    if (subs.len > 0) {
                        // Round-robin: pick one subscriber
                        const counter = self.round_robin_counter.fetchAdd(1, .monotonic);
                        const idx = counter % subs.len;
                        callback(context, subs[idx].sub_id, subs[idx].data);
                    }
                }
            }
        }
    }

    fn matchRecursive(
        self: *Self,
        node: *Node,
        iter: TopicIterator,
        context: anytype,
        callback: fn (@TypeOf(context), SubscriptionId, SubscriptionData) void,
        skip_wildcards: bool,
        is_root: bool,
    ) void {
        var local_iter = iter;

        if (local_iter.next()) |level| {
            // Multi-level wildcard matches everything from here
            // But skip wildcards at root for $ topics
            if (!skip_wildcards or !is_root) {
                var mw_it = node.multi_wildcard_subs.iterator();
                while (mw_it.next()) |entry| {
                    callback(context, entry.key_ptr.*, entry.value_ptr.*);
                }
            }

            // Single-level wildcard matches this level
            // But skip wildcards at root for $ topics
            if (!skip_wildcards or !is_root) {
                if (node.single_wildcard) |sw| {
                    self.matchRecursive(sw, local_iter, context, callback, skip_wildcards, false);
                }
            }

            // Literal match
            if (node.children.get(level)) |child| {
                self.matchRecursive(child, local_iter, context, callback, skip_wildcards, false);
            }
        } else {
            // End of topic - check multi-level wildcard and exact subscriptions
            if (!skip_wildcards or !is_root) {
                var mw_it = node.multi_wildcard_subs.iterator();
                while (mw_it.next()) |entry| {
                    callback(context, entry.key_ptr.*, entry.value_ptr.*);
                }
            }

            var sub_it = node.subscriptions.iterator();
            while (sub_it.next()) |entry| {
                callback(context, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    pub const MatchResult = struct {
        id: SubscriptionId,
        data: SubscriptionData,
    };

    /// Collect matching subscriptions into a list (allocates)
    pub fn matchCollect(
        self: *Self,
        allocator: Allocator,
        topic_name: []const u8,
    ) !std.ArrayListUnmanaged(MatchResult) {
        var results: std.ArrayListUnmanaged(MatchResult) = .empty;
        const Context = struct {
            list: *std.ArrayListUnmanaged(MatchResult),
            alloc: Allocator,
        };
        const ctx = Context{ .list = &results, .alloc = allocator };
        self.match(topic_name, ctx, struct {
            fn cb(c: Context, id: SubscriptionId, data: SubscriptionData) void {
                c.list.append(c.alloc, .{ .id = id, .data = data }) catch {};
            }
        }.cb);
        return results;
    }
};

/// Iterator over topic levels (splits on '/')
pub const TopicIterator = struct {
    topic: []const u8,
    pos: usize = 0,

    pub fn init(topic: []const u8) TopicIterator {
        return .{ .topic = topic };
    }

    pub fn next(self: *TopicIterator) ?[]const u8 {
        if (self.pos >= self.topic.len) return null;

        const start = self.pos;
        while (self.pos < self.topic.len and self.topic[self.pos] != '/') {
            self.pos += 1;
        }
        const level = self.topic[start..self.pos];

        // Skip separator
        if (self.pos < self.topic.len) {
            self.pos += 1;
        }

        return level;
    }
};

/// Validate a topic name (not a filter)
pub fn validateTopicName(topic: []const u8) bool {
    if (topic.len == 0) return false;
    if (topic.len > 65535) return false;

    // Topic names cannot contain wildcards
    for (topic) |c| {
        if (c == '+' or c == '#') return false;
        if (c == 0) return false; // Null character
    }

    return true;
}

/// Validate a topic filter (subscription)
pub fn validateTopicFilter(filter: []const u8) bool {
    if (filter.len == 0) return false;
    if (filter.len > 65535) return false;

    // Handle shared subscription: $share/group/topic-filter
    const actual_filter = if (parseSharedSubscription(filter)) |shared| shared.topic_filter else filter;

    var iter = TopicIterator.init(actual_filter);
    var saw_multi = false;

    while (iter.next()) |level| {
        if (saw_multi) return false; // # must be last

        if (std.mem.eql(u8, level, "#")) {
            saw_multi = true;
        } else if (std.mem.eql(u8, level, "+")) {
            // + is valid as a complete level
        } else {
            // Check for embedded wildcards
            for (level) |c| {
                if (c == '+' or c == '#') return false;
                if (c == 0) return false;
            }
        }
    }

    return true;
}

/// Parse shared subscription format: $share/group/topic-filter
/// Returns null if not a shared subscription
pub fn parseSharedSubscription(filter: []const u8) ?struct { group: []const u8, topic_filter: []const u8 } {
    // Must start with "$share/"
    if (filter.len < 8) return null;
    if (!std.mem.startsWith(u8, filter, "$share/")) return null;

    // Find second slash after "$share/"
    const rest = filter[7..]; // Skip "$share/"
    const second_slash = std.mem.indexOf(u8, rest, "/") orelse return null;

    if (second_slash == 0) return null; // Empty group name
    if (second_slash + 1 >= rest.len) return null; // Empty topic filter

    return .{
        .group = rest[0..second_slash],
        .topic_filter = rest[second_slash + 1 ..],
    };
}

/// Check if a topic matches a filter (used for validation, not routing)
pub fn topicMatchesFilter(topic: []const u8, filter: []const u8) bool {
    var topic_iter = TopicIterator.init(topic);
    var filter_iter = TopicIterator.init(filter);

    while (true) {
        const filter_level = filter_iter.next();
        const topic_level = topic_iter.next();

        if (filter_level == null and topic_level == null) {
            return true; // Both exhausted
        }

        if (filter_level) |fl| {
            if (std.mem.eql(u8, fl, "#")) {
                return true; // # matches everything remaining
            }

            if (topic_level == null) {
                return false; // Filter has more levels but topic exhausted
            }

            if (std.mem.eql(u8, fl, "+")) {
                continue; // + matches any single level
            }

            if (!std.mem.eql(u8, fl, topic_level.?)) {
                return false; // Literal mismatch
            }
        } else {
            return false; // Filter exhausted but topic has more
        }
    }
}

// Tests
test "TopicIterator" {
    var iter = TopicIterator.init("a/b/c");
    try std.testing.expectEqualStrings("a", iter.next().?);
    try std.testing.expectEqualStrings("b", iter.next().?);
    try std.testing.expectEqualStrings("c", iter.next().?);
    try std.testing.expect(iter.next() == null);
}

test "topicMatchesFilter" {
    try std.testing.expect(topicMatchesFilter("a/b/c", "a/b/c"));
    try std.testing.expect(topicMatchesFilter("a/b/c", "a/+/c"));
    try std.testing.expect(topicMatchesFilter("a/b/c", "a/#"));
    try std.testing.expect(topicMatchesFilter("a/b/c", "#"));
    try std.testing.expect(topicMatchesFilter("a/b/c", "+/+/+"));

    try std.testing.expect(!topicMatchesFilter("a/b/c", "a/b"));
    try std.testing.expect(!topicMatchesFilter("a/b", "a/b/c"));
    try std.testing.expect(!topicMatchesFilter("a/b/c", "a/x/c"));
}

test "validateTopicFilter" {
    try std.testing.expect(validateTopicFilter("a/b/c"));
    try std.testing.expect(validateTopicFilter("a/+/c"));
    try std.testing.expect(validateTopicFilter("a/#"));
    try std.testing.expect(validateTopicFilter("#"));
    try std.testing.expect(validateTopicFilter("+"));

    try std.testing.expect(!validateTopicFilter(""));
    try std.testing.expect(!validateTopicFilter("a/#/b")); // # must be last
    try std.testing.expect(!validateTopicFilter("a/b+c")); // + must be whole level
}

test "TopicTree subscribe and match" {
    var tree = try TopicTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.subscribe("a/b/c", 1, .{ .client_id = "client1", .qos = 0 });
    try tree.subscribe("a/+/c", 2, .{ .client_id = "client2", .qos = 1 });
    try tree.subscribe("a/#", 3, .{ .client_id = "client3", .qos = 2 });

    var matches = try tree.matchCollect(std.testing.allocator, "a/b/c");
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), matches.items.len);
}

// RFC 5.0 Section 9.2: Shared Subscription Tests
test "parseSharedSubscription basic" {
    // Valid shared subscriptions [MQTT-4.8.2]
    const result = parseSharedSubscription("$share/consumer-group/orders/#");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("consumer-group", result.?.group);
    try std.testing.expectEqualStrings("orders/#", result.?.topic_filter);
}

test "parseSharedSubscription workers example" {
    // Example from RFC: $share/workers/tasks/+
    const result = parseSharedSubscription("$share/workers/tasks/+");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("workers", result.?.group);
    try std.testing.expectEqualStrings("tasks/+", result.?.topic_filter);
}

test "parseSharedSubscription invalid cases" {
    // Not a shared subscription
    try std.testing.expect(parseSharedSubscription("orders/#") == null);
    try std.testing.expect(parseSharedSubscription("$SYS/broker/clients") == null);

    // Invalid format: missing group or topic
    try std.testing.expect(parseSharedSubscription("$share/") == null);
    try std.testing.expect(parseSharedSubscription("$share//topic") == null);
    try std.testing.expect(parseSharedSubscription("$share/group/") == null);
}

test "validateTopicFilter shared subscriptions" {
    // Shared subscriptions should be valid [MQTT-4.8.2]
    try std.testing.expect(validateTopicFilter("$share/group/topic"));
    try std.testing.expect(validateTopicFilter("$share/workers/tasks/+"));
    try std.testing.expect(validateTopicFilter("$share/consumers/orders/#"));
}

test "TopicTree shared subscription basic" {
    // [MQTT-4.8.2-1] Message matching shared subscription sent to ONE subscriber
    var tree = try TopicTree.init(std.testing.allocator);
    defer tree.deinit();

    // Subscribe two clients to same shared group
    try tree.subscribe("$share/workers/tasks", 1, .{ .client_id = "client1", .qos = 0 });
    try tree.subscribe("$share/workers/tasks", 2, .{ .client_id = "client2", .qos = 0 });

    // Match should return exactly one result (round-robin)
    var matches = try tree.matchCollect(std.testing.allocator, "tasks");
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
}

test "TopicTree shared and normal subscriptions coexist" {
    // [MQTT-4.8.2] Shared and normal subscriptions can coexist
    var tree = try TopicTree.init(std.testing.allocator);
    defer tree.deinit();

    // One normal subscription
    try tree.subscribe("tasks", 1, .{ .client_id = "normal_client", .qos = 0 });
    // One shared subscription
    try tree.subscribe("$share/workers/tasks", 2, .{ .client_id = "shared_client", .qos = 0 });

    var matches = try tree.matchCollect(std.testing.allocator, "tasks");
    defer matches.deinit(std.testing.allocator);

    // Should get 2 results: one from normal, one from shared
    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
}

test "TopicTree multiple share groups on same topic" {
    // [MQTT-4.8.2] Different share groups receive their own copy
    var tree = try TopicTree.init(std.testing.allocator);
    defer tree.deinit();

    // Two different groups
    try tree.subscribe("$share/group1/tasks", 1, .{ .client_id = "g1_client", .qos = 0 });
    try tree.subscribe("$share/group2/tasks", 2, .{ .client_id = "g2_client", .qos = 0 });

    var matches = try tree.matchCollect(std.testing.allocator, "tasks");
    defer matches.deinit(std.testing.allocator);

    // Should get 2 results: one from each group
    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
}

// RFC Section 4.7.2: $SYS Topics Tests
test "TopicTree dollar topics not matched by wildcards" {
    // [MQTT-4.7.2-1] Topics starting with $ MUST NOT be matched by # or + at root
    var tree = try TopicTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.subscribe("#", 1, .{ .client_id = "client1", .qos = 0 });
    try tree.subscribe("+/test", 2, .{ .client_id = "client2", .qos = 0 });

    // $SYS topics should NOT match # at root
    var matches = try tree.matchCollect(std.testing.allocator, "$SYS/broker/clients");
    defer matches.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "TopicTree explicit dollar topic subscription" {
    // But explicit subscription to $SYS topic should work
    var tree = try TopicTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.subscribe("$SYS/#", 1, .{ .client_id = "client1", .qos = 0 });
    try tree.subscribe("$SYS/broker/clients", 2, .{ .client_id = "client2", .qos = 0 });

    var matches = try tree.matchCollect(std.testing.allocator, "$SYS/broker/clients");
    defer matches.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
}

// RFC Section 4.7.1: Topic Wildcards Tests
test "single level wildcard in middle" {
    // [MQTT-4.7.1-2] + matches exactly one topic level
    try std.testing.expect(topicMatchesFilter("a/b/c", "a/+/c"));
    try std.testing.expect(topicMatchesFilter("a/xyz/c", "a/+/c"));
    try std.testing.expect(!topicMatchesFilter("a/b/d/c", "a/+/c")); // + matches only one level
}

test "multi level wildcard" {
    // [MQTT-4.7.1-1] # matches any number of levels
    try std.testing.expect(topicMatchesFilter("a", "a/#"));
    try std.testing.expect(topicMatchesFilter("a/b", "a/#"));
    try std.testing.expect(topicMatchesFilter("a/b/c/d/e", "a/#"));
}

test "empty topic level" {
    // Topics can have empty levels (e.g., "a//c")
    try std.testing.expect(topicMatchesFilter("a//c", "a/+/c"));
    try std.testing.expect(topicMatchesFilter("a//c", "a//c"));
}
