//! rawmq - High-performance MQTT broker library
//! Supports MQTT v3.1.1 and v5.0 with zero-copy parsing

const std = @import("std");

// Re-export public modules
pub const protocol = @import("protocol.zig");
pub const topic = @import("topic.zig");
pub const session = @import("session.zig");
pub const broker = @import("broker.zig");
pub const server = @import("server.zig");
pub const hook = @import("hook.zig");
pub const config = @import("config.zig");

// Convenient type aliases
pub const Protocol = protocol;
pub const Broker = broker.Broker;
pub const Server = server.Server;
pub const Session = session.Session;
pub const TopicTree = topic.TopicTree;

// Version info
pub const version = "0.1.0";
pub const mqtt_versions = [_][]const u8{ "3.1.1", "5.0" };

test {
    // Run all module tests
    std.testing.refAllDecls(@This());
    _ = @import("protocol.zig");
    _ = @import("topic.zig");
    _ = @import("session.zig");
    _ = @import("broker.zig");
    _ = @import("server.zig");
    _ = @import("hook.zig");
    _ = @import("config.zig");
}
