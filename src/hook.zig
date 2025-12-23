//! Hook System for MQTT Broker
//!
//! Zero-cost comptime hooks for extensibility. Define custom hooks by
//! implementing the auth, logging, or metrics interfaces, then compose
//! them into a Hook type.
//!
//! Example:
//! ```
//! const MyHook = hook.Hook(.{
//!     .Auth = MyCustomAuth,
//!     .Logger = hook.StderrLogger,
//!     .Metrics = hook.AtomicMetrics,
//! });
//! ```

pub const auth = @import("hooks/auth.zig");
pub const logging = @import("hooks/logging.zig");
pub const metrics = @import("hooks/metrics.zig");

// Re-export types
pub const AuthResult = auth.AuthResult;
pub const ClientContext = auth.ClientContext;
pub const NoOpAuth = auth.NoOpAuth;

pub const LogLevel = logging.Level;
pub const LogEvent = logging.Event;
pub const NoOpLogger = logging.NoOpLogger;
pub const StderrLogger = logging.StderrLogger;

pub const Metric = metrics.Metric;
pub const NoOpMetrics = metrics.NoOpMetrics;
pub const AtomicMetrics = metrics.AtomicMetrics;

/// Hook configuration
pub const Config = struct {
    Auth: type = NoOpAuth,
    Logger: type = NoOpLogger,
    Metrics: type = NoOpMetrics,
};

/// Composable hook system
/// All hooks are resolved at comptime for zero runtime overhead
pub fn Hook(comptime config: Config) type {
    // Validate interfaces at comptime
    if (!auth.isValidAuth(config.Auth)) {
        @compileError("Auth type must implement onConnect, onPublish, onSubscribe, onDeliver");
    }
    if (!logging.isValidLogger(config.Logger)) {
        @compileError("Logger type must implement log");
    }
    if (!metrics.isValidMetrics(config.Metrics)) {
        @compileError("Metrics type must implement increment, incrementBy, decrement, gauge");
    }

    return struct {
        const Self = @This();

        pub const Auth = config.Auth;
        pub const Logger = config.Logger;
        pub const Metrics = config.Metrics;

        // Auth delegation
        pub inline fn onConnect(ctx: ClientContext) AuthResult {
            return Auth.onConnect(ctx);
        }

        pub inline fn onPublish(client_id: []const u8, topic: []const u8) AuthResult {
            return Auth.onPublish(client_id, topic);
        }

        pub inline fn onSubscribe(client_id: []const u8, filter: []const u8) AuthResult {
            return Auth.onSubscribe(client_id, filter);
        }

        pub inline fn onDeliver(client_id: []const u8, topic: []const u8) AuthResult {
            return Auth.onDeliver(client_id, topic);
        }

        // Logger delegation
        pub inline fn log(level: LogLevel, event: LogEvent) void {
            Logger.log(level, event);
        }

        // Metrics delegation (static for NoOp, needs instance for stateful)
        pub inline fn increment(metric: Metric) void {
            Metrics.increment(metric);
        }

        pub inline fn incrementBy(metric: Metric, value: u64) void {
            Metrics.incrementBy(metric, value);
        }

        pub inline fn decrement(metric: Metric) void {
            Metrics.decrement(metric);
        }

        pub inline fn gauge(metric: Metric, value: u64) void {
            Metrics.gauge(metric, value);
        }
    };
}

/// Default no-op hook - zero overhead when not using hooks
pub const NoOp = Hook(.{});

test "NoOp hook" {
    try @import("std").testing.expectEqual(AuthResult.allow, NoOp.onConnect(.{ .client_id = "test" }));
    try @import("std").testing.expectEqual(AuthResult.allow, NoOp.onPublish("test", "topic"));
    try @import("std").testing.expectEqual(AuthResult.allow, NoOp.onSubscribe("test", "topic/#"));
    try @import("std").testing.expectEqual(AuthResult.allow, NoOp.onDeliver("test", "topic"));

    NoOp.log(.info, .{ .connect = .{ .client_id = "test", .protocol_version = .v5_0, .clean_session = true } });

    NoOp.increment(.connections_total);
    NoOp.decrement(.connections_active);
    NoOp.incrementBy(.bytes_received, 1024);
    NoOp.gauge(.subscriptions_active, 42);
}

test "custom Hook composition" {
    const Custom = Hook(.{
        .Auth = NoOpAuth,
        .Logger = StderrLogger,
        .Metrics = NoOpMetrics,
    });

    try @import("std").testing.expectEqual(AuthResult.allow, Custom.onConnect(.{ .client_id = "test" }));
}

test {
    _ = @import("hooks/auth.zig");
    _ = @import("hooks/logging.zig");
    _ = @import("hooks/metrics.zig");
}
