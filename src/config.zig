//! Configuration System
//!
//! TOML-based configuration with environment variable substitution.
//! Supports ${VAR} and ${VAR:-default} syntax.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Server configuration
pub const Server = struct {
    bind: []const u8 = "0.0.0.0",
    port: u16 = 1883,
    ws_port: ?u16 = null,
    ws_path: []const u8 = "/mqtt",
    workers: u32 = 0,
    backlog: u31 = 4096,
    recv_buffer_size: u32 = 65536,
    max_events: u32 = 4096,
};

/// Connection and message limits
pub const Limits = struct {
    max_connections: u32 = 100000,
    max_packet_size: u32 = 1048576,
    max_inflight: u16 = 32,
    max_queued_messages: u32 = 1000,
    retry_interval: u32 = 30,
};

/// Session settings
pub const Session = struct {
    default_keep_alive: u16 = 60,
    max_keep_alive: u16 = 65535,
    expiry_check_interval: u32 = 60,
    max_topic_aliases: u16 = 65535,
};

/// MQTT protocol settings
pub const Mqtt = struct {
    max_qos: u2 = 2,
    retain_available: bool = true,
    wildcard_subscriptions: bool = true,
    subscription_identifiers: bool = true,
    shared_subscriptions: bool = true,
};

/// Logging settings
pub const Log = struct {
    level: Level = .info,

    pub const Level = enum {
        err,
        warn,
        info,
        debug,
    };
};

/// Metrics settings
pub const Metrics = struct {
    enabled: bool = true,
};

/// Authentication settings
pub const Auth = struct {
    enabled: bool = false,
    allow_anonymous: bool = true,
};

/// Full configuration
pub const Config = struct {
    server: Server = .{},
    limits: Limits = .{},
    session: Session = .{},
    mqtt: Mqtt = .{},
    log: Log = .{},
    metrics: Metrics = .{},
    auth: Auth = .{},

    /// Load config from TOML file
    pub fn load(allocator: Allocator, path: []const u8) !Config {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return Config{}; // Use defaults
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        return parse(allocator, content);
    }

    /// Parse TOML content into Config
    pub fn parse(allocator: Allocator, content: []const u8) !Config {
        var config = Config{};
        var parser = TomlParser.init(allocator, content);
        defer parser.deinit();

        try parser.parseInto(&config);
        return config;
    }
};

