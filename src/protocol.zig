//! MQTT Protocol Implementation
//!
//! Zero-copy packet parsing and encoding for MQTT v3.1.1 and v5.0.
//! This module re-exports from submodules for a clean public API.

const types = @import("protocol/types.zig");
const parser = @import("protocol/parser.zig");
const encoder_mod = @import("protocol/encoder.zig");
const encoding = @import("protocol/encoding.zig");
const props = @import("protocol/properties.zig");
const err = @import("protocol/error.zig");

// Types
pub const PacketType = types.PacketType;
pub const ProtocolVersion = types.ProtocolVersion;
pub const QoS = types.QoS;
pub const FixedHeader = types.FixedHeader;
pub const Packet = types.Packet;
pub const ConnectPacket = types.ConnectPacket;
pub const ConnectFlags = types.ConnectFlags;
pub const PublishPacket = types.PublishPacket;
pub const SubscribePacket = types.SubscribePacket;
pub const UnsubscribePacket = types.UnsubscribePacket;
pub const TopicFilter = types.TopicFilter;
pub const AckPacket = types.AckPacket;
pub const DisconnectPacket = types.DisconnectPacket;
pub const AuthPacket = types.AuthPacket;

// Parser
pub const Parser = parser.Parser;
pub const parseFixedHeader = parser.parseFixedHeader;
pub const packetLength = parser.packetLength;

// Encoder
pub const Encoder = encoder_mod.Encoder;

// Properties (v5.0)
pub const Properties = props.Properties;
pub const PropertyId = props.PropertyId;
pub const PropertyValue = props.PropertyValue;

// Errors
pub const ParseError = err.ParseError;
pub const ReasonCode = err.ReasonCode;
pub const ConnackReturnCode = err.ConnackReturnCode;

// Encoding utilities
pub const decodeVarInt = encoding.decodeVarInt;
pub const encodeVarInt = encoding.encodeVarInt;
pub const readU16 = encoding.readU16;

// Tests - pull in all submodule tests
test {
    _ = @import("protocol/types.zig");
    _ = @import("protocol/parser.zig");
    _ = @import("protocol/encoder.zig");
    _ = @import("protocol/encoding.zig");
    _ = @import("protocol/properties.zig");
    _ = @import("protocol/error.zig");
}
