//
// RelayController.swift
// ble-poc
//
// Bluetooth Mesh Relay Controller for intelligent message forwarding
// This is free and unencumbered software released into the public domain.
//

import Foundation

/**
 * RelayDecision encapsulates a single relay scheduling choice
 *
 * This struct contains everything needed to make a smart relay decision:
 * - shouldRelay: Whether this message should be forwarded to other devices
 * - newTTL: The updated Time-To-Live value (decremented from original)
 * - delayMs: Random delay in milliseconds to prevent network congestion
 *
 * Example decision:
 * RelayDecision(shouldRelay: true, newTTL: 4, delayMs: 45)
 * Meaning: "Yes, relay this message with TTL=4 after waiting 45ms"
 */
struct RelayDecision {
    let shouldRelay: Bool    // Should we forward this message?
    let newTTL: UInt8        // New TTL value (original TTL - 1)
    let delayMs: Int         // Delay before relaying (prevents congestion)
}

/**
 * RelayController centralizes flood control policy for Bluetooth mesh relays
 *
 * WHAT IS A RELAY?
 * In a Bluetooth mesh network, devices act as "relays" to forward messages between
 * devices that aren't directly connected. Think of it like a chain of people passing
 * a message across a crowded room - each person (device) passes the message to the
 * next person until it reaches its destination.
 *
 * WHY DO WE NEED SMART RELAY DECISIONS?
 * Without intelligent relay control, mesh networks suffer from "broadcast storms":
 * 1. Device A sends a message
 * 2. Devices B, C, D all receive it and immediately relay it
 * 3. Now devices E, F, G receive 3 copies and each relays all 3 copies
 * 4. The network gets flooded with duplicate messages and becomes unusable
 *
 * HOW DOES THIS CONTROLLER SOLVE IT?
 * 1. TTL (Time To Live): Each message has a "hop count" that decreases by 1 at each relay
 * 2. Probabilistic Relaying: Not every device relays every message (based on network density)
 * 3. Jitter/Delay: Random delays prevent all devices from relaying simultaneously
 * 4. Degree-Aware Logic: Devices with many connections relay less frequently
 *
 * EXAMPLE SCENARIO:
 * - Network has 10 devices, each connected to 3-4 others
 * - Device A sends "Hello" with TTL=5
 * - Device B receives it, controller decides: 70% chance to relay, wait 35ms, new TTL=4
 * - Device C receives it, controller decides: 90% chance to relay, wait 52ms, new TTL=4
 * - This continues until TTL reaches 1 (no more relaying) or message reaches all devices
 */
struct RelayController {
    
