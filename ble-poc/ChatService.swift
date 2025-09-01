//
// SimpleBLEService.swift
// bitchat
//
// Simplified BLE service for peer-to-peer messaging demonstration
// This is free and unencumbered software released into the public domain.
//

import Foundation
import CoreBluetooth
import Combine

/**
 * RelayMetrics tracks relay performance and network health statistics
 *
 * This struct provides insights into how well the mesh relay system is working:
 * - How many messages have been relayed vs. received directly
 * - How many duplicates have been blocked
 * - Network topology information (degree, connectivity)
 * - Performance metrics (relay success rate, timing)
 */
struct RelayMetrics {
    // MESSAGE STATISTICS
    var messagesReceived: Int = 0           // Total messages received (direct + relayed)
    var messagesRelayed: Int = 0            // Messages we've forwarded to others
    var duplicatesBlocked: Int = 0          // Duplicate messages prevented
    var directMessages: Int = 0             // Messages received via direct connection
    var relayedMessages: Int = 0            // Messages received via relay
    
    // RELAY PERFORMANCE
    var relaysScheduled: Int = 0            // Total relays scheduled
    var relaysCancelled: Int = 0            // Relays cancelled due to duplicates
    var relaysExecuted: Int = 0             // Relays actually executed
    
    // NETWORK TOPOLOGY
    var currentDegree: Int = 0              // Number of current connections
    var maxDegree: Int = 0                  // Maximum connections seen
    var averageHopCount: Double = 0.0       // Average hops for received messages
    
    // TIMING STATISTICS
    var lastRelayAt: Date?                  // When we last relayed a message
    var averageRelayDelay: TimeInterval = 0 // Average delay before relaying
    
    /**
     * Calculate relay efficiency (0.0 to 1.0)
     * Higher values mean fewer unnecessary relays
     */
    var relayEfficiency: Double {
        guard relaysScheduled > 0 else { return 1.0 }
        return Double(relaysExecuted) / Double(relaysScheduled)
    }
    
    /**
     * Calculate duplicate detection rate (0.0 to 1.0)
     * Higher values mean better duplicate prevention
     */
    var duplicateDetectionRate: Double {
        let totalProcessed = messagesReceived + duplicatesBlocked
        guard totalProcessed > 0 else { return 0.0 }
        return Double(duplicatesBlocked) / Double(totalProcessed)
    }
    
    /**
     * Calculate relay ratio (0.0 to 1.0)
     * Shows what portion of received messages came via relay vs direct
     */
    var relayRatio: Double {
        guard messagesReceived > 0 else { return 0.0 }
        return Double(relayedMessages) / Double(messagesReceived)
    }
    
    /**
     * Get a human-readable summary of relay metrics
     */
    var summary: String {
        return """
        Relay Metrics Summary:
        • Messages: \(messagesReceived) received (\(directMessages) direct, \(relayedMessages) relayed)
        • Relays: \(relaysExecuted) executed, \(relaysCancelled) cancelled
        • Duplicates: \(duplicatesBlocked) blocked (\(String(format: "%.1f", duplicateDetectionRate * 100))% detection rate)
        • Network: \(currentDegree) connections (max: \(maxDegree))
        • Efficiency: \(String(format: "%.1f", relayEfficiency * 100))% relay efficiency
        """
    }
    
    /**
     * Reset all metrics (useful for testing or periodic resets)
     */
    mutating func reset() {
        messagesReceived = 0
        messagesRelayed = 0
        duplicatesBlocked = 0
        directMessages = 0
        relayedMessages = 0
        relaysScheduled = 0
        relaysCancelled = 0
        relaysExecuted = 0
        currentDegree = 0
        maxDegree = 0
        averageHopCount = 0.0
        lastRelayAt = nil
        averageRelayDelay = 0
    }
}

