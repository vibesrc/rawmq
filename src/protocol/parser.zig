const std = @import("std");
const types = @import("types.zig");
const encoding = @import("encoding.zig");
const properties = @import("properties.zig");
const err = @import("error.zig");

const ParseError = err.ParseError;
const ProtocolVersion = types.ProtocolVersion;
const PacketType = types.PacketType;
const QoS = types.QoS;
const FixedHeader = types.FixedHeader;
const Packet = types.Packet;
const ConnectPacket = types.ConnectPacket;
const ConnectFlags = types.ConnectFlags;
const PublishPacket = types.PublishPacket;
const SubscribePacket = types.SubscribePacket;
const UnsubscribePacket = types.UnsubscribePacket;
const TopicFilter = types.TopicFilter;
const AckPacket = types.AckPacket;
const DisconnectPacket = types.DisconnectPacket;
const AuthPacket = types.AuthPacket;
const Properties = properties.Properties;
const ReasonCode = err.ReasonCode;

/// Parse fixed header from buffer
pub fn parseFixedHeader(data: []const u8) ParseError!FixedHeader {
    if (data.len < 2) return error.IncompletePacket;

    const byte1 = data[0];
    const packet_type: PacketType = @enumFromInt(byte1 >> 4);
    const flags: u4 = @truncate(byte1 & 0x0F);

    // Validate reserved packet types
    if (packet_type == .reserved) return error.InvalidPacketType;

    const var_int = try encoding.decodeVarInt(data[1..]);

    return .{
        .packet_type = packet_type,
        .flags = flags,
        .remaining_length = var_int.value,
        .header_len = 1 + var_int.len,
    };
}

/// Check if we have a complete packet in the buffer
pub fn packetLength(data: []const u8) ParseError!usize {
    const header = try parseFixedHeader(data);
    return header.header_len + header.remaining_length;
}

