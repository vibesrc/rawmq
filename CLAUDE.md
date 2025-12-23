# rawmq - Zig MQTT Broker

## Project Overview
A high-performance MQTT broker written in Zig supporting both MQTT v3.1.1 and v5.0 protocols.

## Build Commands
- `zig build` - Build the broker executable (outputs to `zig-out/bin/`)
- `zig build run` - Build and run the broker
- `zig build test` - Run all tests

## Running the Broker
```bash
./zig-out/bin/rawmq                    # Default: 0.0.0.0:1883
./zig-out/bin/rawmq -p 1884            # Custom port
./zig-out/bin/rawmq -b 127.0.0.1       # Bind to localhost only
./zig-out/bin/rawmq -w 4               # Use 4 worker threads
```

## Testing Conformance
The `testmqtt` tool validates protocol conformance:
- `testmqtt conformance --version 3 --verbose` - Run all v3.1.1 conformance tests
- `testmqtt conformance --version 5 --verbose` - Run all v5.0 conformance tests
- Broker must be running on `tcp://localhost:1883` (default)

### Current Test Status
- **v3.1.1**: 66/77 tests passing (86%)
- **v5.0**: 86/139 tests passing (62%)

## Design Principles
- **Zero-copy parsing**: Use slices into receive buffers, avoid allocations in hot paths
- **Multi-core**: Thread-per-connection model, shared broker state with locks
- **Zig idioms**: Comptime for packet type dispatch, tagged unions for packets

## Project Structure
```
src/
  main.zig      - CLI entry point with argument parsing
  root.zig      - Library root module (public API exports)
  protocol.zig  - Zero-copy MQTT packet parser/encoder
  topic.zig     - Topic tree with wildcard matching (+, #)
  session.zig   - Client session and QoS state management
  broker.zig    - Central coordinator, routing, retained messages
  server.zig    - TCP server and connection handling
spec/
  v3.1.1/       - MQTT 3.1.1 specification documents
  v5.0/         - MQTT 5.0 specification documents
```

## MQTT Protocol Notes

### Packet Types (both versions)
1. CONNECT, 2. CONNACK, 3. PUBLISH, 4. PUBACK, 5. PUBREC,
6. PUBREL, 7. PUBCOMP, 8. SUBSCRIBE, 9. SUBACK, 10. UNSUBSCRIBE,
11. UNSUBACK, 12. PINGREQ, 13. PINGRESP, 14. DISCONNECT

### v5.0 Additions
- 15. AUTH packet for enhanced authentication
- Properties system on most packets
- Reason codes for detailed error reporting
- Topic aliases, shared subscriptions, message expiry

### QoS Levels
- QoS 0: At most once (fire and forget)
- QoS 1: At least once (acknowledged delivery)
- QoS 2: Exactly once (4-way handshake)

## Known Limitations / TODO
- Will message delivery needs improvement
- Session takeover (duplicate client ID) needs work
- $SYS topics not implemented
- Subscription persistence across reconnects
- v5.0 property forwarding not complete
- Topic aliases not implemented

## Development Guidelines
- Build outputs go to `zig-out/` (gitignored)
- Reference specs in `spec/` when implementing packet handling
- Run conformance tests frequently during development