/**
 * Enhanced message structure with relay support for Bluetooth mesh networking
 *
 * This message structure supports both direct peer-to-peer messaging and
 * multi-hop relay functionality across a mesh network of Bluetooth devices.
 *
 * BASIC MESSAGE FIELDS:
 * - id: Unique identifier for each message (like "ABC123")
 * - sender: Who originally sent it (like "User1234")
 * - content: The actual message text (like "Hello!")
 * - timestamp: When it was originally sent
 *
 * RELAY-SPECIFIC FIELDS:
 * - ttl: Time To Live - how many more hops this message can make (0-255)
 * - relayCount: How many times this message has been relayed (for debugging)
 * - isRelayed: Whether this message came through relay vs direct connection
 * - originalSender: Always the original sender (doesn't change during relay)
 * - lastRelay: The device that most recently relayed this message to us
 *
 * EXAMPLE MESSAGE FLOW:
 * 1. User1234 sends "Hello!" with TTL=5, relayCount=0, isRelayed=false
 * 2. User5678 receives it directly: isRelayed=false, lastRelay=nil
 * 3. User5678 relays it with TTL=4, relayCount=1
 * 4. User9999 receives it: isRelayed=true, lastRelay="User5678", originalSender="User1234"
 *
 * JSON Example:
 * {
 *   "id": "550e8400-e29b-41d4-a716-446655440000",
 *   "sender": "User1234",
 *   "content": "Hello there!",
 *   "timestamp": "2024-01-01T12:00:00Z",
 *   "ttl": 4,
 *   "relayCount": 1,
 *   "isRelayed": true,
 *   "originalSender": "User1234",
 *   "lastRelay": "User5678"
 * }
 */
struct SimpleMessage: Codable {
    let id: String              // Unique message identifier
    let sender: String          // Original sender (for backward compatibility)
    let content: String         // Message content
    let timestamp: Date         // When originally sent
    
    // RELAY FIELDS - New fields for mesh networking support
    let ttl: UInt8              // Time To Live - hops remaining (0-255)
    let relayCount: Int         // Number of times this message has been relayed
    let isRelayed: Bool         // True if this message came through a relay
    let originalSender: String  // Always the original sender (immutable during relay)
    let lastRelay: String?      // Device that most recently relayed this to us
    
    /**
     * Initialize a new original message (not relayed)
     * This is used when a user types a new message to send
     */
    init(sender: String, content: String, ttl: UInt8 = 5) {
        self.id = UUID().uuidString         // Generate unique ID automatically
        self.sender = sender                // Original sender
        self.content = content              // Message content
        self.timestamp = Date()             // Current time
        self.ttl = ttl                      // Default TTL of 5 hops
        self.relayCount = 0                 // New message, never relayed
        self.isRelayed = false              // Direct message, not relayed
        self.originalSender = sender        // Same as sender for original messages
        self.lastRelay = nil                // No relay for original messages
    }
    
    /**
     * Initialize a relayed message with updated relay information
     * This is used when forwarding a message through the mesh network
     */
    init(relayingMessage original: SimpleMessage, newTTL: UInt8, relayedBy: String) {
        self.id = original.id               // Keep same message ID
        self.sender = original.sender       // Keep original sender for compatibility
        self.content = original.content     // Keep same content
        self.timestamp = original.timestamp // Keep original timestamp
        self.ttl = newTTL                   // Updated TTL (decremented)
        self.relayCount = original.relayCount + 1  // Increment relay count
        self.isRelayed = true               // Mark as relayed
        self.originalSender = original.originalSender  // Preserve original sender
        self.lastRelay = relayedBy          // Who relayed it to us
    }
    
    /**
     * Create a message ID for deduplication purposes
     * This combines the original message ID with the original sender to ensure uniqueness
     */
    var deduplicationID: String {
        return "\(originalSender)-\(id)"
    }
    
    /**
     * Check if this message can still be relayed (TTL > 1)
     */
    var canBeRelayed: Bool {
        return ttl > 1
    }
    
    /**
     * Get a human-readable description of the relay path
     * Examples: "Direct", "via User5678", "via User5678 → User9999"
     */
    var relayPath: String {
        if !isRelayed {
            return "Direct"
        } else if let relay = lastRelay {
            if relayCount == 1 {
                return "via \(relay)"
            } else {
                return "via \(relay) (+\(relayCount - 1) hops)"
            }
        } else {
            return "Relayed (\(relayCount) hops)"
        }
    }
}

/**
 * Delegate protocol for receiving messages
 *
 * This is like having a messenger that tells you when stuff happens.
 * The SimpleBLEService will call these functions to notify your app:
 *
 * - didReceiveMessage: "Hey, someone sent you a message!"
 * - didConnectToPeer: "Hey, someone joined the chat!"
 * - didDisconnectFromPeer: "Hey, someone left the chat!"
 *
 * Example usage in your ViewModel:
 * func didReceiveMessage(_ message: SimpleMessage) {
 *     print("Got message: \(message.content)")
 *     // Add to your messages array
 * }
 */
