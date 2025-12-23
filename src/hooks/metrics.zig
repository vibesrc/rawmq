//! Metrics Hooks
//!
//! Hooks for collecting broker metrics and statistics.

const std = @import("std");

/// Metric types
pub const Metric = enum {
    connections_total,
    connections_active,
    messages_received,
    messages_sent,
    messages_dropped,
    bytes_received,
    bytes_sent,
    subscriptions_active,
    retained_messages,
    publish_qos0,
    publish_qos1,
    publish_qos2,
};

/// Default no-op metrics collector
pub const NoOpMetrics = struct {
    pub inline fn increment(_: Metric) void {}
    pub inline fn incrementBy(_: Metric, _: u64) void {}
    pub inline fn decrement(_: Metric) void {}
    pub inline fn gauge(_: Metric, _: u64) void {}
};

/// Atomic counter-based metrics
pub const AtomicMetrics = struct {
    counters: [12]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** 12,

    pub fn increment(self: *AtomicMetrics, metric: Metric) void {
        _ = self.counters[@intFromEnum(metric)].fetchAdd(1, .monotonic);
    }

    pub fn incrementBy(self: *AtomicMetrics, metric: Metric, value: u64) void {
        _ = self.counters[@intFromEnum(metric)].fetchAdd(value, .monotonic);
    }

    pub fn decrement(self: *AtomicMetrics, metric: Metric) void {
        _ = self.counters[@intFromEnum(metric)].fetchSub(1, .monotonic);
    }

    pub fn gauge(self: *AtomicMetrics, metric: Metric, value: u64) void {
        self.counters[@intFromEnum(metric)].store(value, .monotonic);
    }

    pub fn get(self: *AtomicMetrics, metric: Metric) u64 {
        return self.counters[@intFromEnum(metric)].load(.monotonic);
    }

    pub fn snapshot(self: *AtomicMetrics) Snapshot {
        var snap: Snapshot = undefined;
        inline for (0..12) |i| {
            snap.values[i] = self.counters[i].load(.monotonic);
        }
        return snap;
    }

    pub const Snapshot = struct {
        values: [12]u64,

        pub fn get(self: Snapshot, metric: Metric) u64 {
            return self.values[@intFromEnum(metric)];
        }
    };
};

/// Check if a type implements the Metrics interface
pub fn isValidMetrics(comptime T: type) bool {
    return @hasDecl(T, "increment") and
        @hasDecl(T, "incrementBy") and
        @hasDecl(T, "decrement") and
        @hasDecl(T, "gauge");
}

test "NoOpMetrics compiles" {
    NoOpMetrics.increment(.connections_total);
    NoOpMetrics.incrementBy(.bytes_received, 1024);
    NoOpMetrics.decrement(.connections_active);
    NoOpMetrics.gauge(.subscriptions_active, 42);
}

test "AtomicMetrics" {
    var metrics = AtomicMetrics{};
    metrics.increment(.connections_total);
    metrics.increment(.connections_total);
    try std.testing.expectEqual(@as(u64, 2), metrics.get(.connections_total));

    metrics.incrementBy(.bytes_received, 1024);
    try std.testing.expectEqual(@as(u64, 1024), metrics.get(.bytes_received));

    metrics.gauge(.connections_active, 5);
    try std.testing.expectEqual(@as(u64, 5), metrics.get(.connections_active));

    metrics.decrement(.connections_active);
    try std.testing.expectEqual(@as(u64, 4), metrics.get(.connections_active));
}

test "isValidMetrics" {
    try std.testing.expect(isValidMetrics(NoOpMetrics));
    try std.testing.expect(isValidMetrics(AtomicMetrics));
}
