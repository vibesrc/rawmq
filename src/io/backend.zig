//! I/O Backend Abstraction
//!
//! Provides a unified interface for async I/O with automatic backend selection:
//! - io_uring on Linux 5.6+ (default, highest performance)
//! - epoll on older Linux (fallback)
//! - kqueue on macOS/BSD (future)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Epoll = @import("epoll.zig").Epoll;
pub const Uring = @import("uring.zig").Uring;

/// Socket handle
pub const Socket = std.posix.socket_t;

/// Event types for I/O readiness
pub const EventType = enum {
    read,
    write,
    close,
    error_event,
};

/// I/O completion event
pub const Event = struct {
    socket: Socket,
    event_type: EventType,
    user_data: usize,
};

/// Connection state for managed connections
pub const ConnState = struct {
    socket: Socket,
    recv_buffer: []u8,
    recv_pos: usize = 0,
    send_queue: std.ArrayList([]const u8),
    user_data: usize = 0,
    connected: bool = true,
};

/// Unified I/O backend interface
pub const Backend = union(enum) {
    io_uring: *Uring,
    epoll: *Epoll,

    const Self = @This();

    /// Add a socket to be monitored for read events
    pub fn addSocket(self: Self, socket: Socket, user_data: usize) !void {
        switch (self) {
            .io_uring => |u| try u.addSocket(socket, user_data),
            .epoll => |e| try e.addSocket(socket, user_data),
        }
    }

    /// Remove a socket from monitoring
    pub fn removeSocket(self: Self, socket: Socket) void {
        switch (self) {
            .io_uring => |u| u.removeSocket(socket),
            .epoll => |e| e.removeSocket(socket),
        }
    }

    /// Modify socket to watch for write readiness
    pub fn watchWrite(self: Self, socket: Socket, user_data: usize) !void {
        switch (self) {
            .io_uring => |u| try u.watchWrite(socket, user_data),
            .epoll => |e| try e.watchWrite(socket, user_data),
        }
    }

    /// Modify socket to watch for read readiness only
    pub fn watchRead(self: Self, socket: Socket, user_data: usize) !void {
        switch (self) {
            .io_uring => |u| try u.watchRead(socket, user_data),
            .epoll => |e| try e.watchRead(socket, user_data),
        }
    }

    /// Wait for I/O events, returns slice of ready events
    pub fn wait(self: Self, events: []Event, timeout_ms: i32) ![]Event {
        switch (self) {
            .io_uring => |u| return u.wait(events, timeout_ms),
            .epoll => |e| return e.wait(events, timeout_ms),
        }
    }

    /// Submit any pending I/O operations (io_uring specific, no-op for epoll)
    pub fn submit(self: Self) !void {
        switch (self) {
            .io_uring => |u| try u.submit(),
            .epoll => {},
        }
    }

    /// Get the backend name for logging
    pub fn name(self: Self) []const u8 {
        switch (self) {
            .io_uring => return "io_uring",
            .epoll => return "epoll",
        }
    }

    /// Clean up resources
    pub fn deinit(self: Self) void {
        switch (self) {
            .io_uring => |u| u.deinit(),
            .epoll => |e| e.deinit(),
        }
    }
};

/// Detect and initialize the best available backend
pub fn detectBest(allocator: Allocator, max_events: u32) !Backend {
    if (comptime builtin.os.tag == .linux) {
        // Try io_uring first (requires kernel 5.6+ for full networking support)
        if (Uring.init(allocator, max_events)) |uring| {
            return .{ .io_uring = uring };
        } else |_| {
            // Fall through to epoll
        }
    }

    // Fallback to epoll on Linux
    if (comptime builtin.os.tag == .linux) {
        return .{ .epoll = try Epoll.init(allocator, max_events) };
    }

    // TODO: kqueue for macOS/BSD
    return error.UnsupportedPlatform;
}

/// Force a specific backend (for testing or user preference)
pub fn forceBackend(allocator: Allocator, backend_type: enum { io_uring, epoll }, max_events: u32) !Backend {
    switch (backend_type) {
        .io_uring => {
            if (comptime builtin.os.tag != .linux) return error.UnsupportedPlatform;
            return .{ .io_uring = try Uring.init(allocator, max_events) };
        },
        .epoll => {
            if (comptime builtin.os.tag != .linux) return error.UnsupportedPlatform;
            return .{ .epoll = try Epoll.init(allocator, max_events) };
        },
    }
}