protocol SimpleBLEDelegate: AnyObject {
    func didReceiveMessage(_ message: SimpleMessage)
    func didConnectToPeer(_ peerName: String)
    func didDisconnectFromPeer(_ peerName: String)
}

/**
 * Enhanced BLE service with Bluetooth mesh relay functionality
 *
 * This class performs THREE main functions for mesh networking:
 *
 * 1. CENTRAL ROLE (Scanner): Looks for other devices to connect to
 *    - Like walking around with a radar looking for friends
 *    - Finds devices, connects to them, sends/receives messages
 *
 * 2. PERIPHERAL ROLE (Advertiser): Makes itself visible to other devices
 *    - Like putting up a big sign saying "I'm here, come chat with me!"
 *    - Other devices can find you and connect to you
 *
 * 3. RELAY ROLE (Mesh Forwarder): Forwards messages between devices that aren't directly connected
 *    - Like being a messenger that passes notes between friends who can't see each other
 *    - Enables multi-hop communication across the entire mesh network
 *    - Uses intelligent relay decisions to prevent network flooding
 *
 * MESH NETWORKING EXPLAINED:
 * In a traditional BLE setup, Device A can only talk to Device B if they're directly connected.
 * With mesh relaying, Device A can send a message to Device C through Device B:
 * A → B → C (B acts as a relay)
 *
 * This enables much larger networks where devices can be spread over a wider area.
 *
 * RELAY INTELLIGENCE:
 * - TTL (Time To Live): Messages have a hop count that prevents infinite loops
 * - Deduplication: Prevents the same message from being processed multiple times
 * - Jittered Scheduling: Prevents network congestion from simultaneous relays
 * - Probabilistic Forwarding: Not every device relays every message (based on network density)
 */
class SimpleBLEService: NSObject, ObservableObject {
    
    // MARK: - Constants
    
    /**
     * These are like secret handshake codes that all our devices use to recognize each other.
     * Think of them like:
     * - serviceUUID: "Hey, I'm a BitChat app!"
     * - messageCharacteristicUUID: "This is where I send/receive messages"
     * - nameCharacteristicUUID: "This is where I store my username"
     *
     * All our devices use these same UUIDs so they can find each other.
     * Different from other apps so we don't accidentally connect to random Bluetooth devices.
     */
    static let serviceUUID = CBUUID(string: "12345678-1234-5678-9ABC-123456789ABC")
    static let messageCharacteristicUUID = CBUUID(string: "87654321-4321-8765-CBA9-987654321CBA")
    static let nameCharacteristicUUID = CBUUID(string: "11111111-2222-3333-4444-555555555555")
    
    // MARK: - Published Properties
    
    /**
     * These @Published properties automatically update the UI when they change.
     * Think of them as status indicators:
     *
     * - isScanning: "Am I currently looking for other devices?" (true/false)
     * - isAdvertising: "Am I currently visible to other devices?" (true/false)
     * - connectedPeers: "Who am I currently chatting with?" (["User1234", "User5678"])
     * - discoveredPeers: "Who have I found nearby?" (["User9999", "User1111"])
     *
     * When these change, SwiftUI automatically updates the UI to show the new values.
     */
    @Published var isScanning = false          // True when actively looking for devices
    @Published var isAdvertising = false       // True when visible to other devices
    @Published var connectedPeers: [String] = []    // List of connected device names
    @Published var discoveredPeers: [String] = []   // List of discovered device names
    
    // MARK: - Properties
    
    /**
     * The delegate is like having an assistant that you tell "hey, let me know when something happens"
     * When messages arrive or people connect/disconnect, we tell the delegate about it.
     */
    weak var delegate: SimpleBLEDelegate?
    
    // MARK: - Relay System Components
    
    /**
     * RELAY SYSTEM ARCHITECTURE:
     *
     * These three components work together to enable intelligent mesh relaying:
     *
     * 1. MESSAGE DEDUPLICATOR: Prevents processing the same message multiple times
     *    - Remembers message IDs we've already seen
     *    - Automatically forgets old messages to prevent memory leaks
     *    - Thread-safe for concurrent BLE operations
     *
     * 2. RELAY SCHEDULER: Manages timing of relay operations with jitter
     *    - Adds random delays to prevent network congestion
     *    - Allows cancellation of scheduled relays if duplicates arrive
     *    - Prioritizes different types of messages
     *
     * 3. RELAY METRICS: Tracks relay performance and network health
     *    - Counts messages relayed, duplicates blocked, etc.
     *    - Helps with debugging and network optimization
     *    - Provides insights into mesh network topology
     */
    private let messageDeduplicator = MessageDeduplicator()
    private let relayScheduler = RelayScheduler()
    private var relayMetrics = RelayMetrics()
    
