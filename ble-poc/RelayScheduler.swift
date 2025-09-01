//
// RelayScheduler.swift
// ble-poc
//
// Relay scheduling system with jitter to prevent network congestion
// This is free and unencumbered software released into the public domain.
//

import Foundation

/**
 * RelayScheduler manages the timing and execution of message relays
 *
 * WHAT IS THE PROBLEM?
 * Without careful timing, relay systems can cause network congestion:
 * 1. Device A broadcasts a message to 5 neighbors
 * 2. All 5 neighbors immediately try to relay it at the same time
 * 3. This creates a "thundering herd" effect with network collisions
 * 4. Messages get lost, battery drains faster, network becomes unstable
 *
 * HOW DOES THIS SOLVE IT?
 * 1. JITTER: Add random delays before relaying to spread out transmissions
 * 2. CANCELLATION: Cancel scheduled relays if the same message arrives from another source
 * 3. PRIORITY: Handle different message types with different urgency levels
 * 4. BACKPRESSURE: Limit the number of concurrent scheduled relays
 *
 * EXAMPLE SCENARIO:
 * 1. Device A broadcasts "Hello" to Devices B, C, D
 * 2. RelayScheduler on Device B: "Relay in 45ms"
 * 3. RelayScheduler on Device C: "Relay in 73ms"
 * 4. RelayScheduler on Device D: "Relay in 28ms"
 * 5. Device D relays first (28ms), others receive the relay
 * 6. Devices B and C cancel their scheduled relays (duplicate detected)
 * 7. Only one relay happens instead of three!
 */
class RelayScheduler {
    
    /**
     * ScheduledRelay represents a pending relay operation
     */
    private struct ScheduledRelay {
        let messageID: String           // Unique message identifier
        let message: SimpleMessage      // The message to relay
        let scheduledAt: Date           // When this relay was scheduled
        let executeAt: Date             // When this relay should execute
        let workItem: DispatchWorkItem  // The actual relay operation
        let priority: RelayPriority     // Priority level for this relay
    }
    
    /**
     * RelayPriority determines how urgently a message should be relayed
     */
    enum RelayPriority: Int, CaseIterable {
        case low = 0        // Regular chat messages
        case normal = 1     // Standard messages
        case high = 2       // Important system messages
        case urgent = 3     // Critical messages (errors, disconnections)
        
        var description: String {
            switch self {
            case .low: return "Low"
            case .normal: return "Normal"
            case .high: return "High"
            case .urgent: return "Urgent"
            }
        }
    }
    
    // THREAD-SAFE STORAGE
    private let queue = DispatchQueue(label: "relay.scheduler", attributes: .concurrent)
    private var scheduledRelays: [String: ScheduledRelay] = [:]  // MessageID -> ScheduledRelay
    
    // CONFIGURATION
    private let maxConcurrentRelays = 20    // Maximum number of scheduled relays
    private let defaultJitterRange = 20...80 // Default jitter range in milliseconds
    
    // STATISTICS
    private var totalScheduled = 0
    private var totalExecuted = 0
    private var totalCancelled = 0
    
    // DELEGATE FOR ACTUAL RELAY EXECUTION
    weak var relayDelegate: RelaySchedulerDelegate?
    
    /**
     * Initialize the relay scheduler
     */
    init() {
        // Start periodic cleanup of expired scheduled relays
        startMaintenanceTimer()
    }
    
    // MARK: - Public Interface
    
