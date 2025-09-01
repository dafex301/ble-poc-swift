//
// MessageDeduplicator.swift
// ble-poc
//
// Message deduplication system to prevent relay loops and duplicate messages
// This is free and unencumbered software released into the public domain.
//

import Foundation

/**
 * MessageDeduplicator prevents relay loops and duplicate message processing
 *
 * WHAT IS THE PROBLEM?
 * In a Bluetooth mesh network, messages can arrive via multiple paths:
 * 1. Device A sends "Hello" to Device B and Device C
 * 2. Device B relays "Hello" to Device D
 * 3. Device C also relays "Hello" to Device D
 * 4. Device D receives the same "Hello" message twice!
 *
 * Without deduplication, Device D would:
 * - Show "Hello" twice in the chat
 * - Potentially relay it twice to other devices
 * - Create an infinite loop of message forwarding
 *
 * HOW DOES THIS SOLVE IT?
 * 1. UNIQUE MESSAGE IDS: Each message has a unique identifier
 * 2. MEMORY OF SEEN MESSAGES: We remember which messages we've already processed
 * 3. AUTOMATIC CLEANUP: Old message IDs are forgotten to prevent memory leaks
 * 4. THREAD SAFETY: Multiple BLE connections can check simultaneously
 *
 * EXAMPLE FLOW:
 * 1. Device D receives "Hello" (ID: "User1234-ABC123") via Device B
 * 2. Deduplicator checks: "Have I seen User1234-ABC123 before?" → No
 * 3. Deduplicator marks it as seen, message is processed normally
 * 4. Device D receives same "Hello" (ID: "User1234-ABC123") via Device C
 * 5. Deduplicator checks: "Have I seen User1234-ABC123 before?" → Yes!
 * 6. Message is ignored, no duplicate processing or relay
 */
class MessageDeduplicator {
    
    /**
     * SeenMessage tracks when we first saw a message
     * We store both the message ID and timestamp for cleanup purposes
     */
    private struct SeenMessage {
        let messageID: String
        let firstSeenAt: Date
    }
    
    // THREAD-SAFE STORAGE
    // We use a concurrent queue with barriers for thread safety
    // Multiple threads can read simultaneously, but writes are exclusive
    private let queue = DispatchQueue(label: "message.deduplication", attributes: .concurrent)
    private var seenMessages: Set<String> = []          // Fast lookup for message IDs
    private var messageTimestamps: [String: Date] = [:] // Track when we first saw each message
    
    // CLEANUP CONFIGURATION
    // How long to remember message IDs before forgetting them
    private let retentionPeriod: TimeInterval = 300  // 5 minutes (300 seconds)
    
    // How often to run cleanup (remove old message IDs)
    private let cleanupInterval: TimeInterval = 60   // 1 minute
    
    // Timer for automatic cleanup
    private var cleanupTimer: Timer?
    
    // STATISTICS (for debugging and monitoring)
    private var totalMessagesSeen: Int = 0
    private var duplicatesBlocked: Int = 0
    
    /**
     * Initialize the deduplicator and start automatic cleanup
     */
    init() {
        startCleanupTimer()
    }
    
    deinit {
        stopCleanupTimer()
    }
    
    // MARK: - Public Interface
    
    /**
     * Check if a message has been seen before (thread-safe)
     *
     * PARAMETERS:
     * - messageID: Unique identifier for the message (usually sender-id-timestamp)
     *
     * RETURNS:
     * - true if this message has been seen before (duplicate)
     * - false if this is the first time we've seen this message
     *
     * EXAMPLE:
     * ```swift
     * let messageID = "User1234-550e8400-e29b-41d4-a716-446655440000"
     * if deduplicator.isDuplicate(messageID) {
     *     print("Ignoring duplicate message")
     *     return
     * }
     * // Process message normally...
     * ```
     */
    func isDuplicate(_ messageID: String) -> Bool {
        return queue.sync {
            let isDupe = seenMessages.contains(messageID)
            
            if isDupe {
                // Update statistics
                duplicatesBlocked += 1
                print("🚫 Blocked duplicate message: \(messageID.prefix(20))... (Total blocked: \(duplicatesBlocked))")
            } else {
                // Mark as seen for future checks
                seenMessages.insert(messageID)
                messageTimestamps[messageID] = Date()
                totalMessagesSeen += 1
                
                // Only log non-duplicates if we want to reduce noise
                // print("✅ New message: \(messageID.prefix(20))... (Total seen: \(totalMessagesSeen))")
            }
            
            return isDupe
        }
    }
    