    // RELAY CONFIGURATION
    private let defaultTTL: UInt8 = 5           // Default message TTL (5 hops)
    private let highDegreeThreshold = 4         // Consider 4+ connections as "high degree"
    private let maxRelayDelayMs = 200           // Maximum relay delay in milliseconds
    
    /**
     * Core Bluetooth managers - these are Apple's built-in classes for BLE:
     *
     * - centralManager: Handles scanning for and connecting to other devices
     *   (like having a radar that finds other devices and connects to them)
     *
     * - peripheralManager: Handles advertising ourselves and responding to connections
     *   (like having a beacon that says "I'm here!" and accepts incoming connections)
     */
    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    
    /**
     * PERIPHERAL STATE (when we're acting as a server that others connect to):
     *
     * Think of characteristics like "channels" or "folders" where we store different types of data:
     * - messageCharacteristic: The "mailbox" where messages go
     * - nameCharacteristic: The "name tag" that shows our username
     */
    private var messageCharacteristic: CBMutableCharacteristic?  // Where messages are stored
    private var nameCharacteristic: CBMutableCharacteristic?     // Where our name is stored
    
    /**
     * CENTRAL STATE (when we're connecting to other devices):
     *
     * - connectedPeripherals: List of actual BLE device objects we're connected to
     *   (like having contact cards for each person you're chatting with)
     *
     * - discoveredPeripherals: Maps device objects to their names
     *   (like a phonebook: Device123 -> "User1234")
     */
    private var connectedPeripherals: [CBPeripheral] = []              // Actual connected devices
    private var discoveredPeripherals: [CBPeripheral: String] = [:]    // Device -> Name mapping
    
    /**
     * RECONNECTION LOGIC (because Bluetooth connections can drop):
     *
     * When someone walks away or Bluetooth gets flaky, connections drop.
     * This system automatically tries to reconnect to people you were chatting with.
     *
     * - reconnectionTimer: Runs every 5 seconds to check for disconnected friends
     * - knownPeripherals: List of devices we should try to reconnect to
     * - isReconnecting: Prevents multiple reconnection attempts at once
     */
    private var reconnectionTimer: Timer?                              // Timer that runs every 5 seconds
    private var knownPeripherals: [CBPeripheral] = []                  // Devices we should reconnect to
    private let reconnectionInterval: TimeInterval = 30.0              // Try reconnecting every 5 seconds
    private var isReconnecting = false                                 // Flag to prevent spam reconnections
    
    /**
     * USER INFO:
     *
     * Your username - randomly generated like "User1234".
     * When you change it, we update the name characteristic so others see the new name.
     */
    var myName: String = "User\(Int.random(in: 1000...9999))" {
        didSet {
            updateNameCharacteristic()  // Tell everyone our new name
        }
    }
    
    // MARK: - Initialization
    
    /**
     * When the service is created, we set up the Core Bluetooth managers and relay system:
     * - centralManager: For finding and connecting to other devices
     * - peripheralManager: For being visible and accepting connections
     * - relayScheduler: For intelligent message relay timing and management
     *
     * All managers will call our delegate methods when things happen.
     */
    override init() {
        super.init()
        
        // Create the BLE managers - they'll start calling our delegate methods immediately
        centralManager = CBCentralManager(delegate: self, queue: nil)
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        
        // Set up relay scheduler delegate
        relayScheduler.relayDelegate = self
        
        print("🔄 Initialized BLE service with mesh relay support")
    }
    
    // MARK: - Public Methods
    
    /**
     * Start both services at once:
     * 1. Start advertising (make ourselves visible)
     * 2. Start scanning (look for others)
     *
     * This is like turning on both your "I'm here!" beacon and your "looking for friends" radar.
     */
    func startServices() {
        startAdvertising()  // Put up our "I'm here!" sign
        startScanning()     // Start looking for other people
    }
    
    /**
     * Stop everything:
     * 1. Stop advertising (become invisible)
     * 2. Stop scanning (stop looking)
     * 3. Stop reconnection attempts (stop trying to reconnect)
     *
     * This turns off all Bluetooth activity.
     */
    func stopServices() {
        stopAdvertising()       // Take down our "I'm here!" sign
        stopScanning()          // Stop looking for others
        stopReconnectionTimer() // Stop trying to reconnect to old friends
    }
    
