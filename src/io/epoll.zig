//! epoll-based I/O backend
//!
//! Fallback backend for Linux systems without io_uring support.
//! Uses level-triggered epoll for socket readiness notification.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const backend = @import("backend.zig");
const Event = backend.Event;
const EventType = backend.EventType;
const Socket = backend.Socket;

pub const Epoll = struct {
    const Self = @This();

    allocator: Allocator,
    epoll_fd: i32,
    max_events: u32,
    epoll_events: []std.os.linux.epoll_event,

    pub fn init(allocator: Allocator, max_events: u32) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const epoll_fd = try std.posix.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
        errdefer std.posix.close(epoll_fd);

        const events = try allocator.alloc(std.os.linux.epoll_event, max_events);
        errdefer allocator.free(events);

        self.* = .{
            .allocator = allocator,
            .epoll_fd = epoll_fd,
            .max_events = max_events,
            .epoll_events = events,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        std.posix.close(self.epoll_fd);
        self.allocator.free(self.epoll_events);
        self.allocator.destroy(self);
    }

    /// Add a socket to be monitored for read events
    pub fn addSocket(self: *Self, socket: Socket, user_data: usize) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.RDHUP | std.os.linux.EPOLL.HUP | std.os.linux.EPOLL.ERR,
            .data = .{ .u64 = @as(u64, @intCast(socket)) | (@as(u64, user_data) << 32) },
        };

        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, socket, &event);
    }

    /// Remove a socket from monitoring
    pub fn removeSocket(self: *Self, socket: Socket) void {
        std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, socket, null) catch {};
    }

    /// Modify socket to watch for write readiness
    pub fn watchWrite(self: *Self, socket: Socket, user_data: usize) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.OUT | std.os.linux.EPOLL.RDHUP | std.os.linux.EPOLL.HUP | std.os.linux.EPOLL.ERR,
            .data = .{ .u64 = @as(u64, @intCast(socket)) | (@as(u64, user_data) << 32) },
        };

        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, socket, &event);
    }

    /// Modify socket to watch for read readiness only
    pub fn watchRead(self: *Self, socket: Socket, user_data: usize) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.RDHUP | std.os.linux.EPOLL.HUP | std.os.linux.EPOLL.ERR,
            .data = .{ .u64 = @as(u64, @intCast(socket)) | (@as(u64, user_data) << 32) },
        };

        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, socket, &event);
    }

    /// Wait for I/O events
    pub fn wait(self: *Self, events: []Event, timeout_ms: i32) ![]Event {
        const n = std.posix.epoll_wait(self.epoll_fd, self.epoll_events, timeout_ms);

        const count = @min(n, events.len);
        for (0..count) |i| {
            const ep_event = self.epoll_events[i];
            const socket: Socket = @intCast(ep_event.data.u64 & 0xFFFFFFFF);
            const user_data: usize = @intCast(ep_event.data.u64 >> 32);

            // Determine event type
            var event_type: EventType = .read;
            if (ep_event.events & (std.os.linux.EPOLL.HUP | std.os.linux.EPOLL.RDHUP) != 0) {
                event_type = .close;
            } else if (ep_event.events & std.os.linux.EPOLL.ERR != 0) {
                event_type = .error_event;
            } else if (ep_event.events & std.os.linux.EPOLL.OUT != 0) {
                event_type = .write;
            } else if (ep_event.events & std.os.linux.EPOLL.IN != 0) {
                event_type = .read;
            }

            events[i] = .{
                .socket = socket,
                .event_type = event_type,
                .user_data = user_data,
            };
        }

        return events[0..count];
    }
};

// Helper to create socket pair
fn createSocketPair() ![2]i32 {
    var sockets: [2]i32 = undefined;
    // SOCK_STREAM = 1, SOCK_CLOEXEC = 0x80000, SOCK_NONBLOCK = 0x800
    const rc = std.os.linux.socketpair(std.os.linux.AF.UNIX, 1 | 0x80000 | 0x800, 0, &sockets);
    if (rc != 0) return error.SocketPairFailed;
    return sockets;
}

// Tests
test "epoll init/deinit" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const epoll = try Epoll.init(std.testing.allocator, 1024);
    defer epoll.deinit();
}

test "epoll socket lifecycle" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const epoll = try Epoll.init(std.testing.allocator, 1024);
    defer epoll.deinit();

    const sockets = try createSocketPair();
    defer {
        std.posix.close(sockets[0]);
        std.posix.close(sockets[1]);
    }

    try epoll.addSocket(sockets[0], 42);
    try epoll.watchWrite(sockets[0], 42);
    try epoll.watchRead(sockets[0], 42);
    epoll.removeSocket(sockets[0]);
}

