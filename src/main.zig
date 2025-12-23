const std = @import("std");
const rawmq = @import("rawmq");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_path: []const u8 = "rawmq.toml";
    var cli_port: ?u16 = null;
    var cli_bind: ?[]const u8 = null;
    var cli_workers: ?u32 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i < args.len) {
                config_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i < args.len) {
                cli_port = std.fmt.parseInt(u16, args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--bind") or std.mem.eql(u8, arg, "-b")) {
            i += 1;
            if (i < args.len) {
                cli_bind = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--workers") or std.mem.eql(u8, arg, "-w")) {
            i += 1;
            if (i < args.len) {
                cli_workers = std.fmt.parseInt(u32, args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            std.debug.print("rawmq {s} - MQTT broker supporting v3.1.1 and v5.0\n", .{rawmq.version});
            return;
        }
    }

    // Load config from file (uses defaults if file not found)
    var config = try rawmq.config.Config.load(allocator, config_path);

    // CLI overrides
    if (cli_port) |p| config.server.port = p;
    if (cli_bind) |b| config.server.bind = b;
    if (cli_workers) |w| config.server.workers = w;

    // Create broker with config
    const broker = try rawmq.Broker.init(allocator, .{
        .max_connections = config.limits.max_connections,
        .max_packet_size = config.limits.max_packet_size,
        .max_inflight_messages = config.limits.max_inflight,
        .default_keep_alive = config.session.default_keep_alive,
        .max_keep_alive = config.session.max_keep_alive,
        .max_qos = @enumFromInt(config.mqtt.max_qos),
        .retain_available = config.mqtt.retain_available,
        .wildcard_subscription_available = config.mqtt.wildcard_subscriptions,
        .subscription_identifier_available = config.mqtt.subscription_identifiers,
        .shared_subscription_available = config.mqtt.shared_subscriptions,
        .worker_threads = config.server.workers,
    });
    defer broker.deinit();

    // Create and run server
    const server = try rawmq.Server.init(allocator, .{
        .bind_address = config.server.bind,
        .port = config.server.port,
    }, broker);
    defer server.deinit();

    std.debug.print(
        \\
        \\  ┌─────────────────────────────────────────┐
        \\  │           rawmq MQTT Broker             │
        \\  │     Supporting MQTT v3.1.1 & v5.0       │
        \\  └─────────────────────────────────────────┘
        \\
        \\
    , .{});

    try server.run();
}

fn printHelp() void {
    const help =
        \\rawmq - High-performance MQTT broker
        \\
        \\Usage: rawmq [OPTIONS]
        \\
        \\Options:
        \\  -c, --config <FILE>    Config file path (default: rawmq.toml)
        \\  -p, --port <PORT>      Port to listen on (overrides config)
        \\  -b, --bind <ADDR>      Address to bind to (overrides config)
        \\  -w, --workers <NUM>    Number of worker threads (overrides config)
        \\  -h, --help             Show this help message
        \\  -v, --version          Show version information
        \\
        \\Config file uses TOML format with environment variable substitution:
        \\  ${VAR}           - substitute with env var value
        \\  ${VAR:-default}  - substitute with env var or default
        \\
        \\Examples:
        \\  rawmq                      Start with defaults
        \\  rawmq -c /etc/rawmq.toml   Use custom config file
        \\  rawmq -p 1884              Override port from CLI
        \\
    ;
    std.debug.print("{s}", .{help});
}

test "main tests" {
    _ = @import("rawmq");
}
