# Bluetooth Mesh Relay Implementation

## Overview

This implementation adds comprehensive Bluetooth mesh relay functionality to the existing BLE peer-to-peer chat application. The system enables multi-hop communication across a mesh network of Bluetooth devices, allowing messages to reach devices that aren't directly connected.

## Architecture

### Core Components

#### 1. RelayController (`RelayController.swift`)
**Purpose**: Intelligent relay decision making with flood control

**Key Features**:
- **TTL Management**: Prevents infinite message loops with Time-To-Live counters
- **Degree-Aware Probability**: Reduces relay frequency in dense networks to prevent flooding
- **Jittered Delays**: Adds random delays (20-80ms) to prevent network congestion
- **Message Type Awareness**: Different relay priorities for different message types

**How It Works**:
```swift
let decision = RelayController.decide(
    ttl: message.ttl,                    // Current hop count
    senderIsSelf: false,                 // Don't relay our own messages
    isEncrypted: false,                  // Message encryption status
    isDirectedFragment: false,           // Fragment targeting specific recipient
    isHandshake: false,                  // Security handshake message
    degree: connectedPeers.count,        // Number of connections
    highDegreeThreshold: 4               // Dense network threshold
)
```

#### 2. MessageDeduplicator (`MessageDeduplicator.swift`)
**Purpose**: Prevents processing duplicate messages and relay loops

**Key Features**:
- **Thread-Safe Operation**: Concurrent read access with exclusive write access
- **Automatic Cleanup**: Removes old message IDs after 5 minutes to prevent memory leaks
- **Statistics Tracking**: Monitors duplicate detection performance
- **Unique Message IDs**: Combines sender ID and message ID for deduplication

**Memory Management**:
- Retains message IDs for 5 minutes (configurable)
- Automatic cleanup every 60 seconds
- Caps memory usage by evicting oldest entries

#### 3. RelayScheduler (`RelayScheduler.swift`)
**Purpose**: Manages timing and execution of message relays with jitter

**Key Features**:
- **Jittered Scheduling**: Spreads relay timing to prevent thundering herd effects
- **Priority System**: Different urgency levels (low, normal, high, urgent)
- **Cancellation Support**: Cancel scheduled relays if duplicates arrive
- **Backpressure Control**: Limits concurrent scheduled relays (max 20)

**Relay Priority Levels**:
- **Urgent**: 5-15ms jitter (critical messages)
- **High**: 10-30ms jitter (important system messages)
- **Normal**: 20-80ms jitter (standard chat messages)
- **Low**: 50-150ms jitter (background messages)

#### 4. Enhanced SimpleMessage Structure
**Purpose**: Message format with relay support

**New Fields**:
- `ttl: UInt8` - Time To Live (hop count remaining)
- `relayCount: Int` - Number of times message has been relayed
- `isRelayed: Bool` - Whether message came through relay
- `originalSender: String` - Always the original sender (immutable)
- `lastRelay: String?` - Device that most recently relayed this message

**Relay Path Tracking**:
```swift
// Original message: "Direct"
// After 1 relay: "via User5678"
// After 2 relays: "via User9999 (+1 hops)"
```

#### 5. RelayMetrics Structure
**Purpose**: Comprehensive relay performance tracking

**Tracked Metrics**:
- **Message Statistics**: Total received, direct vs relayed, relay ratio
- **Relay Performance**: Scheduled, executed, cancelled, efficiency rate
- **Network Topology**: Current/max degree, average hop count
- **Duplicate Detection**: Blocked duplicates, detection rate

### Message Flow

#### Sending a Message
1. **Create Message**: Generate SimpleMessage with default TTL=5
2. **Mark as Seen**: Pre-mark in deduplicator to prevent self-processing
3. **Update Metrics**: Track network degree and statistics
4. **Broadcast**: Send via both Central and Peripheral BLE roles

#### Receiving a Message
1. **Deduplication Check**: Verify message hasn't been seen before
2. **Cancel Duplicates**: If duplicate, cancel any scheduled relay
3. **Update Metrics**: Track message statistics and relay performance
4. **UI Notification**: Display message in chat interface
5. **Relay Decision**: Use RelayController to decide if/when to relay
6. **Schedule Relay**: If decision is positive, schedule with jitter delay

#### Executing a Relay
1. **Create Relay Message**: Update TTL, increment relay count, set relay info
2. **Broadcast**: Send via same dual-role BLE transmission
3. **Update Metrics**: Track successful relay execution

## User Interface Enhancements