    /**
     * Manually mark a message as seen (useful for pre-marking our own messages)
     *
     * EXAMPLE:
     * ```swift
     * // Before sending our own message, mark it as seen so we don't process it if it comes back
     * let messageID = myMessage.deduplicationID
     * deduplicator.markAsSeen(messageID)
     * sendMessage(myMessage)
     * ```
     */
    func markAsSeen(_ messageID: String) {
        queue.async(flags: .barrier) {
            if !self.seenMessages.contains(messageID) {
                self.seenMessages.insert(messageID)
                self.messageTimestamps[messageID] = Date()
                self.totalMessagesSeen += 1
            }
        }
    }
    
    /**
     * Check if a message ID exists in our seen set (without marking it as seen)
     */
    func contains(_ messageID: String) -> Bool {
        return queue.sync {
            return seenMessages.contains(messageID)
        }
    }
    
    /**
     * Get current deduplication statistics (thread-safe)
     */
    func getStatistics() -> (totalSeen: Int, duplicatesBlocked: Int, currentlyCached: Int) {
        return queue.sync {
            return (
                totalSeen: totalMessagesSeen,
                duplicatesBlocked: duplicatesBlocked,
                currentlyCached: seenMessages.count
            )
        }
    }
    
    /**
     * Clear all stored message IDs (useful for testing or memory pressure)
     */
    func clearAll() {
        queue.async(flags: .barrier) {
            self.seenMessages.removeAll()
            self.messageTimestamps.removeAll()
            print("🧹 Cleared all message deduplication cache")
        }
    }
    
    // MARK: - Automatic Cleanup
    
    /**
     * Start the automatic cleanup timer
     * This runs every minute to remove old message IDs from memory
     */
    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: cleanupInterval, repeats: true) { [weak self] _ in
            self?.performCleanup()
        }
    }
    
    /**
     * Stop the automatic cleanup timer
     */
    private func stopCleanupTimer() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
    }
    
    /**
     * Remove old message IDs to prevent memory leaks
     *
     * This function runs periodically to remove message IDs that are older than
     * the retention period. This prevents the deduplicator from using unlimited memory.
     *
     * CLEANUP LOGIC:
     * 1. Calculate cutoff time (now - retentionPeriod)
     * 2. Find all message IDs older than cutoff
     * 3. Remove them from both seenMessages and messageTimestamps
     * 4. Log cleanup statistics
     */
    private func performCleanup() {
        queue.async(flags: .barrier) {
            let now = Date()
            let cutoffTime = now.addingTimeInterval(-self.retentionPeriod)
            
            // Find old message IDs to remove
            let oldMessageIDs = self.messageTimestamps.compactMap { (messageID, timestamp) in
                return timestamp < cutoffTime ? messageID : nil
            }
            
            // Remove old message IDs
            for messageID in oldMessageIDs {
                self.seenMessages.remove(messageID)
                self.messageTimestamps.removeValue(forKey: messageID)
            }
            
            if !oldMessageIDs.isEmpty {
                print("🧹 Cleaned up \(oldMessageIDs.count) old message IDs (kept \(self.seenMessages.count))")
            }
        }
    }
    
    /**
     * Force an immediate cleanup (useful for testing or memory pressure)
     */
    func forceCleanup() {
        performCleanup()
    }
}

/**
 * USAGE EXAMPLES:
 *
 * ```swift
 * // 1. Basic duplicate checking
 * let deduplicator = MessageDeduplicator()
 * 
 * func handleReceivedMessage(_ message: SimpleMessage) {
 *     if deduplicator.isDuplicate(message.deduplicationID) {
 *         return // Ignore duplicate
 *     }
 *     
 *     // Process message normally
 *     displayMessage(message)
 *     
 *     // Decide whether to relay
 *     if shouldRelay(message) {
 *         relayMessage(message)
 *     }
 * }
 *
 * // 2. Pre-marking our own messages
 * func sendMessage(_ content: String) {
 *     let message = SimpleMessage(sender: myName, content: content)
 *     
 *     // Mark our own message as seen before sending
 *     deduplicator.markAsSeen(message.deduplicationID)
 *     
 *     broadcastMessage(message)
 * }
 *
 * // 3. Monitoring statistics
 * func printStats() {
 *     let stats = deduplicator.getStatistics()
 *     print("Seen: \(stats.totalSeen), Blocked: \(stats.duplicatesBlocked), Cached: \(stats.currentlyCached)")
 * }
 * ```
 */
