const std = @import("std");
const ParseError = @import("error.zig").ParseError;

/// Decode variable length integer from buffer
/// Returns the value and number of bytes consumed
pub fn decodeVarInt(data: []const u8) ParseError!struct { value: u32, len: usize } {
    var result: u32 = 0;
    var shift: u5 = 0;
    var i: usize = 0;

    while (i < data.len and i < 4) : (i += 1) {
        const b = data[i];
        result |= @as(u32, b & 0x7F) << shift;
        if (b & 0x80 == 0) {
            return .{ .value = result, .len = i + 1 };
        }
        shift += 7;
    }

    if (i >= 4) return error.InvalidRemainingLength;
    return error.IncompletePacket;
}

/// Encode variable length integer to buffer
/// Returns number of bytes written
pub fn encodeVarInt(value: u32, buf: []u8) usize {
    var x = value;
    var i: usize = 0;
    while (true) : (i += 1) {
        var b: u8 = @truncate(x & 0x7F);
        x >>= 7;
        if (x > 0) {
            b |= 0x80;
        }
        buf[i] = b;
        if (x == 0) break;
    }
    return i + 1;
}

/// Helper to read big-endian u16
pub fn readU16(data: []const u8, pos: *usize) ?u16 {
    if (pos.* + 2 > data.len) return null;
    const val = std.mem.readInt(u16, data[pos.*..][0..2], .big);
    pos.* += 2;
    return val;
}

// Tests
const testing = std.testing;

test "decodeVarInt" {
    // Single byte
    const r1 = try decodeVarInt(&[_]u8{0x00});
    try testing.expectEqual(@as(u32, 0), r1.value);
    try testing.expectEqual(@as(usize, 1), r1.len);

    const r2 = try decodeVarInt(&[_]u8{0x7F});
    try testing.expectEqual(@as(u32, 127), r2.value);

    // Two bytes
    const r3 = try decodeVarInt(&[_]u8{ 0x80, 0x01 });
    try testing.expectEqual(@as(u32, 128), r3.value);
    try testing.expectEqual(@as(usize, 2), r3.len);

    // Maximum value
    const r4 = try decodeVarInt(&[_]u8{ 0xFF, 0xFF, 0xFF, 0x7F });
    try testing.expectEqual(@as(u32, 268435455), r4.value);
}

test "encodeVarInt boundary values" {
    var buf: [4]u8 = undefined;

    // 0 = single byte
    try testing.expectEqual(@as(usize, 1), encodeVarInt(0, &buf));
    try testing.expectEqual(@as(u8, 0x00), buf[0]);

    // 127 = single byte max
    try testing.expectEqual(@as(usize, 1), encodeVarInt(127, &buf));
    try testing.expectEqual(@as(u8, 0x7F), buf[0]);

    // 128 = two bytes min
    try testing.expectEqual(@as(usize, 2), encodeVarInt(128, &buf));
    try testing.expectEqual(@as(u8, 0x80), buf[0]);
    try testing.expectEqual(@as(u8, 0x01), buf[1]);

    // 16383 = two bytes max
    try testing.expectEqual(@as(usize, 2), encodeVarInt(16383, &buf));

    // 16384 = three bytes min
    try testing.expectEqual(@as(usize, 3), encodeVarInt(16384, &buf));

    // 268,435,455 = maximum value (four bytes)
    try testing.expectEqual(@as(usize, 4), encodeVarInt(268435455, &buf));
}