### Enhanced Chat View
- **Mesh Status Indicator**: Shows network density and relay activity
- **Message Type Icons**: Visual indicators for direct vs relayed messages
  - 📱 Direct messages
  - 🔄 Relayed messages
  - 🔧 System messages
- **TTL Display**: Shows remaining hop count for debugging
- **Relay Path**: Shows message routing path (e.g., "via User5678")

### Relay Statistics View
Comprehensive statistics dashboard showing:
- **Network Overview**: Connection count, mesh status, connected peers
- **Message Statistics**: Total/direct/relayed message counts, relay ratio
- **Relay Performance**: Scheduling efficiency, execution success rate
- **Duplicate Detection**: Prevention statistics and detection rate

## Configuration Parameters

### Default Settings
```swift
private let defaultTTL: UInt8 = 5           // Default message TTL (5 hops)
private let highDegreeThreshold = 4         // Consider 4+ connections as "high degree"
private let maxRelayDelayMs = 200           // Maximum relay delay in milliseconds
private let retentionPeriod: TimeInterval = 300  // 5 minutes message ID retention
private let cleanupInterval: TimeInterval = 60   // 1 minute cleanup frequency
private let maxConcurrentRelays = 20        // Maximum scheduled relays
```

### Relay Probability Matrix
Based on network degree (number of connections):
- **0-2 connections**: 100% relay probability (always forward)
- **3-4 connections**: 90% relay probability
- **5-6 connections**: 70% relay probability
- **7-9 connections**: 55% relay probability
- **10+ connections**: 45% relay probability (dense network)

## Network Behavior

### Flood Prevention
1. **TTL Limiting**: Messages die after 5 hops by default
2. **Probabilistic Relaying**: Not every device forwards every message
3. **Jitter Delays**: Random 20-80ms delays prevent simultaneous broadcasts
4. **Duplicate Cancellation**: Later duplicates cancel scheduled relays

### Adaptive Behavior
- **Dense Network Detection**: Reduces relay frequency when many devices present
- **TTL Capping**: Limits message propagation distance in dense networks
- **Priority-Based Jitter**: Critical messages get smaller delays

### Performance Optimizations
- **Thread-Safe Operations**: All relay operations use concurrent queues
- **Memory Management**: Automatic cleanup prevents memory leaks
- **Efficient Deduplication**: Hash-based duplicate detection with O(1) lookup
- **Backpressure Control**: Limits concurrent operations to prevent overload

## Testing and Debugging

### Available Debug Tools
1. **Relay Statistics View**: Real-time performance metrics
2. **Console Logging**: Detailed relay decision and execution logs
3. **Message Path Tracking**: Visual relay path in message display
4. **TTL Indicators**: Shows remaining hop count for each message

### Key Metrics to Monitor
- **Relay Efficiency**: Percentage of scheduled relays that execute
- **Duplicate Rate**: Percentage of messages that are duplicates
- **Network Degree**: Number of direct connections
- **Hop Count Distribution**: Average hops for received messages

## Security Considerations

### Current Implementation
- **No Encryption**: Messages are transmitted in plain text
- **No Authentication**: No verification of message authenticity
- **No Rate Limiting**: No protection against message flooding attacks

### Future Enhancements
- Add message encryption for relay messages
- Implement sender authentication
- Add rate limiting per sender
- Implement reputation-based relay decisions

## Usage Examples

### Basic Relay Testing
1. Start 3+ devices with the app
2. Ensure devices form a chain (A-B-C) where A and C aren't directly connected
3. Send message from A, verify it reaches C via B
4. Check relay statistics to confirm relay occurred

### Network Density Testing
1. Start 6+ devices in close proximity
2. Observe relay probability decreases as more devices connect
3. Monitor duplicate detection rates
4. Verify network doesn't get flooded with relay messages

### Performance Monitoring
1. Use "Stats" button to view real-time relay metrics
2. Monitor relay efficiency (should be >70% in normal conditions)
3. Check duplicate detection rate (should be >0% in multi-path networks)
4. Observe average hop count for relayed messages

## Implementation Notes

### Thread Safety
All relay components use appropriate synchronization:
- `MessageDeduplicator`: Concurrent queue with barriers for writes
- `RelayScheduler`: Concurrent queue with barriers for state changes
- `RelayMetrics`: Accessed on main actor for UI updates

### Memory Management
- Automatic cleanup of old message IDs
- Bounded relay scheduler queue
- Efficient data structures for performance

### BLE Integration
- Seamless integration with existing dual-role BLE architecture
- No changes required to BLE connection management
- Compatible with existing message format (backward compatible)

This implementation provides a robust, scalable Bluetooth mesh relay system that significantly extends the range and reliability of the peer-to-peer chat application.