    /**
     * Manual refresh when user taps the refresh button.
     *
     * This does a "hard reset" of all connections:
     *
     * 1. RESTART SCANNING: Stop looking, wait a bit, then start looking again
     *    (Sometimes devices get "stuck" and need a fresh scan to be found)
     *
     * 2. TRY RECONNECTIONS: Attempt to reconnect to people we were chatting with before
     *    (In case they were disconnected but are still nearby)
     *
     * 3. RESTART ADVERTISING: Stop being visible, wait a bit, then be visible again
     *    (So other devices can find us fresh)
     *
     * Think of it like "turning it off and on again" but smarter.
     */
    func refreshConnections() {
        print("🔄 Manually refreshing BLE connections...")
        
        // 1. RESTART SCANNING: Fresh scan to find devices that might be "stuck"
        if centralManager.state == .poweredOn {
            centralManager.stopScan()  // Stop looking
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startScanning()  // Start looking again after 0.5 seconds
            }
        }
        
        // 2. TRY RECONNECTIONS: Try to reconnect to old friends
        attemptReconnections()
        
        // 3. RESTART ADVERTISING: Fresh advertising so others can find us
        if peripheralManager.state == .poweredOn {
            peripheralManager.stopAdvertising()  // Stop being visible
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startAdvertising()  // Be visible again after 0.5 seconds
            }
        }
    }
    
    /**
     * Send a message to ALL connected devices with mesh relay support.
     *
     * ENHANCED MESH FUNCTIONALITY:
     * This function now creates messages with relay support, enabling multi-hop communication
     * across the mesh network. The message includes TTL and relay tracking information.
     *
     * DUAL-ROLE TRANSMISSION (same as before):
     * Since we're both Central AND Peripheral, we send the message in TWO ways:
     *
     * PERIPHERAL SIDE: Broadcast to devices that connected TO US
     * - We update our message characteristic
     * - Any device that subscribed to our notifications gets the message
     * - Like updating your status on social media - followers see it
     *
     * CENTRAL SIDE: Send to devices WE connected to
     * - We write directly to each device's message characteristic
     * - Like sending a direct message to each friend individually
     *
     * RELAY PREPARATION:
     * - Mark our own message as "seen" to prevent relay loops
     * - Update relay metrics for network monitoring
     * - Set appropriate TTL for message propagation
     *
     * Example flow:
     * 1. User types "Hello!" and hits send
     * 2. We create a SimpleMessage with sender=myName, content="Hello!", TTL=5
     * 3. Mark message as seen in deduplicator (prevent processing our own message)
     * 4. Convert message to JSON data
     * 5. Send via both peripheral (broadcast) and central (direct) methods
     * 6. Connected devices receive the message and may relay it further
     */
    func sendMessage(_ content: String) {
        // Step 1: Create the message object with relay support
        let message = SimpleMessage(sender: myName, content: content, ttl: defaultTTL)
        
        // Step 2: Pre-mark our own message as seen to prevent relay loops
        // This ensures we don't process our own message if it comes back to us
        messageDeduplicator.markAsSeen(message.deduplicationID)
        
        // Step 3: Update relay metrics
        relayMetrics.currentDegree = connectedPeers.count
        relayMetrics.maxDegree = max(relayMetrics.maxDegree, relayMetrics.currentDegree)
        
        // Step 4: Convert to JSON data for transmission
        guard let data = try? JSONEncoder().encode(message),
              let messageChar = messageCharacteristic else {
            print("❌ Failed to encode message or characteristic not ready")
            return
        }
        
        // Step 5a: PERIPHERAL SIDE - Broadcast to devices connected TO US
        // This sends to any device that is acting as Central and connected to us
        peripheralManager.updateValue(data, for: messageChar, onSubscribedCentrals: nil)
        
        // Step 5b: CENTRAL SIDE - Send directly to devices WE connected to
        // This sends to any device that we connected to (where we're acting as Central)
        for peripheral in connectedPeripherals {
            if let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }),
               let characteristic = service.characteristics?.first(where: { $0.uuid == Self.messageCharacteristicUUID }) {
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
            }
        }
        
        print("📤 Sent mesh message: \(content) (TTL: \(message.ttl), ID: \(message.id.prefix(8))...)")
    }
    
    /**
     * Get current relay metrics for debugging and monitoring
     */
    func getRelayMetrics() -> RelayMetrics {
        return relayMetrics
    }
    
    /**
     * Get relay system statistics summary
     */
    func getRelayStatistics() -> String {
        let dedupStats = messageDeduplicator.getStatistics()
        let schedStats = relayScheduler.getStatistics()
        
        return """
        Mesh Relay Statistics:
        
        Deduplication:
        • Total seen: \(dedupStats.totalSeen)
        • Duplicates blocked: \(dedupStats.duplicatesBlocked)
        • Currently cached: \(dedupStats.currentlyCached)
        
        Relay Scheduling:
        • Scheduled: \(schedStats.scheduled)
        • Executed: \(schedStats.executed)
        • Cancelled: \(schedStats.cancelled)
        • Pending: \(schedStats.pending)
        
        \(relayMetrics.summary)
        """
    }
    
    // MARK: - Message Handling with Relay Logic
    
    /**
     * Handle a received message with intelligent relay decision making
     *
     * This is the core of the mesh relay system. When we receive a message, we:
     * 1. Check for duplicates (prevent processing the same message twice)
     * 2. Update metrics and notify the UI
     * 3. Make an intelligent relay decision based on network conditions
     * 4. Schedule the relay with jitter if appropriate
     * 5. Handle relay cancellation if duplicates arrive later
     *
     * RELAY DECISION FACTORS:
     * - TTL: Don't relay messages with TTL <= 1
     * - Origin: Never relay our own messages
     * - Network Density: Relay less frequently in dense networks
     * - Message Type: Different priorities for different message types
     * - Duplicates: Cancel scheduled relays if the same message arrives from another source
     *
     * EXAMPLE FLOW:
     * 1. Device B receives "Hello" from Device A (TTL=5)
     * 2. Check deduplication: First time seeing this message
     * 3. Notify UI: Display "Hello" in chat
     * 4. Relay decision: 70% chance to relay (based on network density)
     * 5. If yes: Schedule relay with 45ms jitter delay
     * 6. If Device B later receives same "Hello" from Device C: Cancel scheduled relay
     */
    private func handleReceivedMessage(_ message: SimpleMessage, fromPeer: String) {
        // STEP 1: DEDUPLICATION CHECK
        // Prevent processing the same message multiple times
        if messageDeduplicator.isDuplicate(message.deduplicationID) {
            print("🚫 Ignoring duplicate message: \(message.id.prefix(8))... from \(message.originalSender)")
            
            // Cancel any scheduled relay for this duplicate message
            if relayScheduler.cancelRelay(messageID: message.deduplicationID) {
                relayMetrics.relaysCancelled += 1
                print("❌ Cancelled scheduled relay due to duplicate")
            }
            
            relayMetrics.duplicatesBlocked += 1
            return
        }
        
        // STEP 2: UPDATE METRICS
        relayMetrics.messagesReceived += 1
        if message.isRelayed {
            relayMetrics.relayedMessages += 1
            
            // Update average hop count
            let totalHops = Double(relayMetrics.relayedMessages - 1) * relayMetrics.averageHopCount + Double(message.relayCount)
            relayMetrics.averageHopCount = totalHops / Double(relayMetrics.relayedMessages)
        } else {
            relayMetrics.directMessages += 1
        }
        
        // STEP 3: NOTIFY UI
        // Always notify the delegate so the message appears in the chat
        print("📨 Received message: \(message.content) (from: \(message.originalSender), hops: \(message.relayCount), TTL: \(message.ttl))")
        delegate?.didReceiveMessage(message)
        
        // STEP 4: RELAY DECISION
        // Don't relay our own messages or messages from ourselves
        if message.originalSender == myName {
            print("🔄 Not relaying our own message")
            return
        }
        
        // Don't relay if TTL is too low
        if !message.canBeRelayed {
            print("🔄 Message TTL expired, not relaying")
            return
        }
        
        // Make intelligent relay decision based on network conditions
        let currentDegree = connectedPeers.count
        let decision = RelayController.decide(
            ttl: message.ttl,
            senderIsSelf: false,  // We know this isn't from us at this point
            isEncrypted: false,   // For now, treating all messages as plain text
            isDirectedFragment: false,  // Not implementing fragmentation yet
            isHandshake: false,   // No handshake messages yet
            degree: currentDegree,
            highDegreeThreshold: highDegreeThreshold
        )
        
        // STEP 5: SCHEDULE RELAY IF DECISION IS POSITIVE
        if decision.shouldRelay {
            // Create relay message with updated TTL and relay information
            let relayMessage = SimpleMessage(
                relayingMessage: message,
                newTTL: decision.newTTL,
                relayedBy: myName
            )
            
            // Schedule the relay with jitter
            let scheduled = relayScheduler.scheduleRelay(
                message: relayMessage,
                delayMs: decision.delayMs,
                priority: .normal
            )
            
            if scheduled {
                relayMetrics.relaysScheduled += 1
                print("📅 Scheduled relay for message \(message.id.prefix(8))... in \(decision.delayMs)ms (new TTL: \(decision.newTTL))")
            } else {
                print("⚠️ Failed to schedule relay (queue full or duplicate)")
            }
        } else {
            print("🔄 Relay decision: NO (TTL: \(message.ttl), degree: \(currentDegree))")
        }
    }
    
    // MARK: - Private Methods - Peripheral (Advertising)
    
    private func startAdvertising() {
        guard peripheralManager.state == .poweredOn else {
            print("Peripheral manager not ready")
            return
        }
        
        setupPeripheralService()
        
        let advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: myName
        ]
        
        peripheralManager.startAdvertising(advertisementData)
        isAdvertising = true
        print("Started advertising as: \(myName)")
    }
    
    private func stopAdvertising() {
        peripheralManager.stopAdvertising()
        isAdvertising = false
        print("Stopped advertising")
    }
    
    private func setupPeripheralService() {
        // Create characteristics
        messageCharacteristic = CBMutableCharacteristic(
            type: Self.messageCharacteristicUUID,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )
        
        nameCharacteristic = CBMutableCharacteristic(
            type: Self.nameCharacteristicUUID,
            properties: [.read],
            value: myName.data(using: .utf8),
            permissions: [.readable]
        )
        
        // Create service
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [messageCharacteristic!, nameCharacteristic!]
        
        // Add service to peripheral manager
        peripheralManager.add(service)
    }
    
    private func updateNameCharacteristic() {
        guard let nameChar = nameCharacteristic else { return }
        nameChar.value = myName.data(using: .utf8)
    }
    
    // MARK: - Private Methods - Central (Scanning)
    
    private func startScanning() {
        guard centralManager.state == .poweredOn else {
            print("Central manager not ready")
            return
        }
        
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
        print("Started scanning for devices")
    }
    
    private func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        print("Stopped scanning")
    }
    
    private func connectToPeripheral(_ peripheral: CBPeripheral) {
        print("Connecting to: \(peripheral.name ?? "Unknown")")
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }
    
    // MARK: - Reconnection Logic
    
    private func startReconnectionTimer() {
        stopReconnectionTimer()
        reconnectionTimer = Timer.scheduledTimer(withTimeInterval: reconnectionInterval, repeats: true) { [weak self] _ in
            self?.attemptReconnections()
        }
        print("🔄 Started automatic reconnection timer (every \(reconnectionInterval)s)")
    }
    
    private func stopReconnectionTimer() {
        reconnectionTimer?.invalidate()
        reconnectionTimer = nil
        print("⏹️ Stopped automatic reconnection timer")
    }
    
    private func attemptReconnections() {
        guard !isReconnecting else { return }
        
        // Find disconnected known peripherals
        let disconnectedPeripherals = knownPeripherals.filter { peripheral in
            !connectedPeripherals.contains(peripheral) && peripheral.state != .connected
        }
        
        if !disconnectedPeripherals.isEmpty {
            isReconnecting = true
            print("🔄 Attempting to reconnect to \(disconnectedPeripherals.count) known device(s)...")
            
            for peripheral in disconnectedPeripherals {
                if centralManager.state == .poweredOn {
                    print("🔄 Reconnecting to: \(discoveredPeripherals[peripheral] ?? "Unknown")")
                    centralManager.connect(peripheral, options: nil)
                }
            }
            
            // Reset reconnection flag after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.isReconnecting = false
            }
        }
    }
}