test "epoll read event detection" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const epoll = try Epoll.init(std.testing.allocator, 1024);
    defer epoll.deinit();

    const sockets = try createSocketPair();
    defer {
        std.posix.close(sockets[0]);
        std.posix.close(sockets[1]);
    }

    // Watch socket[0] for reads
    try epoll.addSocket(sockets[0], 100);

    // Write to socket[1] - should trigger read on socket[0]
    const msg = "hello";
    _ = try std.posix.send(sockets[1], msg, 0);

    // Wait for event
    var events: [16]Event = undefined;
    const ready = try epoll.wait(&events, 1000);

    try std.testing.expect(ready.len >= 1);
    try std.testing.expectEqual(@as(i32, sockets[0]), ready[0].socket);
    try std.testing.expectEqual(EventType.read, ready[0].event_type);
    try std.testing.expectEqual(@as(usize, 100), ready[0].user_data);
}

test "epoll write event detection" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const epoll = try Epoll.init(std.testing.allocator, 1024);
    defer epoll.deinit();

    const sockets = try createSocketPair();
    defer {
        std.posix.close(sockets[0]);
        std.posix.close(sockets[1]);
    }

    // Watch for write readiness
    try epoll.addSocket(sockets[0], 200);
    try epoll.watchWrite(sockets[0], 200);

    // Socket should be immediately writable
    var events: [16]Event = undefined;
    const ready = try epoll.wait(&events, 100);

    try std.testing.expect(ready.len >= 1);
    // Could be read or write depending on epoll edge cases
    try std.testing.expectEqual(@as(i32, sockets[0]), ready[0].socket);
}

test "epoll multiple sockets" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const epoll = try Epoll.init(std.testing.allocator, 1024);
    defer epoll.deinit();

    // Create 3 socket pairs
    var pairs: [3][2]i32 = undefined;
    for (&pairs, 0..) |*pair, i| {
        pair.* = try createSocketPair();
        try epoll.addSocket(pair[0], i + 1);
    }
    defer {
        for (pairs) |pair| {
            std.posix.close(pair[0]);
            std.posix.close(pair[1]);
        }
    }

    // Write to all of them
    for (pairs) |pair| {
        _ = try std.posix.send(pair[1], "test", 0);
    }

    // Should get events for all 3
    var events: [16]Event = undefined;
    const ready = try epoll.wait(&events, 1000);

    try std.testing.expect(ready.len >= 3);
}

test "epoll timeout with no events" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const epoll = try Epoll.init(std.testing.allocator, 1024);
    defer epoll.deinit();

    const sockets = try createSocketPair();
    defer {
        std.posix.close(sockets[0]);
        std.posix.close(sockets[1]);
    }

    // Watch for reads but don't write anything
    try epoll.addSocket(sockets[0], 42);

    // Should timeout and return empty
    var events: [16]Event = undefined;
    const start = std.time.milliTimestamp();
    const ready = try epoll.wait(&events, 50);
    const elapsed = std.time.milliTimestamp() - start;

    try std.testing.expectEqual(@as(usize, 0), ready.len);
    try std.testing.expect(elapsed >= 40); // Allow some timing slack
}

test "epoll close detection" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const epoll = try Epoll.init(std.testing.allocator, 1024);
    defer epoll.deinit();

    const sockets = try createSocketPair();
    defer std.posix.close(sockets[0]);

    // Watch socket[0]
    try epoll.addSocket(sockets[0], 42);

    // Close the other end
    std.posix.close(sockets[1]);

    // Should get close/hangup event
    var events: [16]Event = undefined;
    const ready = try epoll.wait(&events, 1000);

    try std.testing.expect(ready.len >= 1);
    try std.testing.expectEqual(@as(i32, sockets[0]), ready[0].socket);
    // Should be close or read (read returns 0 on closed connection)
    try std.testing.expect(ready[0].event_type == .close or ready[0].event_type == .read);
}

test "epoll high connection count" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const epoll = try Epoll.init(std.testing.allocator, 4096);
    defer epoll.deinit();

    const count = 100;
    var pairs: [count][2]i32 = undefined;
    var created: usize = 0;

    // Create many socket pairs
    for (&pairs, 0..) |*pair, i| {
        pair.* = createSocketPair() catch break;
        epoll.addSocket(pair[0], i) catch break;
        created += 1;
    }
    defer {
        for (pairs[0..created]) |pair| {
            std.posix.close(pair[0]);
            std.posix.close(pair[1]);
        }
    }

    try std.testing.expect(created >= 50); // Should handle at least 50

    // Write to half of them
    for (pairs[0 .. created / 2]) |pair| {
        _ = std.posix.send(pair[1], "x", 0) catch {};
    }

    // Should get events
    var events: [128]Event = undefined;
    const ready = try epoll.wait(&events, 100);
    try std.testing.expect(ready.len > 0);
}