    /**
     * Main decision function - determines if and how to relay a message
     *
     * PARAMETERS EXPLAINED:
     * - ttl: Time To Live - how many more hops this message can make
     * - senderIsSelf: Did we originally send this message? (never relay our own messages)
     * - isEncrypted: Is this an encrypted message? (handle differently for security)
     * - isDirectedFragment: Is this a fragment meant for a specific recipient?
     * - isHandshake: Is this a security handshake message? (lower relay probability)
     * - degree: How many peers are we connected to? (affects relay probability)
     * - highDegreeThreshold: At what connection count do we consider a node "high degree"?
     *
     * RETURNS:
     * RelayDecision with shouldRelay, newTTL, and delayMs
     */
    static func decide(ttl: UInt8,
                       senderIsSelf: Bool,
                       isEncrypted: Bool,
                       isDirectedFragment: Bool,
                       isHandshake: Bool,
                       degree: Int,
                       highDegreeThreshold: Int) -> RelayDecision {
        
        // STEP 1: SUPPRESS OBVIOUS NON-RELAYS
        // Don't relay if TTL is too low (would expire immediately) or if we sent it originally
        if ttl <= 1 || senderIsSelf {
            return RelayDecision(shouldRelay: false, newTTL: ttl, delayMs: 0)
        }
        
        // STEP 2: DEGREE-AWARE PROBABILITY TO REDUCE FLOODS IN DENSE GRAPHS
        // The more connections a device has, the lower its relay probability
        // This prevents "hub" devices from flooding the network
        let baseProb: Double
        switch degree {
        case 0...2:     baseProb = 1.0   // Always relay if you have few connections
        case 3...4:     baseProb = 0.9   // Almost always relay
        case 5...6:     baseProb = 0.7   // Usually relay
        case 7...9:     baseProb = 0.55  // Sometimes relay
        default:        baseProb = 0.45  // Rarely relay if you're a major hub
        }
        
        // STEP 3: ADJUST PROBABILITY FOR SPECIAL MESSAGE TYPES
        var prob = baseProb
        
        // Handshake messages are relayed less frequently to reduce security noise
        if isHandshake {
            prob = max(0.3, baseProb - 0.2)  // Reduce by 20%, but never below 30%
        }
        
        // Encrypted messages might need special handling in the future
        // For now, treat them normally
        
        // Directed fragments (parts of messages meant for specific recipients)
        // are relayed normally since they need to reach their destination
        
        // STEP 4: MAKE THE RELAY DECISION
        // Use random number generation to decide whether to relay
        let shouldRelay = Double.random(in: 0...1) <= prob
        
        // STEP 5: TTL CLAMPING IN DENSE GRAPHS
        // In very dense networks, limit how far messages can travel
        // This prevents messages from bouncing around forever in large networks
        let ttlCap: UInt8 = degree >= highDegreeThreshold ? 3 : 5
        let clamped = max(1, min(ttl, ttlCap))  // Clamp between 1 and ttlCap
        let newTTL = clamped &- 1  // Decrement by 1 (safe subtraction)
        
        // STEP 6: ADD JITTER TO DESYNCHRONIZE REBROADCASTS
        // Random delay prevents all devices from relaying at the same time
        // This spreads out the network load and reduces collisions
        let delayMs = Int.random(in: 20...80)  // 20-80ms random delay
        
        return RelayDecision(
            shouldRelay: shouldRelay,
            newTTL: newTTL,
            delayMs: delayMs
        )
    }
    
    /**
     * Helper function to determine if a message type should be relayed at all
     *
     * Some message types might never need relaying (like local status updates)
     * This function can be extended to filter out non-relayable message types
     */
    static func isRelayableMessageType(_ messageType: String) -> Bool {
        // For now, all message types are relayable
        // In the future, we might exclude certain local-only message types
        return true
    }
    
    /**
     * Calculate network congestion level based on recent relay activity
     *
     * This can be used to further adjust relay probabilities during high traffic periods
     * Currently unused but provided for future enhancement
     */
    static func calculateCongestionLevel(recentRelayCount: Int, timeWindow: TimeInterval) -> Double {
        // Simple congestion calculation: more recent relays = higher congestion
        let relaysPerSecond = Double(recentRelayCount) / timeWindow
        
        // Normalize to 0.0-1.0 scale (0 = no congestion, 1 = high congestion)
        return min(1.0, relaysPerSecond / 10.0)  // 10 relays/second = full congestion
    }
}

/**
 * USAGE EXAMPLE:
 *
 * ```swift
 * // When receiving a message from another device:
 * let decision = RelayController.decide(
 *     ttl: receivedMessage.ttl,           // e.g., 5
 *     senderIsSelf: false,                // We didn't send this
 *     isEncrypted: false,                 // Plain text message
 *     isDirectedFragment: false,          // Not a fragment
 *     isHandshake: false,                 // Not a handshake
 *     degree: connectedPeers.count,       // e.g., 3 connections
 *     highDegreeThreshold: 6              // Consider 6+ connections as "high degree"
 * )
 *
 * if decision.shouldRelay {
 *     // Wait for the jitter delay, then relay the message
 *     DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(decision.delayMs)) {
 *         var relayMessage = receivedMessage
 *         relayMessage.ttl = decision.newTTL
 *         sendMessage(relayMessage)
 *     }
 * }
 * ```
 */