// MARK: - RelaySchedulerDelegate

extension SimpleBLEService: RelaySchedulerDelegate {
    /**
     * Execute a relay for the given message
     *
     * This is called by the RelayScheduler when a scheduled relay is ready to execute.
     * We simply broadcast the relay message to all connected devices using the same
     * dual-role transmission method as sending original messages.
     *
     * The message has already been prepared with updated TTL and relay information,
     * so we just need to transmit it.
     */
    func executeRelay(message: SimpleMessage) {
        // Update metrics
        relayMetrics.relaysExecuted += 1
        relayMetrics.messagesRelayed += 1
        relayMetrics.lastRelayAt = Date()
        
        // Convert to JSON data for transmission
        guard let data = try? JSONEncoder().encode(message),
              let messageChar = messageCharacteristic else {
            print("❌ Failed to encode relay message or characteristic not ready")
            return
        }
        
        // Broadcast the relay message using the same dual-role approach
        
        // PERIPHERAL SIDE - Broadcast to devices connected TO US
        peripheralManager.updateValue(data, for: messageChar, onSubscribedCentrals: nil)
        
        // CENTRAL SIDE - Send directly to devices WE connected to
        for peripheral in connectedPeripherals {
            if let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }),
               let characteristic = service.characteristics?.first(where: { $0.uuid == Self.messageCharacteristicUUID }) {
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
            }
        }
        
        print("🚀 Executed relay: \(message.content) (original: \(message.originalSender), TTL: \(message.ttl), hops: \(message.relayCount))")
    }
}