/// Simple TOML parser for config files
pub const TomlParser = struct {
    allocator: Allocator,
    content: []const u8,
    pos: usize = 0,
    current_section: ?[]const u8 = null,
    // Store allocated strings for cleanup
    strings: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(allocator: Allocator, content: []const u8) TomlParser {
        return .{
            .allocator = allocator,
            .content = content,
        };
    }

    pub fn deinit(self: *TomlParser) void {
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit(self.allocator);
    }

    pub fn parseInto(self: *TomlParser, config: *Config) !void {
        while (self.pos < self.content.len) {
            self.skipWhitespaceAndComments();
            if (self.pos >= self.content.len) break;

            if (self.content[self.pos] == '[') {
                // Section header
                self.current_section = try self.parseSection();
            } else if (self.isIdentChar(self.content[self.pos])) {
                // Key-value pair
                const key = self.parseKey();
                self.skipWhitespace();
                if (self.pos < self.content.len and self.content[self.pos] == '=') {
                    self.pos += 1;
                    self.skipWhitespace();
                    try self.setValue(config, key);
                }
            }
            self.skipToNextLine();
        }
    }

    fn setValue(self: *TomlParser, config: *Config, key: []const u8) !void {
        const section = self.current_section orelse "";

        if (std.mem.eql(u8, section, "server")) {
            if (std.mem.eql(u8, key, "bind")) {
                config.server.bind = try self.parseString();
            } else if (std.mem.eql(u8, key, "port")) {
                config.server.port = try self.parseInt(u16);
            } else if (std.mem.eql(u8, key, "ws_port")) {
                config.server.ws_port = try self.parseInt(u16);
            } else if (std.mem.eql(u8, key, "ws_path")) {
                config.server.ws_path = try self.parseString();
            } else if (std.mem.eql(u8, key, "workers")) {
                config.server.workers = try self.parseInt(u32);
            } else if (std.mem.eql(u8, key, "backlog")) {
                config.server.backlog = try self.parseInt(u31);
            } else if (std.mem.eql(u8, key, "recv_buffer_size")) {
                config.server.recv_buffer_size = try self.parseInt(u32);
            } else if (std.mem.eql(u8, key, "max_events")) {
                config.server.max_events = try self.parseInt(u32);
            }
        } else if (std.mem.eql(u8, section, "limits")) {
            if (std.mem.eql(u8, key, "max_connections")) {
                config.limits.max_connections = try self.parseInt(u32);
            } else if (std.mem.eql(u8, key, "max_packet_size")) {
                config.limits.max_packet_size = try self.parseInt(u32);
            } else if (std.mem.eql(u8, key, "max_inflight")) {
                config.limits.max_inflight = try self.parseInt(u16);
            } else if (std.mem.eql(u8, key, "max_queued_messages")) {
                config.limits.max_queued_messages = try self.parseInt(u32);
            } else if (std.mem.eql(u8, key, "retry_interval")) {
                config.limits.retry_interval = try self.parseInt(u32);
            }
        } else if (std.mem.eql(u8, section, "session")) {
            if (std.mem.eql(u8, key, "default_keep_alive")) {
                config.session.default_keep_alive = try self.parseInt(u16);
            } else if (std.mem.eql(u8, key, "max_keep_alive")) {
                config.session.max_keep_alive = try self.parseInt(u16);
            } else if (std.mem.eql(u8, key, "expiry_check_interval")) {
                config.session.expiry_check_interval = try self.parseInt(u32);
            } else if (std.mem.eql(u8, key, "max_topic_aliases")) {
                config.session.max_topic_aliases = try self.parseInt(u16);
            }
        } else if (std.mem.eql(u8, section, "mqtt")) {
            if (std.mem.eql(u8, key, "max_qos")) {
                config.mqtt.max_qos = try self.parseInt(u2);
            } else if (std.mem.eql(u8, key, "retain_available")) {
                config.mqtt.retain_available = try self.parseBool();
            } else if (std.mem.eql(u8, key, "wildcard_subscriptions")) {
                config.mqtt.wildcard_subscriptions = try self.parseBool();
            } else if (std.mem.eql(u8, key, "subscription_identifiers")) {
                config.mqtt.subscription_identifiers = try self.parseBool();
            } else if (std.mem.eql(u8, key, "shared_subscriptions")) {
                config.mqtt.shared_subscriptions = try self.parseBool();
            }
        } else if (std.mem.eql(u8, section, "log")) {
            if (std.mem.eql(u8, key, "level")) {
                const level_str = try self.parseString();
                config.log.level = std.meta.stringToEnum(Log.Level, level_str) orelse .info;
            }
        } else if (std.mem.eql(u8, section, "metrics")) {
            if (std.mem.eql(u8, key, "enabled")) {
                config.metrics.enabled = try self.parseBool();
            }
        } else if (std.mem.eql(u8, section, "auth")) {
            if (std.mem.eql(u8, key, "enabled")) {
                config.auth.enabled = try self.parseBool();
            } else if (std.mem.eql(u8, key, "allow_anonymous")) {
                config.auth.allow_anonymous = try self.parseBool();
            }
        }
    }

    fn parseSection(self: *TomlParser) ![]const u8 {
        self.pos += 1; // skip '['
        const start = self.pos;
        while (self.pos < self.content.len and self.content[self.pos] != ']' and self.content[self.pos] != '\n') {
            self.pos += 1;
        }
        const section = self.content[start..self.pos];
        if (self.pos < self.content.len and self.content[self.pos] == ']') {
            self.pos += 1;
        }
        return section;
    }

    fn parseKey(self: *TomlParser) []const u8 {
        const start = self.pos;
        while (self.pos < self.content.len and (self.isIdentChar(self.content[self.pos]) or self.content[self.pos] == '_')) {
            self.pos += 1;
        }
        return self.content[start..self.pos];
    }

    fn parseString(self: *TomlParser) ![]const u8 {
        if (self.pos >= self.content.len) return "";

        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        const quote = self.content[self.pos] == '"';
        if (quote) self.pos += 1;

        const start = self.pos;
        while (self.pos < self.content.len) {
            const c = self.content[self.pos];
            if (quote and c == '"') break;
            if (!quote and (c == '\n' or c == '#' or c == ' ' or c == '\t')) break;
            self.pos += 1;
        }

        const raw = self.content[start..self.pos];
        if (quote and self.pos < self.content.len) self.pos += 1; // skip closing quote

        // Process env var substitution
        var i: usize = 0;
        while (i < raw.len) {
            if (i + 1 < raw.len and raw[i] == '$' and raw[i + 1] == '{') {
                // Find closing brace
                const env_start = i + 2;
                var env_end = env_start;
                while (env_end < raw.len and raw[env_end] != '}') {
                    env_end += 1;
                }
                if (env_end < raw.len) {
                    const env_expr = raw[env_start..env_end];
                    // Check for default value
                    if (std.mem.indexOf(u8, env_expr, ":-")) |sep| {
                        const var_name = env_expr[0..sep];
                        const default = env_expr[sep + 2 ..];
                        const value = std.posix.getenv(var_name) orelse default;
                        try result.appendSlice(self.allocator, value);
                    } else {
                        const value = std.posix.getenv(env_expr) orelse "";
                        try result.appendSlice(self.allocator, value);
                    }
                    i = env_end + 1;
                    continue;
                }
            }
            try result.append(self.allocator, raw[i]);
            i += 1;
        }

        const owned = try result.toOwnedSlice(self.allocator);
        try self.strings.append(self.allocator, owned);
        return owned;
    }

    fn parseInt(self: *TomlParser, comptime T: type) !T {
        self.skipWhitespace();
        const start = self.pos;
        while (self.pos < self.content.len and (std.ascii.isDigit(self.content[self.pos]) or self.content[self.pos] == '-')) {
            self.pos += 1;
        }
        const str = self.content[start..self.pos];
        return std.fmt.parseInt(T, str, 10) catch 0;
    }

    fn parseBool(self: *TomlParser) !bool {
        self.skipWhitespace();
        const start = self.pos;
        while (self.pos < self.content.len and std.ascii.isAlphabetic(self.content[self.pos])) {
            self.pos += 1;
        }
        const str = self.content[start..self.pos];
        return std.mem.eql(u8, str, "true");
    }

    fn skipWhitespace(self: *TomlParser) void {
        while (self.pos < self.content.len and (self.content[self.pos] == ' ' or self.content[self.pos] == '\t')) {
            self.pos += 1;
        }
    }

    fn skipWhitespaceAndComments(self: *TomlParser) void {
        while (self.pos < self.content.len) {
            const c = self.content[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (c == '#') {
                self.skipToNextLine();
            } else {
                break;
            }
        }
    }

    fn skipToNextLine(self: *TomlParser) void {
        while (self.pos < self.content.len and self.content[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.content.len) self.pos += 1;
    }

    fn isIdentChar(self: *TomlParser, c: u8) bool {
        _ = self;
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
    }
};

// Tests
const testing = std.testing;

test "parse empty config" {
    const config = try Config.parse(testing.allocator, "");
    try testing.expectEqual(@as(u16, 1883), config.server.port);
    try testing.expectEqual(true, config.mqtt.retain_available);
}

test "parse server section" {
    const toml =
        \\[server]
        \\port = 1884
        \\workers = 4
    ;
    const config = try Config.parse(testing.allocator, toml);
    try testing.expectEqual(@as(u16, 1884), config.server.port);
    try testing.expectEqual(@as(u32, 4), config.server.workers);
}

test "parse mqtt section with bools" {
    const toml =
        \\[mqtt]
        \\max_qos = 1
        \\retain_available = false
        \\shared_subscriptions = true
    ;
    const config = try Config.parse(testing.allocator, toml);
    try testing.expectEqual(@as(u2, 1), config.mqtt.max_qos);
    try testing.expectEqual(false, config.mqtt.retain_available);
    try testing.expectEqual(true, config.mqtt.shared_subscriptions);
}

test "parse with comments" {
    const toml =
        \\# This is a comment
        \\[server]
        \\port = 1885 # inline comment
    ;
    const config = try Config.parse(testing.allocator, toml);
    try testing.expectEqual(@as(u16, 1885), config.server.port);
}

test "env var substitution" {
    // This test relies on environment, so just test the parser doesn't crash
    const toml =
        \\[server]
        \\bind = "${RAWMQ_BIND:-0.0.0.0}"
    ;
    const config = try Config.parse(testing.allocator, toml);
    try testing.expect(config.server.bind.len > 0);
}