    /**
     * Schedule a message for relay with jitter
     *
     * PARAMETERS:
     * - message: The message to relay
     * - delayMs: Base delay in milliseconds before relaying
     * - priority: Priority level for this relay (affects jitter and cancellation behavior)
     *
     * RETURNS:
     * - true if relay was scheduled successfully
     * - false if relay was rejected (duplicate, queue full, etc.)
     */
    func scheduleRelay(message: SimpleMessage, delayMs: Int, priority: RelayPriority = .normal) -> Bool {
        let messageID = message.deduplicationID
        
        return queue.sync(flags: .barrier) {
            // Check if we already have a scheduled relay for this message
            if scheduledRelays[messageID] != nil {
                print("🔄 Relay already scheduled for message: \(messageID.prefix(20))...")
                return false
            }
            
            // Check if we're at capacity
            if scheduledRelays.count >= maxConcurrentRelays {
                print("⚠️ Relay queue full, dropping message: \(messageID.prefix(20))...")
                return false
            }
            
            // Apply priority-based jitter
            let jitteredDelayMs = applyJitter(baseDelayMs: delayMs, priority: priority)
            let executeAt = Date().addingTimeInterval(Double(jitteredDelayMs) / 1000.0)
            
            // Create the relay work item
            let workItem = DispatchWorkItem { [weak self] in
                self?.executeRelay(messageID: messageID)
            }
            
            // Create the scheduled relay
            let scheduledRelay = ScheduledRelay(
                messageID: messageID,
                message: message,
                scheduledAt: Date(),
                executeAt: executeAt,
                workItem: workItem,
                priority: priority
            )
            
            // Store the scheduled relay
            scheduledRelays[messageID] = scheduledRelay
            totalScheduled += 1
            
            // Schedule the execution
            DispatchQueue.global(qos: qosForPriority(priority)).asyncAfter(
                deadline: .now() + .milliseconds(jitteredDelayMs),
                execute: workItem
            )
            
            print("📅 Scheduled relay for \(messageID.prefix(20))... in \(jitteredDelayMs)ms (priority: \(priority.description))")
            return true
        }
    }
    
    /**
     * Cancel a scheduled relay (usually because we received the message from another relay)
     *
     * PARAMETERS:
     * - messageID: The unique identifier of the message to cancel
     *
     * RETURNS:
     * - true if a relay was cancelled
     * - false if no relay was scheduled for this message
     */
    func cancelRelay(messageID: String) -> Bool {
        return queue.sync(flags: .barrier) {
            guard let scheduledRelay = scheduledRelays.removeValue(forKey: messageID) else {
                return false
            }
            
            // Cancel the work item
            scheduledRelay.workItem.cancel()
            totalCancelled += 1
            
            print("❌ Cancelled scheduled relay for \(messageID.prefix(20))... (Total cancelled: \(totalCancelled))")
            return true
        }
    }
    
    /**
     * Check if a relay is currently scheduled for a message
     */
    func isRelayScheduled(messageID: String) -> Bool {
        return queue.sync {
            return scheduledRelays[messageID] != nil
        }
    }
    
    /**
     * Get current scheduler statistics
     */
    func getStatistics() -> (scheduled: Int, executed: Int, cancelled: Int, pending: Int) {
        return queue.sync {
            return (
                scheduled: totalScheduled,
                executed: totalExecuted,
                cancelled: totalCancelled,
                pending: scheduledRelays.count
            )
        }
    }
    
    /**
     * Cancel all scheduled relays (useful for shutdown or network changes)
     */
    func cancelAllRelays() {
        queue.sync(flags: .barrier) {
            for (_, scheduledRelay) in scheduledRelays {
                scheduledRelay.workItem.cancel()
                totalCancelled += 1
            }
            scheduledRelays.removeAll()
            print("🚫 Cancelled all scheduled relays (\(scheduledRelays.count) items)")
        }
    }
    
    // MARK: - Private Implementation
    
    /**
     * Apply jitter to the base delay based on priority
     *
     * Higher priority messages get less jitter (more predictable timing)
     * Lower priority messages get more jitter (more spread out)
     */
    private func applyJitter(baseDelayMs: Int, priority: RelayPriority) -> Int {
        let jitterRange: ClosedRange<Int>
        
        switch priority {
        case .urgent:
            jitterRange = 5...15    // Very small jitter for urgent messages
        case .high:
            jitterRange = 10...30   // Small jitter for high priority
        case .normal:
            jitterRange = 20...80   // Standard jitter
        case .low:
            jitterRange = 50...150  // Large jitter for low priority
        }
        
        let jitter = Int.random(in: jitterRange)
        return baseDelayMs + jitter
    }
    
