//! Authentication and Authorization Hooks
//!
//! Zero-cost comptime hooks for ACL enforcement.

const std = @import("std");

/// Result of an auth check
pub const AuthResult = enum {
    allow,
    deny,
    /// Continue with default behavior
    continue_default,
};

/// Client connection context
pub const ClientContext = struct {
    client_id: []const u8,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    client_ip: ?[]const u8 = null,
};

/// Default no-op auth hooks - all operations allowed
pub const NoOpAuth = struct {
    /// Called when a client attempts to connect
    pub inline fn onConnect(_: ClientContext) AuthResult {
        return .allow;
    }

    /// Called when a client attempts to publish
    pub inline fn onPublish(_: []const u8, _: []const u8) AuthResult {
        return .allow;
    }

    /// Called when a client attempts to subscribe
    pub inline fn onSubscribe(_: []const u8, _: []const u8) AuthResult {
        return .allow;
    }

    /// Called when a message is about to be delivered
    pub inline fn onDeliver(_: []const u8, _: []const u8) AuthResult {
        return .allow;
    }
};

/// Check if a type implements the Auth interface
pub fn isValidAuth(comptime T: type) bool {
    return @hasDecl(T, "onConnect") and
        @hasDecl(T, "onPublish") and
        @hasDecl(T, "onSubscribe") and
        @hasDecl(T, "onDeliver");
}

test "NoOpAuth allows all" {
    const ctx = ClientContext{ .client_id = "test" };
    try std.testing.expectEqual(AuthResult.allow, NoOpAuth.onConnect(ctx));
    try std.testing.expectEqual(AuthResult.allow, NoOpAuth.onPublish("client", "topic"));
    try std.testing.expectEqual(AuthResult.allow, NoOpAuth.onSubscribe("client", "topic/#"));
    try std.testing.expectEqual(AuthResult.allow, NoOpAuth.onDeliver("client", "topic"));
}

test "isValidAuth" {
    try std.testing.expect(isValidAuth(NoOpAuth));
}
