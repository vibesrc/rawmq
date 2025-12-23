//! Logging Hooks
//!
//! Hooks for custom logging of MQTT events.

const std = @import("std");
const protocol = @import("../protocol.zig");

/// Log level
pub const Level = enum {
    debug,
    info,
    warn,
    err,
};

/// Event types that can be logged
pub const Event = union(enum) {
    connect: struct {
        client_id: []const u8,
        protocol_version: protocol.ProtocolVersion,
        clean_session: bool,
    },
    disconnect: struct {
        client_id: []const u8,
        reason: ?protocol.ReasonCode,
    },
    publish: struct {
        client_id: []const u8,
        topic: []const u8,
        qos: protocol.QoS,
        payload_len: usize,
    },
    subscribe: struct {
        client_id: []const u8,
        filter: []const u8,
        qos: protocol.QoS,
    },
    unsubscribe: struct {
        client_id: []const u8,
        filter: []const u8,
    },
};

/// Default no-op logger
pub const NoOpLogger = struct {
    pub inline fn log(_: Level, _: Event) void {}
};

/// Simple stderr logger
pub const StderrLogger = struct {
    pub fn log(level: Level, event: Event) void {
        const level_str = switch (level) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };

        switch (event) {
            .connect => |e| std.debug.print("[{s}] CONNECT client={s} version={s} clean={}\n", .{
                level_str,
                e.client_id,
                @tagName(e.protocol_version),
                e.clean_session,
            }),
            .disconnect => |e| std.debug.print("[{s}] DISCONNECT client={s}\n", .{
                level_str,
                e.client_id,
            }),
            .publish => |e| std.debug.print("[{s}] PUBLISH client={s} topic={s} qos={d} len={d}\n", .{
                level_str,
                e.client_id,
                e.topic,
                @intFromEnum(e.qos),
                e.payload_len,
            }),
            .subscribe => |e| std.debug.print("[{s}] SUBSCRIBE client={s} filter={s} qos={d}\n", .{
                level_str,
                e.client_id,
                e.filter,
                @intFromEnum(e.qos),
            }),
            .unsubscribe => |e| std.debug.print("[{s}] UNSUBSCRIBE client={s} filter={s}\n", .{
                level_str,
                e.client_id,
                e.filter,
            }),
        }
    }
};

/// Check if a type implements the Logger interface
pub fn isValidLogger(comptime T: type) bool {
    return @hasDecl(T, "log");
}

test "NoOpLogger compiles" {
    NoOpLogger.log(.info, .{ .connect = .{
        .client_id = "test",
        .protocol_version = .v5_0,
        .clean_session = true,
    } });
}

test "isValidLogger" {
    try std.testing.expect(isValidLogger(NoOpLogger));
    try std.testing.expect(isValidLogger(StderrLogger));
}