// Helper to create socket pair for tests
fn createSocketPair() ![2]std.posix.socket_t {
    const linux = std.os.linux;
    var sockets: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, 1 | 0x80000 | 0x800, 0, &sockets);
    if (rc != 0) return error.SocketPairFailed;
    return sockets;
}

// Tests
test "backend detection" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const b = try detectBest(std.testing.allocator, 1024);
    defer b.deinit();

    // Should get some backend
    const backend_name = b.name();
    try std.testing.expect(std.mem.eql(u8, backend_name, "io_uring") or std.mem.eql(u8, backend_name, "epoll"));
}

test "backend force epoll" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const b = try forceBackend(std.testing.allocator, .epoll, 1024);
    defer b.deinit();

    try std.testing.expectEqualStrings("epoll", b.name());
}

test "backend force io_uring" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const b = forceBackend(std.testing.allocator, .io_uring, 1024) catch return error.SkipZigTest;
    defer b.deinit();

    try std.testing.expectEqualStrings("io_uring", b.name());
}

test "backend unified socket operations" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const b = try detectBest(std.testing.allocator, 1024);
    defer b.deinit();

    const sockets = try createSocketPair();
    defer {
        std.posix.close(sockets[0]);
        std.posix.close(sockets[1]);
    }

    // Test add/remove/watch operations through unified interface
    try b.addSocket(sockets[0], 42);
    try b.watchWrite(sockets[0], 42);
    try b.watchRead(sockets[0], 42);
    b.removeSocket(sockets[0]);
}

test "backend unified event detection" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const b = try detectBest(std.testing.allocator, 1024);
    defer b.deinit();

    const sockets = try createSocketPair();
    defer {
        std.posix.close(sockets[0]);
        std.posix.close(sockets[1]);
    }

    // Watch socket[0] for reads
    try b.addSocket(sockets[0], 100);
    try b.submit();

    // Write to socket[1] - should trigger read on socket[0]
    _ = try std.posix.send(sockets[1], "hello", 0);

    // Wait for event
    var events: [16]Event = undefined;
    const ready = try b.wait(&events, 1000);

    try std.testing.expect(ready.len >= 1);
    try std.testing.expectEqual(@as(std.posix.socket_t, sockets[0]), ready[0].socket);
    try std.testing.expectEqual(EventType.read, ready[0].event_type);
    try std.testing.expectEqual(@as(usize, 100), ready[0].user_data);
}

test "backend both implementations produce same events" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    // Test epoll
    const epoll_backend = try forceBackend(std.testing.allocator, .epoll, 1024);
    defer epoll_backend.deinit();

    const sockets1 = try createSocketPair();
    defer {
        std.posix.close(sockets1[0]);
        std.posix.close(sockets1[1]);
    }

    try epoll_backend.addSocket(sockets1[0], 1);
    _ = try std.posix.send(sockets1[1], "test", 0);

    var events1: [16]Event = undefined;
    const ready1 = try epoll_backend.wait(&events1, 100);

    // Test io_uring if available
    const uring_backend = forceBackend(std.testing.allocator, .io_uring, 1024) catch return;
    defer uring_backend.deinit();

    const sockets2 = try createSocketPair();
    defer {
        std.posix.close(sockets2[0]);
        std.posix.close(sockets2[1]);
    }

    try uring_backend.addSocket(sockets2[0], 1);
    try uring_backend.submit();
    _ = try std.posix.send(sockets2[1], "test", 0);

    var events2: [16]Event = undefined;
    const ready2 = try uring_backend.wait(&events2, 100);

    // Both should detect read events
    try std.testing.expect(ready1.len >= 1);
    try std.testing.expect(ready2.len >= 1);
    try std.testing.expectEqual(ready1[0].event_type, ready2[0].event_type);
}

test "backend multiple sockets unified" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const b = try detectBest(std.testing.allocator, 1024);
    defer b.deinit();

    // Create 5 socket pairs
    var pairs: [5][2]std.posix.socket_t = undefined;
    for (&pairs, 0..) |*pair, i| {
        pair.* = try createSocketPair();
        try b.addSocket(pair[0], i + 1);
    }
    defer {
        for (pairs) |pair| {
            std.posix.close(pair[0]);
            std.posix.close(pair[1]);
        }
    }

    try b.submit();

    // Write to all of them
    for (pairs) |pair| {
        _ = try std.posix.send(pair[1], "data", 0);
    }

    // Collect events
    var events: [32]Event = undefined;
    var total: usize = 0;
    var attempts: usize = 0;
    while (total < 5 and attempts < 10) : (attempts += 1) {
        const ready = try b.wait(&events, 100);
        total += ready.len;
    }

    try std.testing.expect(total >= 5);
}