// MARK: - CBCentralManagerDelegate

extension SimpleBLEService: CBCentralManagerDelegate {
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("Central manager state: \(central.state.rawValue)")
        
        if central.state == .poweredOn {
            startScanning()
        } else {
            isScanning = false
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let peerName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Unknown"
        
        print("Discovered: \(peerName)")
        
        if !discoveredPeripherals.keys.contains(peripheral) {
            discoveredPeripherals[peripheral] = peerName
            
            DispatchQueue.main.async {
                self.discoveredPeers.append(peerName)
            }
            
            // Auto-connect for demo
            connectToPeripheral(peripheral)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let peerName = discoveredPeripherals[peripheral] ?? "Unknown"
        print("Connected to: \(peerName)")
        
        connectedPeripherals.append(peripheral)
        
        // Add to known peripherals for reconnection
        if !knownPeripherals.contains(peripheral) {
            knownPeripherals.append(peripheral)
        }
        
        DispatchQueue.main.async {
            if !self.connectedPeers.contains(peerName) {
                self.connectedPeers.append(peerName)
            }
        }
        
        delegate?.didConnectToPeer(peerName)
        
        // Start reconnection timer when we have our first connection
        if connectedPeripherals.count == 1 {
            startReconnectionTimer()
        }
        
        // Discover services
        peripheral.discoverServices([Self.serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let peerName = discoveredPeripherals[peripheral] ?? "Unknown"
        print("Disconnected from: \(peerName)")
        
        connectedPeripherals.removeAll { $0 == peripheral }
        
        DispatchQueue.main.async {
            self.connectedPeers.removeAll { $0 == peerName }
        }
        
        delegate?.didDisconnectFromPeer(peerName)
    }
}

// MARK: - CBPeripheralDelegate

extension SimpleBLEService: CBPeripheralDelegate {
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        
        for service in services {
            if service.uuid == Self.serviceUUID {
                peripheral.discoverCharacteristics([Self.messageCharacteristicUUID, Self.nameCharacteristicUUID], for: service)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            if characteristic.uuid == Self.messageCharacteristicUUID {
                // Subscribe to notifications
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == Self.nameCharacteristicUUID {
                // Read the name
                peripheral.readValue(for: characteristic)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        
        if characteristic.uuid == Self.messageCharacteristicUUID {
            // Received a message - now with relay support
            if let message = try? JSONDecoder().decode(SimpleMessage.self, from: data) {
                handleReceivedMessage(message, fromPeer: discoveredPeripherals[peripheral] ?? "Unknown")
            }
        } else if characteristic.uuid == Self.nameCharacteristicUUID {
            // Received peer name
            if let name = String(data: data, encoding: .utf8) {
                discoveredPeripherals[peripheral] = name
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Write error: \(error)")
        } else {
            print("Message sent successfully")
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension SimpleBLEService: CBPeripheralManagerDelegate {
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        print("Peripheral manager state: \(peripheral.state.rawValue)")
        
        if peripheral.state == .poweredOn {
            startAdvertising()
        } else {
            isAdvertising = false
        }
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            print("Advertising error: \(error)")
            isAdvertising = false
        } else {
            print("Started advertising successfully")
            isAdvertising = true
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == Self.messageCharacteristicUUID,
               let data = request.value,
               let message = try? JSONDecoder().decode(SimpleMessage.self, from: data) {
                
                // Handle received message with relay support
                handleReceivedMessage(message, fromPeer: "Central")
                
                peripheral.respond(to: request, withResult: .success)
            } else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        print("Central subscribed to characteristic")
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        print("Central unsubscribed from characteristic")
    }
}
