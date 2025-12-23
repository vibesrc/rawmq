//! io_uring-based I/O backend
//!
//! High-performance backend for Linux 5.6+ using io_uring.
//! Provides batched syscalls and efficient completion notification.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const backend = @import("backend.zig");
const Event = backend.Event;
const EventType = backend.EventType;
const Socket = backend.Socket;

const linux = std.os.linux;
const IoUring = linux.IoUring;

// POLL constants not in std
const POLLRDHUP: i16 = 0x2000;

pub const Uring = struct {
    const Self = @This();

    allocator: Allocator,
    ring: IoUring,
    max_events: u32,
    // Track which sockets are being polled to avoid duplicate submissions
    poll_pending: std.AutoHashMap(Socket, usize),

    pub fn init(allocator: Allocator, max_events: u32) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Initialize io_uring with the specified queue depth (max 65535)
        const entries: u16 = @intCast(@min(max_events, 65535));
        self.ring = try IoUring.init(entries, 0);
        errdefer self.ring.deinit();

        self.* = .{
            .allocator = allocator,
            .ring = self.ring,
            .max_events = max_events,
            .poll_pending = std.AutoHashMap(Socket, usize).init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.poll_pending.deinit();
        self.ring.deinit();
        self.allocator.destroy(self);
    }

    /// Add a socket to be monitored for read events using poll
    pub fn addSocket(self: *Self, socket: Socket, user_data: usize) !void {
        // Queue a poll operation for POLLIN
        _ = try self.ring.poll_add(
            encodeUserData(socket, user_data),
            socket,
            linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR | POLLRDHUP,
        );
        try self.poll_pending.put(socket, user_data);
    }

    /// Remove a socket from monitoring
    pub fn removeSocket(self: *Self, socket: Socket) void {
        // Cancel any pending poll operations for this socket
        if (self.poll_pending.get(socket)) |user_data| {
            // poll_remove takes user_data and flags
            _ = self.ring.poll_remove(encodeUserData(socket, user_data), 0) catch {};
            _ = self.poll_pending.remove(socket);
        }
    }

    /// Modify socket to watch for write readiness
    pub fn watchWrite(self: *Self, socket: Socket, user_data: usize) !void {
        // Cancel existing poll and add new one with OUT
        self.removeSocket(socket);
        _ = try self.ring.poll_add(
            encodeUserData(socket, user_data),
            socket,
            linux.POLL.IN | linux.POLL.OUT | linux.POLL.HUP | linux.POLL.ERR | POLLRDHUP,
        );
        try self.poll_pending.put(socket, user_data);
    }

    /// Modify socket to watch for read readiness only
    pub fn watchRead(self: *Self, socket: Socket, user_data: usize) !void {
        // Cancel existing poll and add new one
        self.removeSocket(socket);
        _ = try self.ring.poll_add(
            encodeUserData(socket, user_data),
            socket,
            linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR | POLLRDHUP,
        );
        try self.poll_pending.put(socket, user_data);
    }

    /// Submit pending operations to the kernel
    pub fn submit(self: *Self) !void {
        _ = try self.ring.submit();
    }

    /// Wait for I/O events
    pub fn wait(self: *Self, events: []Event, timeout_ms: i32) ![]Event {
        _ = timeout_ms; // io_uring submit_and_wait doesn't take timeout in this API version

        // Submit any pending operations first
        _ = try self.ring.submit();

        // Wait for at least one completion
        _ = self.ring.submit_and_wait(1) catch |err| {
            if (err == error.SignalInterrupt) return events[0..0];
            return err;
        };

        // Process completions using copy_cqes
        var cqes: [64]linux.io_uring_cqe = undefined;
        const n = try self.ring.copy_cqes(&cqes, 0);

        var count: usize = 0;
        for (cqes[0..n]) |cqe| {
            if (count >= events.len) break;

            const socket: Socket = @intCast(cqe.user_data & 0xFFFFFFFF);
            const user_data: usize = @intCast(cqe.user_data >> 32);

            // Remove from pending since poll completed
            _ = self.poll_pending.remove(socket);

            // Determine event type from poll results
            var event_type: EventType = .read;
            if (cqe.res < 0) {
                event_type = .error_event;
            } else {
                const poll_events: u32 = @intCast(cqe.res);
                if (poll_events & (linux.POLL.HUP | @as(u32, @intCast(POLLRDHUP))) != 0) {
                    event_type = .close;
                } else if (poll_events & linux.POLL.ERR != 0) {
                    event_type = .error_event;
                } else if (poll_events & linux.POLL.OUT != 0) {
                    event_type = .write;
                } else if (poll_events & linux.POLL.IN != 0) {
                    event_type = .read;
                }
            }

            events[count] = .{
                .socket = socket,
                .event_type = event_type,
                .user_data = user_data,
            };
            count += 1;

            // Re-arm the poll for this socket if it's still valid
            // (io_uring poll is one-shot by default)
            if (event_type != .close and event_type != .error_event) {
                _ = self.ring.poll_add(
                    encodeUserData(socket, user_data),
                    socket,
                    linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR | POLLRDHUP,
                ) catch {};
                self.poll_pending.put(socket, user_data) catch {};
            }
        }

        return events[0..count];
    }
};