/// Zero-copy packet parser
pub const Parser = struct {
    version: ProtocolVersion = .v3_1_1,
    // Scratch space for subscribe filters (avoids allocation in hot path)
    filter_scratch: [64]TopicFilter = undefined,
    unsubscribe_scratch: [64][]const u8 = undefined,

    /// Parse a complete packet from buffer (zero-copy)
    pub fn parse(self: *Parser, data: []const u8) ParseError!Packet {
        const header = try parseFixedHeader(data);
        const payload = data[header.header_len..][0..header.remaining_length];

        return switch (header.packet_type) {
            .connect => .{ .connect = try self.parseConnect(payload) },
            .publish => .{ .publish = try self.parsePublish(header.flags, payload) },
            .puback => .{ .puback = try self.parseAck(payload) },
            .pubrec => .{ .pubrec = try self.parseAck(payload) },
            .pubrel => .{ .pubrel = try self.parseAck(payload) },
            .pubcomp => .{ .pubcomp = try self.parseAck(payload) },
            .subscribe => .{ .subscribe = try self.parseSubscribe(payload) },
            .unsubscribe => .{ .unsubscribe = try self.parseUnsubscribe(payload) },
            .pingreq => .{ .pingreq = {} },
            .disconnect => .{ .disconnect = try self.parseDisconnect(payload) },
            .auth => .{ .auth = try self.parseAuth(payload) },
            else => error.InvalidPacketType,
        };
    }

    fn parseConnect(self: *Parser, data: []const u8) ParseError!ConnectPacket {
        var pos: usize = 0;

        // Protocol name
        const name_len = encoding.readU16(data, &pos) orelse return error.PayloadTooShort;
        if (pos + name_len > data.len) return error.PayloadTooShort;
        const name = data[pos..][0..name_len];
        pos += name_len;

        // Validate protocol name
        if (!std.mem.eql(u8, name, "MQTT") and !std.mem.eql(u8, name, "MQIsdp")) {
            return error.InvalidProtocolName;
        }

        // Protocol version
        if (pos >= data.len) return error.PayloadTooShort;
        const version_byte = data[pos];
        pos += 1;

        const version: ProtocolVersion = switch (version_byte) {
            4 => .v3_1_1,
            5 => .v5_0,
            else => return error.InvalidProtocolVersion,
        };
        self.version = version;

        // Connect flags
        if (pos >= data.len) return error.PayloadTooShort;
        const flags: ConnectFlags = @bitCast(data[pos]);
        pos += 1;

        // Validate reserved bit
        if (flags.reserved != 0) return error.InvalidFlags;

        // Keep alive
        const keep_alive = encoding.readU16(data, &pos) orelse return error.PayloadTooShort;

        // v5.0 properties
        var props: ?Properties = null;
        if (version == .v5_0) {
            props = try self.parseProperties(data, &pos);
        }

        // Payload: Client ID
        const client_id_len = encoding.readU16(data, &pos) orelse return error.PayloadTooShort;
        if (pos + client_id_len > data.len) return error.PayloadTooShort;
        const client_id = data[pos..][0..client_id_len];
        pos += client_id_len;

        // Will properties and message
        var will_properties: ?Properties = null;
        var will_topic: ?[]const u8 = null;
        var will_payload: ?[]const u8 = null;

        if (flags.will_flag) {
            if (version == .v5_0) {
                will_properties = try self.parseProperties(data, &pos);
            }

            const topic_len = encoding.readU16(data, &pos) orelse return error.PayloadTooShort;
            if (pos + topic_len > data.len) return error.PayloadTooShort;
            will_topic = data[pos..][0..topic_len];
            pos += topic_len;

            const payload_len = encoding.readU16(data, &pos) orelse return error.PayloadTooShort;
            if (pos + payload_len > data.len) return error.PayloadTooShort;
            will_payload = data[pos..][0..payload_len];
            pos += payload_len;
        }

        // Username
        var username: ?[]const u8 = null;
        if (flags.username_flag) {
            const len = encoding.readU16(data, &pos) orelse return error.PayloadTooShort;
            if (pos + len > data.len) return error.PayloadTooShort;
            username = data[pos..][0..len];
            pos += len;
        }

        // Password
        var password: ?[]const u8 = null;
        if (flags.password_flag) {
            const len = encoding.readU16(data, &pos) orelse return error.PayloadTooShort;
            if (pos + len > data.len) return error.PayloadTooShort;
            password = data[pos..][0..len];
            pos += len;
        }

        return .{
            .protocol_version = version,
            .flags = flags,
            .keep_alive = keep_alive,
            .client_id = client_id,
            .will_topic = will_topic,
            .will_payload = will_payload,
            .username = username,
            .password = password,
            .properties = props,
            .will_properties = will_properties,
        };
    }

    fn parsePublish(self: *Parser, flags: u4, data: []const u8) ParseError!PublishPacket {
        var pos: usize = 0;

        const dup = (flags & 0x08) != 0;
        const qos_val: u2 = @truncate((flags >> 1) & 0x03);
        if (qos_val == 3) return error.InvalidQoS;
        const qos: QoS = @enumFromInt(qos_val);
        const retain = (flags & 0x01) != 0;

        // Topic name
        const topic_len = encoding.readU16(data, &pos) orelse return error.PayloadTooShort;
        if (pos + topic_len > data.len) return error.PayloadTooShort;
        const topic = data[pos..][0..topic_len];
        pos += topic_len;

        // Packet ID (only for QoS > 0)
        var packet_id: ?u16 = null;
        if (qos != .at_most_once) {
            packet_id = encoding.readU16(data, &pos) orelse return error.PayloadTooShort;
        }

        // v5.0 properties
        var props: ?Properties = null;
        if (self.version == .v5_0) {
            props = try self.parseProperties(data, &pos);
        }

        // Payload is remainder
        const payload = data[pos..];

        return .{
            .dup = dup,
            .qos = qos,
            .retain = retain,
            .topic = topic,
            .packet_id = packet_id,
            .payload = payload,
            .properties = props,
        };
    }

    fn parseSubscribe(self: *Parser, data: []const u8) ParseError!SubscribePacket {
        var pos: usize = 0;

        const packet_id = encoding.readU16(data, &pos) orelse return error.PayloadTooShort;

        // v5.0 properties
        var props: ?Properties = null;
        if (self.version == .v5_0) {
            props = try self.parseProperties(data, &pos);
        }

        // Parse topic filters into scratch space
        var filter_count: usize = 0;
        while (pos < data.len) {
            if (filter_count >= self.filter_scratch.len) break;

            const filter_len = encoding.readU16(data, &pos) orelse return error.PayloadTooShort;
            if (pos + filter_len > data.len) return error.PayloadTooShort;
            const filter = data[pos..][0..filter_len];
            pos += filter_len;

            if (pos >= data.len) return error.PayloadTooShort;
            const options = data[pos];
            pos += 1;

            const qos_val: u2 = @truncate(options & 0x03);
            if (qos_val == 3) return error.InvalidQoS;

            self.filter_scratch[filter_count] = .{
                .filter = filter,
                .qos = @enumFromInt(qos_val),
                .no_local = (options & 0x04) != 0,
                .retain_as_published = (options & 0x08) != 0,
                .retain_handling = @truncate((options >> 4) & 0x03),
            };
            filter_count += 1;
        }

        return .{
            .packet_id = packet_id,
            .filters = self.filter_scratch[0..filter_count],
            .properties = props,
        };
    }

    fn parseUnsubscribe(self: *Parser, data: []const u8) ParseError!UnsubscribePacket {
        var pos: usize = 0;

        const packet_id = encoding.readU16(data, &pos) orelse return error.PayloadTooShort;

        // v5.0 properties
        var props: ?Properties = null;
        if (self.version == .v5_0) {
            props = try self.parseProperties(data, &pos);
        }

        // Parse topic filters
        var filter_count: usize = 0;
        while (pos < data.len) {
            if (filter_count >= self.unsubscribe_scratch.len) break;

            const filter_len = encoding.readU16(data, &pos) orelse return error.PayloadTooShort;
            if (pos + filter_len > data.len) return error.PayloadTooShort;
            self.unsubscribe_scratch[filter_count] = data[pos..][0..filter_len];
            pos += filter_len;
            filter_count += 1;
        }

        return .{
            .packet_id = packet_id,
            .filters = self.unsubscribe_scratch[0..filter_count],
            .properties = props,
        };
    }

    fn parseAck(self: *Parser, data: []const u8) ParseError!AckPacket {
        var pos: usize = 0;

        const packet_id = encoding.readU16(data, &pos) orelse return error.PayloadTooShort;

        var reason_code: ReasonCode = .success;
        var props: ?Properties = null;

        // v5.0: optional reason code and properties
        if (self.version == .v5_0 and pos < data.len) {
            reason_code = @enumFromInt(data[pos]);
            pos += 1;

            if (pos < data.len) {
                props = try self.parseProperties(data, &pos);
            }
        }

        return .{
            .packet_id = packet_id,
            .reason_code = reason_code,
            .properties = props,
        };
    }

    fn parseDisconnect(self: *Parser, data: []const u8) ParseError!DisconnectPacket {
        if (self.version != .v5_0 or data.len == 0) {
            return .{};
        }

        var pos: usize = 0;
        const reason_code: ReasonCode = @enumFromInt(data[pos]);
        pos += 1;

        var props: ?Properties = null;
        if (pos < data.len) {
            props = try self.parseProperties(data, &pos);
        }

        return .{
            .reason_code = reason_code,
            .properties = props,
        };
    }

    fn parseAuth(_: *Parser, data: []const u8) ParseError!AuthPacket {
        if (data.len == 0) return error.PayloadTooShort;

        var pos: usize = 0;
        const reason_code: ReasonCode = @enumFromInt(data[pos]);
        pos += 1;

        var props: ?Properties = null;
        if (pos < data.len) {
            const prop_len_result = encoding.decodeVarInt(data[pos..]) catch return error.MalformedPacket;
            pos += prop_len_result.len;
            if (pos + prop_len_result.value > data.len) return error.PayloadTooShort;
            props = .{ .data = data[pos..][0..prop_len_result.value] };
        }

        return .{
            .reason_code = reason_code,
            .properties = props,
        };
    }

    fn parseProperties(_: *Parser, data: []const u8, pos: *usize) ParseError!?Properties {
        const prop_len_result = encoding.decodeVarInt(data[pos.*..]) catch return error.MalformedPacket;
        pos.* += prop_len_result.len;

        if (prop_len_result.value == 0) return null;
        if (pos.* + prop_len_result.value > data.len) return error.PayloadTooShort;

        const props = Properties{ .data = data[pos.*..][0..prop_len_result.value] };
        pos.* += prop_len_result.value;
        return props;
    }
};

// Tests
const testing = std.testing;

test "parseFixedHeader" {
    // CONNECT packet
    const connect = [_]u8{ 0x10, 0x0A };
    const h1 = try parseFixedHeader(&connect);
    try testing.expectEqual(PacketType.connect, h1.packet_type);
    try testing.expectEqual(@as(u4, 0), h1.flags);
    try testing.expectEqual(@as(u32, 10), h1.remaining_length);

    // PUBLISH QoS 1
    const publish = [_]u8{ 0x32, 0x80, 0x01 };
    const h2 = try parseFixedHeader(&publish);
    try testing.expectEqual(PacketType.publish, h2.packet_type);
    try testing.expectEqual(@as(u32, 128), h2.remaining_length);
}