    /**
     * Convert relay priority to dispatch queue QoS class
     */
    private func qosForPriority(_ priority: RelayPriority) -> DispatchQoS.QoSClass {
        switch priority {
        case .urgent:
            return .userInteractive
        case .high:
            return .userInitiated
        case .normal:
            return .default
        case .low:
            return .utility
        }
    }
    
    /**
     * Execute a scheduled relay
     */
    private func executeRelay(messageID: String) {
        queue.sync(flags: .barrier) {
            guard let scheduledRelay = scheduledRelays.removeValue(forKey: messageID) else {
                // Relay was cancelled before execution
                return
            }
            
            // Check if the work item was cancelled
            if scheduledRelay.workItem.isCancelled {
                totalCancelled += 1
                return
            }
            
            totalExecuted += 1
            
            // Execute the relay via delegate
            DispatchQueue.main.async { [weak self] in
                self?.relayDelegate?.executeRelay(message: scheduledRelay.message)
            }
            
            print("🚀 Executed relay for \(messageID.prefix(20))... (Total executed: \(totalExecuted))")
        }
    }
    
    /**
     * Start periodic maintenance to clean up expired scheduled relays
     */
    private func startMaintenanceTimer() {
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.performMaintenance()
        }
    }
    
    /**
     * Clean up any stale scheduled relays that should have executed by now
     */
    private func performMaintenance() {
        queue.sync(flags: .barrier) {
            let now = Date()
            let expiredMessageIDs = scheduledRelays.compactMap { (messageID, scheduledRelay) in
                // If a relay was scheduled more than 5 minutes ago and hasn't executed, it's probably stuck
                return now.timeIntervalSince(scheduledRelay.scheduledAt) > 300 ? messageID : nil
            }
            
            for messageID in expiredMessageIDs {
                if let scheduledRelay = scheduledRelays.removeValue(forKey: messageID) {
                    scheduledRelay.workItem.cancel()
                    totalCancelled += 1
                }
            }
            
            if !expiredMessageIDs.isEmpty {
                print("🧹 Cleaned up \(expiredMessageIDs.count) expired scheduled relays")
            }
        }
    }
}

/**
 * Delegate protocol for executing relays
 */
protocol RelaySchedulerDelegate: AnyObject {
    /**
     * Execute a relay for the given message
     * This is called when a scheduled relay is ready to execute
     */
    func executeRelay(message: SimpleMessage)
}

/**
 * USAGE EXAMPLE:
 *
 * ```swift
 * class ChatService: RelaySchedulerDelegate {
 *     private let relayScheduler = RelayScheduler()
 *     
 *     init() {
 *         relayScheduler.relayDelegate = self
 *     }
 *     
 *     func handleReceivedMessage(_ message: SimpleMessage) {
 *         // Check for duplicates first
 *         if messageDeduplicator.isDuplicate(message.deduplicationID) {
 *             // Cancel any pending relay for this message
 *             relayScheduler.cancelRelay(messageID: message.deduplicationID)
 *             return
 *         }
 *         
 *         // Process message normally
 *         displayMessage(message)
 *         
 *         // Decide whether to relay
 *         let decision = RelayController.decide(/* parameters */)
 *         if decision.shouldRelay {
 *             let relayMessage = SimpleMessage(
 *                 relayingMessage: message,
 *                 newTTL: decision.newTTL,
 *                 relayedBy: myName
 *             )
 *             
 *             relayScheduler.scheduleRelay(
 *                 message: relayMessage,
 *                 delayMs: decision.delayMs,
 *                 priority: .normal
 *             )
 *         }
 *     }
 *     
 *     // RelaySchedulerDelegate
 *     func executeRelay(message: SimpleMessage) {
 *         broadcastMessage(message)
 *     }
 * }
 * ```
 */
