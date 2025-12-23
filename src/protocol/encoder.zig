const std = @import("std");
const types = @import("types.zig");
const encoding = @import("encoding.zig");
const err = @import("error.zig");

const QoS = types.QoS;
const ReasonCode = err.ReasonCode;

/// Packet encoder for building response packets
pub const Encoder = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) Encoder {
        return .{ .buf = buf };
    }

    pub fn reset(self: *Encoder) void {
        self.pos = 0;
    }

    pub fn written(self: *Encoder) []const u8 {
        return self.buf[0..self.pos];
    }

    pub fn writeByte(self: *Encoder, b: u8) !void {
        if (self.pos >= self.buf.len) return error.BufferFull;
        self.buf[self.pos] = b;
        self.pos += 1;
    }

    pub fn writeU16(self: *Encoder, v: u16) !void {
        if (self.pos + 2 > self.buf.len) return error.BufferFull;
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], v, .big);
        self.pos += 2;
    }

    pub fn writeBytes(self: *Encoder, data: []const u8) !void {
        if (self.pos + data.len > self.buf.len) return error.BufferFull;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    pub fn writeString(self: *Encoder, s: []const u8) !void {
        try self.writeU16(@intCast(s.len));
        try self.writeBytes(s);
    }

    pub fn writeVarInt(self: *Encoder, value: u32) !void {
        const len = encoding.encodeVarInt(value, self.buf[self.pos..]);
        self.pos += len;
    }

    /// Build CONNACK packet (v3.1.1)
    pub fn connack(self: *Encoder, session_present: bool, return_code: u8) ![]const u8 {
        self.reset();
        try self.writeByte(0x20); // CONNACK type
        try self.writeByte(0x02); // Remaining length
        try self.writeByte(if (session_present) 0x01 else 0x00);
        try self.writeByte(return_code);
        return self.written();
    }

    /// Build v5.0 CONNACK packet
    pub fn connackV5(self: *Encoder, session_present: bool, reason_code: ReasonCode, props: ?[]const u8) ![]const u8 {
        self.reset();

        // Calculate remaining length
        const props_len: usize = if (props) |p| p.len else 0;
        var var_int_buf: [4]u8 = undefined;
        const props_len_bytes = encoding.encodeVarInt(@intCast(props_len), &var_int_buf);
        const remaining: u32 = @intCast(2 + props_len_bytes + props_len);

        try self.writeByte(0x20);
        try self.writeVarInt(remaining);
        try self.writeByte(if (session_present) 0x01 else 0x00);
        try self.writeByte(@intFromEnum(reason_code));
        try self.writeVarInt(@intCast(props_len));
        if (props) |p| {
            try self.writeBytes(p);
        }
        return self.written();
    }

    /// Build PUBACK packet (v3.1.1)
    pub fn puback(self: *Encoder, packet_id: u16) ![]const u8 {
        self.reset();
        try self.writeByte(0x40);
        try self.writeByte(0x02);
        try self.writeU16(packet_id);
        return self.written();
    }

    /// Build PUBREC packet (v3.1.1)
    pub fn pubrec(self: *Encoder, packet_id: u16) ![]const u8 {
        self.reset();
        try self.writeByte(0x50);
        try self.writeByte(0x02);
        try self.writeU16(packet_id);
        return self.written();
    }

    /// Build PUBREL packet (v3.1.1)
    pub fn pubrel(self: *Encoder, packet_id: u16) ![]const u8 {
        self.reset();
        try self.writeByte(0x62); // PUBREL with required flags
        try self.writeByte(0x02);
        try self.writeU16(packet_id);
        return self.written();
    }

    /// Build PUBCOMP packet (v3.1.1)
    pub fn pubcomp(self: *Encoder, packet_id: u16) ![]const u8 {
        self.reset();
        try self.writeByte(0x70);
        try self.writeByte(0x02);
        try self.writeU16(packet_id);
        return self.written();
    }

    /// Build SUBACK packet (v3.1.1)
    pub fn suback(self: *Encoder, packet_id: u16, return_codes: []const u8) ![]const u8 {
        self.reset();
        try self.writeByte(0x90);
        try self.writeVarInt(@intCast(2 + return_codes.len));
        try self.writeU16(packet_id);
        try self.writeBytes(return_codes);
        return self.written();
    }

    /// Build SUBACK packet (v5.0)
    pub fn subackV5(self: *Encoder, packet_id: u16, reason_codes: []const u8, props: ?[]const u8) ![]const u8 {
        self.reset();
        const props_len: usize = if (props) |p| p.len else 0;
        var var_int_buf: [4]u8 = undefined;
        const props_len_bytes = encoding.encodeVarInt(@intCast(props_len), &var_int_buf);
        const remaining: u32 = @intCast(2 + props_len_bytes + props_len + reason_codes.len);

        try self.writeByte(0x90);
        try self.writeVarInt(remaining);
        try self.writeU16(packet_id);
        try self.writeVarInt(@intCast(props_len));
        if (props) |p| {
            try self.writeBytes(p);
        }
        try self.writeBytes(reason_codes);
        return self.written();
    }

    /// Build UNSUBACK packet (v3.1.1)
    pub fn unsuback(self: *Encoder, packet_id: u16) ![]const u8 {
        self.reset();
        try self.writeByte(0xB0);
        try self.writeByte(0x02);
        try self.writeU16(packet_id);
        return self.written();
    }

    /// Build UNSUBACK packet (v5.0)
    pub fn unsubackV5(self: *Encoder, packet_id: u16, reason_codes: []const u8, props: ?[]const u8) ![]const u8 {
        self.reset();
        const props_len: usize = if (props) |p| p.len else 0;
        var var_int_buf: [4]u8 = undefined;
        const props_len_bytes = encoding.encodeVarInt(@intCast(props_len), &var_int_buf);
        const remaining: u32 = @intCast(2 + props_len_bytes + props_len + reason_codes.len);

        try self.writeByte(0xB0);
        try self.writeVarInt(remaining);
        try self.writeU16(packet_id);
        try self.writeVarInt(@intCast(props_len));
        if (props) |p| {
            try self.writeBytes(p);
        }
        try self.writeBytes(reason_codes);
        return self.written();
    }

    /// Build PINGRESP packet
    pub fn pingresp(self: *Encoder) ![]const u8 {
        self.reset();
        try self.writeByte(0xD0);
        try self.writeByte(0x00);
        return self.written();
    }

    /// Build PUBLISH packet (v3.1.1)
    pub fn publish(
        self: *Encoder,
        topic: []const u8,
        payload: []const u8,
        qos: QoS,
        retain: bool,
        dup: bool,
        packet_id: ?u16,
    ) ![]const u8 {
        self.reset();

        // Fixed header byte 1
        var flags: u8 = 0x30; // PUBLISH type
        if (dup) flags |= 0x08;
        flags |= @as(u8, @intFromEnum(qos)) << 1;
        if (retain) flags |= 0x01;
        try self.writeByte(flags);

        // Calculate remaining length
        var remaining: usize = 2 + topic.len + payload.len;
        if (qos != .at_most_once) remaining += 2;

        try self.writeVarInt(@intCast(remaining));
        try self.writeString(topic);

        if (qos != .at_most_once) {
            try self.writeU16(packet_id.?);
        }

        try self.writeBytes(payload);
        return self.written();
    }

    /// Build PUBLISH packet (v5.0 with properties support)
    pub fn publishV5(
        self: *Encoder,
        topic: []const u8,
        payload: []const u8,
        qos: QoS,
        retain: bool,
        dup: bool,
        packet_id: ?u16,
        props: ?[]const u8,
    ) ![]const u8 {
        self.reset();

        // Fixed header byte 1
        var flags: u8 = 0x30; // PUBLISH type
        if (dup) flags |= 0x08;
        flags |= @as(u8, @intFromEnum(qos)) << 1;
        if (retain) flags |= 0x01;
        try self.writeByte(flags);

        // Calculate remaining length
        const props_len: usize = if (props) |p| p.len else 0;
        var var_int_buf: [4]u8 = undefined;
        const props_len_bytes = encoding.encodeVarInt(@intCast(props_len), &var_int_buf);

        var remaining: usize = 2 + topic.len + props_len_bytes + props_len + payload.len;
        if (qos != .at_most_once) remaining += 2;

        try self.writeVarInt(@intCast(remaining));
        try self.writeString(topic);

        if (qos != .at_most_once) {
            try self.writeU16(packet_id.?);
        }

        try self.writeVarInt(@intCast(props_len));
        if (props) |p| {
            try self.writeBytes(p);
        }

        try self.writeBytes(payload);
        return self.written();
    }

    /// Build v5.0 PUBACK with reason code
    pub fn pubackV5(self: *Encoder, packet_id: u16, reason_code: ReasonCode, props: ?[]const u8) ![]const u8 {
        self.reset();
        const props_len: usize = if (props) |p| p.len else 0;

        // If success and no properties, use short form (just packet ID)
        if (reason_code == .success and props_len == 0) {
            try self.writeByte(0x40);
            try self.writeByte(0x02);
            try self.writeU16(packet_id);
            return self.written();
        }

        var var_int_buf: [4]u8 = undefined;
        const props_len_bytes = encoding.encodeVarInt(@intCast(props_len), &var_int_buf);
        const remaining: u32 = @intCast(2 + 1 + props_len_bytes + props_len);

        try self.writeByte(0x40);
        try self.writeVarInt(remaining);
        try self.writeU16(packet_id);
        try self.writeByte(@intFromEnum(reason_code));
        try self.writeVarInt(@intCast(props_len));
        if (props) |p| {
            try self.writeBytes(p);
        }
        return self.written();
    }

    /// Build v5.0 PUBREC with reason code
    pub fn pubrecV5(self: *Encoder, packet_id: u16, reason_code: ReasonCode, props: ?[]const u8) ![]const u8 {
        self.reset();
        const props_len: usize = if (props) |p| p.len else 0;

        if (reason_code == .success and props_len == 0) {
            try self.writeByte(0x50);
            try self.writeByte(0x02);
            try self.writeU16(packet_id);
            return self.written();
        }

        var var_int_buf: [4]u8 = undefined;
        const props_len_bytes = encoding.encodeVarInt(@intCast(props_len), &var_int_buf);
        const remaining: u32 = @intCast(2 + 1 + props_len_bytes + props_len);

        try self.writeByte(0x50);
        try self.writeVarInt(remaining);
        try self.writeU16(packet_id);
        try self.writeByte(@intFromEnum(reason_code));
        try self.writeVarInt(@intCast(props_len));
        if (props) |p| {
            try self.writeBytes(p);
        }
        return self.written();
    }

    /// Build v5.0 PUBREL with reason code
    pub fn pubrelV5(self: *Encoder, packet_id: u16, reason_code: ReasonCode, props: ?[]const u8) ![]const u8 {
        self.reset();
        const props_len: usize = if (props) |p| p.len else 0;

        if (reason_code == .success and props_len == 0) {
            try self.writeByte(0x62);
            try self.writeByte(0x02);
            try self.writeU16(packet_id);
            return self.written();
        }

        var var_int_buf: [4]u8 = undefined;
        const props_len_bytes = encoding.encodeVarInt(@intCast(props_len), &var_int_buf);
        const remaining: u32 = @intCast(2 + 1 + props_len_bytes + props_len);

        try self.writeByte(0x62);
        try self.writeVarInt(remaining);
        try self.writeU16(packet_id);
        try self.writeByte(@intFromEnum(reason_code));
        try self.writeVarInt(@intCast(props_len));
        if (props) |p| {
            try self.writeBytes(p);
        }
        return self.written();
    }

    /// Build v5.0 PUBCOMP with reason code
    pub fn pubcompV5(self: *Encoder, packet_id: u16, reason_code: ReasonCode, props: ?[]const u8) ![]const u8 {
        self.reset();
        const props_len: usize = if (props) |p| p.len else 0;

        if (reason_code == .success and props_len == 0) {
            try self.writeByte(0x70);
            try self.writeByte(0x02);
            try self.writeU16(packet_id);
            return self.written();
        }

        var var_int_buf: [4]u8 = undefined;
        const props_len_bytes = encoding.encodeVarInt(@intCast(props_len), &var_int_buf);
        const remaining: u32 = @intCast(2 + 1 + props_len_bytes + props_len);

        try self.writeByte(0x70);
        try self.writeVarInt(remaining);
        try self.writeU16(packet_id);
        try self.writeByte(@intFromEnum(reason_code));
        try self.writeVarInt(@intCast(props_len));
        if (props) |p| {
            try self.writeBytes(p);
        }
        return self.written();
    }
};

