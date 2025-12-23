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

// Tests
test "backend detection" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const backend = try detectBest(std.testing.allocator, 1024);
    defer backend.deinit();

    // Should get some backend
    _ = backend.name();
}
