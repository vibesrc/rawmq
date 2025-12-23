const std = @import("std");
const encoding = @import("encoding.zig");

/// MQTT v5.0 Property identifiers
pub const PropertyId = enum(u8) {
    payload_format_indicator = 0x01,
    message_expiry_interval = 0x02,
    content_type = 0x03,
    response_topic = 0x08,
    correlation_data = 0x09,
    subscription_identifier = 0x0B,
    session_expiry_interval = 0x11,
    assigned_client_identifier = 0x12,
    server_keep_alive = 0x13,
    authentication_method = 0x15,
    authentication_data = 0x16,
    request_problem_information = 0x17,
    will_delay_interval = 0x18,
    request_response_information = 0x19,
    response_information = 0x1A,
    server_reference = 0x1C,
    reason_string = 0x1F,
    receive_maximum = 0x21,
    topic_alias_maximum = 0x22,
    topic_alias = 0x23,
    maximum_qos = 0x24,
    retain_available = 0x25,
    user_property = 0x26,
    maximum_packet_size = 0x27,
    wildcard_subscription_available = 0x28,
    subscription_identifier_available = 0x29,
    shared_subscription_available = 0x2A,
    _,
};

/// Property value types
pub const PropertyValue = union(enum) {
    byte: u8,
    two_byte_int: u16,
    four_byte_int: u32,
    var_int: u32,
    string: []const u8,
    binary: []const u8,
    string_pair: struct { []const u8, []const u8 },
};

/// v5.0 Properties - stored as raw slice for zero-copy
pub const Properties = struct {
    data: []const u8,

    pub const Iterator = struct {
        data: []const u8,
        pos: usize = 0,

        pub const Property = struct {
            id: PropertyId,
            value: PropertyValue,
        };

        pub fn next(self: *Iterator) ?Property {
            if (self.pos >= self.data.len) return null;

            const id: PropertyId = @enumFromInt(self.data[self.pos]);
            self.pos += 1;

            const value = self.readPropertyValue(id) catch return null;
            return .{ .id = id, .value = value };
        }

        fn readPropertyValue(self: *Iterator, id: PropertyId) !PropertyValue {
            return switch (id) {
                .payload_format_indicator,
                .request_problem_information,
                .request_response_information,
                .maximum_qos,
                .retain_available,
                .wildcard_subscription_available,
                .subscription_identifier_available,
                .shared_subscription_available,
                => .{ .byte = try self.readByte() },

                .server_keep_alive,
                .receive_maximum,
                .topic_alias_maximum,
                .topic_alias,
                => .{ .two_byte_int = try self.readU16() },

                .message_expiry_interval,
                .session_expiry_interval,
                .will_delay_interval,
                .maximum_packet_size,
                => .{ .four_byte_int = try self.readU32() },

                .subscription_identifier,
                => .{ .var_int = try self.readVarInt() },

                .content_type,
                .response_topic,
                .assigned_client_identifier,
                .authentication_method,
                .response_information,
                .server_reference,
                .reason_string,
                => .{ .string = try self.readString() },

                .correlation_data,
                .authentication_data,
                => .{ .binary = try self.readBinary() },

                .user_property,
                => .{ .string_pair = .{ try self.readString(), try self.readString() } },

                _ => error.InvalidPropertyId,
            };
        }

        fn readByte(self: *Iterator) !u8 {
            if (self.pos >= self.data.len) return error.PayloadTooShort;
            const b = self.data[self.pos];
            self.pos += 1;
            return b;
        }

        fn readU16(self: *Iterator) !u16 {
            if (self.pos + 2 > self.data.len) return error.PayloadTooShort;
            const val = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
            self.pos += 2;
            return val;
        }

        fn readU32(self: *Iterator) !u32 {
            if (self.pos + 4 > self.data.len) return error.PayloadTooShort;
            const val = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
            self.pos += 4;
            return val;
        }

        fn readVarInt(self: *Iterator) !u32 {
            var result: u32 = 0;
            var shift: u5 = 0;
            while (true) {
                if (self.pos >= self.data.len) return error.PayloadTooShort;
                const b = self.data[self.pos];
                self.pos += 1;
                result |= @as(u32, b & 0x7F) << shift;
                if (b & 0x80 == 0) break;
                shift += 7;
                if (shift > 28) return error.InvalidRemainingLength;
            }
            return result;
        }

        fn readString(self: *Iterator) ![]const u8 {
            const len = try self.readU16();
            if (self.pos + len > self.data.len) return error.PayloadTooShort;
            const str = self.data[self.pos..][0..len];
            self.pos += len;
            return str;
        }

        fn readBinary(self: *Iterator) ![]const u8 {
            return self.readString(); // Same encoding
        }
    };

    pub fn iterator(self: Properties) Iterator {
        return .{ .data = self.data };
    }
};

// Tests
const testing = std.testing;

test "property iterator" {
    // Build properties: Subscription Identifier (0x0B) = 42
    const props_data = [_]u8{ 0x0B, 42 };
    const props = Properties{ .data = &props_data };

    var iter = props.iterator();
    const prop = iter.next();
    try testing.expect(prop != null);
    try testing.expectEqual(PropertyId.subscription_identifier, prop.?.id);
    try testing.expectEqual(@as(u32, 42), prop.?.value.var_int);
    try testing.expect(iter.next() == null);
}