// Tests
const testing = std.testing;

test "encoder connack" {
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);
    const pkt = try enc.connack(false, 0x00);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x20, 0x02, 0x00, 0x00 }, pkt);
}

test "encoder subackV5 with reason codes" {
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);

    const reason_codes = [_]u8{ 0x00, 0x01, 0x02 };
    const pkt = try enc.subackV5(10, &reason_codes, null);

    try testing.expectEqual(@as(u8, 0x90), pkt[0]);
    try testing.expectEqual(@as(u8, 0x06), pkt[1]);
    try testing.expectEqual(@as(u8, 0x00), pkt[2]);
    try testing.expectEqual(@as(u8, 0x0A), pkt[3]);
    try testing.expectEqual(@as(u8, 0x00), pkt[4]);
    try testing.expectEqual(@as(u8, 0x00), pkt[5]);
    try testing.expectEqual(@as(u8, 0x01), pkt[6]);
    try testing.expectEqual(@as(u8, 0x02), pkt[7]);
}

test "encoder publishV5 QoS 0" {
    var buf: [128]u8 = undefined;
    var enc = Encoder.init(&buf);

    const pkt = try enc.publishV5("test/topic", "hello", .at_most_once, false, false, null, null);

    try testing.expectEqual(@as(u8, 0x30), pkt[0]);
    try testing.expectEqual(@as(u8, 0x00), pkt[2]);
    try testing.expectEqual(@as(u8, 0x0A), pkt[3]);
}

test "encoder pubackV5 short form" {
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);

    const pkt = try enc.pubackV5(100, .success, null);

    try testing.expectEqual(@as(usize, 4), pkt.len);
    try testing.expectEqual(@as(u8, 0x40), pkt[0]);
    try testing.expectEqual(@as(u8, 0x02), pkt[1]);
}