/// Encode socket and user_data into a single u64
fn encodeUserData(socket: Socket, user_data: usize) u64 {
    return @as(u64, @intCast(socket)) | (@as(u64, user_data) << 32);
}

// Helper to create socket pair
fn createSocketPair() ![2]i32 {
    var sockets: [2]i32 = undefined;
    // SOCK_STREAM = 1, SOCK_CLOEXEC = 0x80000, SOCK_NONBLOCK = 0x800
    const rc = linux.socketpair(linux.AF.UNIX, 1 | 0x80000 | 0x800, 0, &sockets);
    if (rc != 0) return error.SocketPairFailed;
    return sockets;
}

// Helper to init uring, returns null if not available
fn initUring(allocator: Allocator) ?*Uring {
    return Uring.init(allocator, 1024) catch return null;
}

// Tests
test "uring init/deinit" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const uring = initUring(std.testing.allocator) orelse return error.SkipZigTest;
    defer uring.deinit();
}

test "uring socket lifecycle" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const uring = initUring(std.testing.allocator) orelse return error.SkipZigTest;
    defer uring.deinit();

    const sockets = try createSocketPair();
    defer {
        std.posix.close(sockets[0]);
        std.posix.close(sockets[1]);
    }

    try uring.addSocket(sockets[0], 42);
    try uring.submit();
    uring.removeSocket(sockets[0]);
}

test "uring read event detection" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const uring = initUring(std.testing.allocator) orelse return error.SkipZigTest;
    defer uring.deinit();

    const sockets = try createSocketPair();
    defer {
        std.posix.close(sockets[0]);
        std.posix.close(sockets[1]);
    }

    // Watch socket[0] for reads
    try uring.addSocket(sockets[0], 100);

    // Write to socket[1] - should trigger read on socket[0]
    const msg = "hello";
    _ = try std.posix.send(sockets[1], msg, 0);

    // Wait for event
    var events: [16]Event = undefined;
    const ready = try uring.wait(&events, 1000);

    try std.testing.expect(ready.len >= 1);
    try std.testing.expectEqual(@as(i32, sockets[0]), ready[0].socket);
    try std.testing.expectEqual(EventType.read, ready[0].event_type);
    try std.testing.expectEqual(@as(usize, 100), ready[0].user_data);
}

test "uring write event detection" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const uring = initUring(std.testing.allocator) orelse return error.SkipZigTest;
    defer uring.deinit();

    const sockets = try createSocketPair();
    defer {
        std.posix.close(sockets[0]);
        std.posix.close(sockets[1]);
    }

    // Watch for write readiness
    try uring.addSocket(sockets[0], 200);
    try uring.watchWrite(sockets[0], 200);

    // Socket should be immediately writable
    var events: [16]Event = undefined;
    const ready = try uring.wait(&events, 100);

    try std.testing.expect(ready.len >= 1);
    try std.testing.expectEqual(@as(i32, sockets[0]), ready[0].socket);
}

test "uring multiple sockets" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const uring = initUring(std.testing.allocator) orelse return error.SkipZigTest;
    defer uring.deinit();

    // Create 3 socket pairs
    var pairs: [3][2]i32 = undefined;
    for (&pairs, 0..) |*pair, i| {
        pair.* = try createSocketPair();
        try uring.addSocket(pair[0], i + 1);
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

    // Collect events (may need multiple waits due to io_uring batching)
    var events: [16]Event = undefined;
    var total_events: usize = 0;
    var attempts: usize = 0;
    while (total_events < 3 and attempts < 5) : (attempts += 1) {
        const ready = try uring.wait(&events, 100);
        total_events += ready.len;
    }

    try std.testing.expect(total_events >= 3);
}

test "uring close detection" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const uring = initUring(std.testing.allocator) orelse return error.SkipZigTest;
    defer uring.deinit();

    const sockets = try createSocketPair();
    defer std.posix.close(sockets[0]);

    // Watch socket[0]
    try uring.addSocket(sockets[0], 42);

    // Close the other end
    std.posix.close(sockets[1]);

    // Should get close/hangup event
    var events: [16]Event = undefined;
    const ready = try uring.wait(&events, 1000);

    try std.testing.expect(ready.len >= 1);
    try std.testing.expectEqual(@as(i32, sockets[0]), ready[0].socket);
    // Should be close or read (read returns 0 on closed connection)
    try std.testing.expect(ready[0].event_type == .close or ready[0].event_type == .read);
}

test "uring high connection count" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const uring = Uring.init(std.testing.allocator, 4096) catch return error.SkipZigTest;
    defer uring.deinit();

    const count = 100;
    var pairs: [count][2]i32 = undefined;
    var created: usize = 0;

    // Create many socket pairs
    for (&pairs, 0..) |*pair, i| {
        pair.* = createSocketPair() catch break;
        uring.addSocket(pair[0], i) catch break;
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

    // Submit and collect events
    try uring.submit();
    var events: [128]Event = undefined;
    const ready = try uring.wait(&events, 100);
    try std.testing.expect(ready.len > 0);
}
