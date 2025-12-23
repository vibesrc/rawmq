const std = @import("std");

/// MQTT Protocol versions
pub const ProtocolVersion = enum(u8) {
    v3_1_1 = 4,
    v5_0 = 5,
};

/// MQTT Control Packet types
pub const PacketType = enum(u4) {
    reserved = 0,
    connect = 1,
    connack = 2,
    publish = 3,
    puback = 4,
    pubrec = 5,
    pubrel = 6,
    pubcomp = 7,
    subscribe = 8,
    suback = 9,
    unsubscribe = 10,
    unsuback = 11,
    pingreq = 12,
    pingresp = 13,
    disconnect = 14,
    auth = 15, // v5.0 only
};

/// Quality of Service levels
pub const QoS = enum(u2) {
    at_most_once = 0,
    at_least_once = 1,
    exactly_once = 2,
};

/// Connect flags from CONNECT packet
pub const ConnectFlags = packed struct(u8) {
    reserved: u1 = 0,
    clean_session: bool,
    will_flag: bool,
    will_qos: u2,
    will_retain: bool,
    password_flag: bool,
    username_flag: bool,
};

/// Fixed header information
pub const FixedHeader = struct {
    packet_type: PacketType,
    flags: u4,
    remaining_length: u32,
    header_len: usize, // Total bytes consumed by fixed header
};

/// CONNECT packet data (zero-copy slices into buffer)
pub const ConnectPacket = struct {
    protocol_version: ProtocolVersion,
    flags: ConnectFlags,
    keep_alive: u16,
    client_id: []const u8,
    will_topic: ?[]const u8 = null,
    will_payload: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    // v5.0 properties
    properties: ?Properties = null,
    will_properties: ?Properties = null,
};

/// PUBLISH packet data (zero-copy)
pub const PublishPacket = struct {
    dup: bool,
    qos: QoS,
    retain: bool,
    topic: []const u8,
    packet_id: ?u16 = null, // Present only for QoS > 0
    payload: []const u8,
    properties: ?Properties = null, // v5.0 only
};

/// SUBSCRIBE topic filter with QoS
pub const TopicFilter = struct {
    filter: []const u8,
    qos: QoS,
    // v5.0 options
    no_local: bool = false,
    retain_as_published: bool = false,
    retain_handling: u2 = 0,
};

/// SUBSCRIBE packet data
pub const SubscribePacket = struct {
    packet_id: u16,
    filters: []TopicFilter,
    properties: ?Properties = null,
};

/// UNSUBSCRIBE packet data
pub const UnsubscribePacket = struct {
    packet_id: u16,
    filters: [][]const u8,
    properties: ?Properties = null,
};

/// Generic acknowledgment packet (PUBACK, PUBREC, PUBREL, PUBCOMP)
pub const AckPacket = struct {
    packet_id: u16,
    reason_code: @import("error.zig").ReasonCode = .success, // v5.0 only
    properties: ?Properties = null,
};

/// DISCONNECT packet (v5.0 has reason code and properties)
pub const DisconnectPacket = struct {
    reason_code: @import("error.zig").ReasonCode = .success, // success = normal_disconnection = 0x00
    properties: ?Properties = null,
};

/// AUTH packet (v5.0 only)
pub const AuthPacket = struct {
    reason_code: @import("error.zig").ReasonCode,
    properties: ?Properties = null,
};

/// Parsed MQTT packet (tagged union for zero-copy access)
pub const Packet = union(PacketType) {
    reserved: void,
    connect: ConnectPacket,
    connack: void, // Broker generates, doesn't parse
    publish: PublishPacket,
    puback: AckPacket,
    pubrec: AckPacket,
    pubrel: AckPacket,
    pubcomp: AckPacket,
    subscribe: SubscribePacket,
    suback: void, // Broker generates
    unsubscribe: UnsubscribePacket,
    unsuback: void, // Broker generates
    pingreq: void,
    pingresp: void, // Broker generates
    disconnect: DisconnectPacket,
    auth: AuthPacket,
};

// Import Properties from properties module
pub const Properties = @import("properties.zig").Properties;
pub const PropertyValue = @import("properties.zig").PropertyValue;
pub const PropertyId = @import("properties.zig").PropertyId;
