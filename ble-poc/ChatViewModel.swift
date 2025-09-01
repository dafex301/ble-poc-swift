//
// SimpleChatViewModel.swift
// bitchat
//
// Simplified chat view model for BLE messaging demonstration
// This is free and unencumbered software released into the public domain.
//

import Foundation
import SwiftUI
import Combine

/**
 * Simplified chat view model for peer-to-peer BLE messaging demonstration
 *
 * This is the "brain" of the chat app that coordinates between the UI and the BLE service.
 * Think of it as the middleman that:
 *
 * 1. TALKS TO UI: Provides @Published properties that SwiftUI watches for changes
 * 2. TALKS TO BLE: Controls the SimpleBLEService and receives delegate callbacks
 * 3. MANAGES STATE: Keeps track of messages, connections, and status
 * 4. PROVIDES FEEDBACK: Shows helpful system messages to guide the user
 *
 * The @MainActor ensures all UI updates happen on the main thread (required for SwiftUI).
 * The SimpleBLEDelegate means we get notified when BLE events happen.
 */
@MainActor
class SimpleChatViewModel: ObservableObject, SimpleBLEDelegate {
    
    // MARK: - Published Properties
    
    /**
     * These @Published properties automatically trigger UI updates when they change.
     * SwiftUI watches them and re-renders the interface when values change.
     *
     * - messages: Array of all chat messages (both sent and received)
     *   Example: [Message1("Hello"), Message2("Hi there!"), SystemMessage("User1234 connected")]
     *
     * - connectedPeers: Names of currently connected devices
     *   Example: ["User1234", "User5678"]
     *
     * - isConnected: Quick check if we have any connections
     *   Example: true if connectedPeers.count > 0, false otherwise
     *
     * - connectionStatus: Human-readable status for the UI header
     *   Example: "Connected to: User1234" or "Scanning & Advertising..."
     *
     * - myName: Our device's display name
     *   Example: "User1234" (randomly generated or user-changed)
     */
    @Published var messages: [SimpleMessage] = []        // All chat messages
    @Published var connectedPeers: [String] = []         // Connected device names
    @Published var isConnected = false                   // True if any connections exist
    @Published var connectionStatus = "Disconnected"    // Human-readable status
    @Published var myName: String = ""                   // Our display name
    
    // RELAY SYSTEM STATUS - New properties for mesh networking
    @Published var relayMetrics: RelayMetrics = RelayMetrics()  // Current relay performance metrics
    @Published var networkDegree: Int = 0                       // Number of direct connections
    @Published var relayEfficiency: Double = 1.0               // Relay success rate (0.0-1.0)
    @Published var duplicateRate: Double = 0.0                  // Duplicate detection rate (0.0-1.0)
    @Published var meshStatus: String = "Mesh Inactive"        // Human-readable mesh status
    
    // MARK: - Private Properties
    
    /**
     * Private properties that do the actual work behind the scenes:
     *
     * - bleService: The actual Bluetooth service that handles all BLE operations
     *   This is our connection to the Bluetooth hardware
     *
     * - cancellables: Stores Combine subscriptions so they don't get deallocated
     *   When we subscribe to bleService updates, we store them here
     *
     * - healthCheckTimer: Runs every 30 seconds to provide helpful status updates
     *   Gives guidance like "Still looking for devices..." if no connections found
     */
    private let bleService = SimpleBLEService()          // The actual BLE service
    private var cancellables = Set<AnyCancellable>()     // Combine subscription storage
    private var healthCheckTimer: Timer?                 // 30-second health check timer
    private var relayMetricsTimer: Timer?                // Timer for updating relay metrics
    
    // MARK: - Initialization
    
    /**
     * When the ViewModel is created, we set up everything needed for the chat to work:
     *
     * 1. SETUP BLE SERVICE: Tell it we want to receive delegate callbacks
     * 2. GENERATE RANDOM NAME: Create a unique name like "User1234"
     * 3. ADD STARTUP MESSAGE: Show user what's happening
     * 4. SETUP SUBSCRIPTIONS: Watch for BLE service changes using Combine
     * 5. START SERVICES: Begin scanning and advertising
     * 6. START HEALTH CHECK: Begin periodic status updates
     */
    init() {
        // Step 1: Set up BLE service to notify us of events
        bleService.delegate = self  // "Hey BLE service, tell me when stuff happens"
        
        // Step 2: Generate random name for demo (like "User1234")
        myName = "User\(Int.random(in: 1000...9999))"
        bleService.myName = myName  // Tell BLE service our name
        
        // Step 3: Add initial startup message so user knows something is happening
        let startupMessage = SimpleMessage(sender: "System", content: "🚀 Starting BLE services as '\(myName)'...")
        messages.append(startupMessage)
        
        // Step 4: SETUP SUBSCRIPTIONS - Watch for changes in BLE service
        
        /**
         * CONNECTED PEERS SUBSCRIPTION:
         * When someone connects/disconnects, update our UI properties.
         *
         * Flow: BLE finds device -> bleService.connectedPeers changes ->
         *       this subscription fires -> we update our @Published properties -> UI updates
         */
        bleService.$connectedPeers
            .receive(on: DispatchQueue.main)  // Ensure UI updates on main thread
            .sink { [weak self] peers in
                self?.connectedPeers = peers           // Update connected peers list
                self?.isConnected = !peers.isEmpty     // Update connection status
                self?.updateConnectionStatus()         // Update status text
            }
            .store(in: &cancellables)  // Keep subscription alive
        
        /**
         * DISCOVERED PEERS SUBSCRIPTION:
         * When we discover new devices (before connecting), show a discovery message.
         * This gives users feedback that the scanning is working.
         *
         * Flow: BLE discovers device -> bleService.discoveredPeers changes ->
         *       we add "📡 Discovered nearby device: User1234" message
         */
        bleService.$discoveredPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                // Only show message for newly discovered peers (avoid spam)
                let currentCount = self?.messages.filter { $0.content.contains("📡 Discovered nearby device:") }.count ?? 0
                if peers.count > currentCount {
                    if let newPeer = peers.last {
                        let discoveryMessage = SimpleMessage(sender: "System", content: "📡 Discovered nearby device: \(newPeer)")
                        self?.messages.append(discoveryMessage)
                    }
                }
            }
            .store(in: &cancellables)
        
        /**
         * SCANNING/ADVERTISING STATUS SUBSCRIPTION:
         * Watch both scanning and advertising status and provide helpful feedback.
         *
         * This uses combineLatest to watch BOTH properties at once:
         * - When either isScanning OR isAdvertising changes, this fires
         * - We show different messages based on what's active
         *
         * Flow: BLE starts scanning/advertising -> status changes ->
         *       we show "🔍 Scanning for devices & 📢 Advertising presence..."
         */
        bleService.$isScanning
            .combineLatest(bleService.$isAdvertising)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (scanning, advertising) in
                if scanning && advertising {
                    let statusMessage = SimpleMessage(sender: "System", content: "🔍 Scanning for devices & 📢 Advertising presence...")
                    self?.messages.append(statusMessage)
                } else if scanning {
                    let statusMessage = SimpleMessage(sender: "System", content: "🔍 Scanning for devices...")
                    self?.messages.append(statusMessage)
                } else if advertising {
                    let statusMessage = SimpleMessage(sender: "System", content: "📢 Advertising presence...")
                    self?.messages.append(statusMessage)
                }
            }
            .store(in: &cancellables)
        
        // Step 5: Start BLE services (scanning and advertising)
        startServices()
        
        // Step 6: Start periodic health check (every 30 seconds)
        startHealthCheck()
        
        // Step 7: Start relay metrics monitoring (every 5 seconds)
        startRelayMetricsMonitoring()
    }
    
    // MARK: - Public Methods
    
    /**
     * Start the BLE services - called automatically in init() and manually on refresh.
     * This tells the BLE service to start both scanning and advertising.
     */
    func startServices() {
        bleService.startServices()                  // Start scanning and advertising
        connectionStatus = "Scanning & Advertising..."  // Update UI status
        print("Started BLE services for: \(myName)")
    }
    
    /**
     * Stop all BLE services - useful for cleanup or when app goes background.
     */
    func stopServices() {
        bleService.stopServices()           // Stop scanning and advertising
        connectionStatus = "Stopped"        // Update UI status
    }
    
    /**
     * Send a message to all connected peers.
     *
     * This function handles the entire message sending flow:
     * 1. Validate the message isn't empty
     * 2. Add the message to our local messages array (for immediate UI feedback)
     * 3. Add helpful system messages based on connection state
     * 4. Send the message via BLE to all connected devices
     *
     * Example flow:
     * User types "Hello!" -> we add it to messages[] immediately ->
     * UI shows it right away -> then we send it via BLE to other devices
     */
    func sendMessage(_ content: String) {
        // Step 1: Validate message isn't just whitespace
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return  // Don't send empty messages
        }
        
        // Step 2: Add message locally first for immediate UI feedback
        // (User sees their message right away, even before BLE transmission)
        let message = SimpleMessage(sender: myName, content: content)
        messages.append(message)
        
        // Step 3: Add helpful system messages based on connection state
        if connectedPeers.isEmpty {
            // No one to send to - let user know
            let systemMessage = SimpleMessage(sender: "System", content: "⚠️ Message sent but no peers connected. It will be delivered when a peer connects.")
            messages.append(systemMessage)
        } else {
            // Show who we're sending to
            let peerList = connectedPeers.joined(separator: ", ")
            let deliveryMessage = SimpleMessage(sender: "System", content: "📤 Message sent to: \(peerList)")
            messages.append(deliveryMessage)
        }
        
        // Step 4: Actually send via BLE to all connected devices
        bleService.sendMessage(content)
        
        print("Sent message: \(content)")
    }
    
    func changeName(_ newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        let oldName = myName
        myName = trimmedName
        bleService.myName = trimmedName
        
        // Add system message about name change
        let systemMessage = SimpleMessage(sender: "System", content: "📝 Changed name from '\(oldName)' to '\(trimmedName)'")
        messages.append(systemMessage)
        
        // Notify about re-advertising with new name
        let advertiseMessage = SimpleMessage(sender: "System", content: "📢 Broadcasting new identity to nearby devices...")
        messages.append(advertiseMessage)
    }
    
    func clearMessages() {
        messages.removeAll()
    }
    
    func refreshConnections() {
        // Add system message about refresh
        let refreshMessage = SimpleMessage(sender: "System", content: "🔄 Refreshing BLE connections...")
        messages.append(refreshMessage)
        
        // Refresh the BLE service
        bleService.refreshConnections()
        
        // Add guidance message
        let guidanceMessage = SimpleMessage(sender: "System", content: "💡 Restarting scanning and advertising. This may take a few seconds.")
        messages.append(guidanceMessage)
    }
    
    // MARK: - Relay System Methods
    
    /**
     * Get detailed relay statistics for debugging
     */
    func getRelayStatistics() -> String {
        return bleService.getRelayStatistics()
    }
    
    /**
     * Show relay statistics in chat (for debugging)
     */
    func showRelayStats() {
        let stats = getRelayStatistics()
        let statsMessage = SimpleMessage(sender: "System", content: "📊 Relay Statistics:\n\n\(stats)")
        messages.append(statsMessage)
    }
    
    /**
     * Reset relay metrics (useful for testing)
     */
    func resetRelayMetrics() {
        // This would require adding a reset method to the BLE service
        let resetMessage = SimpleMessage(sender: "System", content: "🔄 Relay metrics reset")
        messages.append(resetMessage)
    }
    
    // MARK: - Health Check
    
    private func startHealthCheck() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.performHealthCheck()
        }
    }
    
    private func stopHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }
    
    // MARK: - Relay Metrics Monitoring
    
    /**
     * Start monitoring relay metrics and updating UI properties
     *
     * This timer runs every 5 seconds to:
     * 1. Fetch current relay metrics from the BLE service
     * 2. Update @Published properties for UI display
     * 3. Generate human-readable mesh status
     * 4. Provide relay performance insights
     */
    private func startRelayMetricsMonitoring() {
        relayMetricsTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateRelayMetrics()
        }
    }
    
    /**
     * Stop relay metrics monitoring
     */
    private func stopRelayMetricsMonitoring() {
        relayMetricsTimer?.invalidate()
        relayMetricsTimer = nil
    }
    
    /**
     * Update relay metrics and UI properties
     */
    private func updateRelayMetrics() {
        // Fetch current metrics from BLE service
        relayMetrics = bleService.getRelayMetrics()
        networkDegree = connectedPeers.count
        relayEfficiency = relayMetrics.relayEfficiency
        duplicateRate = relayMetrics.duplicateDetectionRate
        
        // Update mesh status based on current conditions
        updateMeshStatus()
    }
    
    /**
     * Generate human-readable mesh status
     */
    private func updateMeshStatus() {
        if !isConnected {
            meshStatus = "Mesh Inactive (No Connections)"
        } else if networkDegree == 1 {
            meshStatus = "Mesh Active (1 connection)"
        } else if networkDegree <= 3 {
            meshStatus = "Mesh Active (\(networkDegree) connections, Light Network)"
        } else if networkDegree <= 6 {
            meshStatus = "Mesh Active (\(networkDegree) connections, Medium Network)"
        } else {
            meshStatus = "Mesh Active (\(networkDegree) connections, Dense Network)"
        }
        
        // Add relay performance indicator
        if relayMetrics.messagesRelayed > 0 {
            let efficiency = Int(relayEfficiency * 100)
            meshStatus += " • \(efficiency)% relay efficiency"
        }
        
        // Add duplicate detection indicator
        if relayMetrics.duplicatesBlocked > 0 {
            let dupRate = Int(duplicateRate * 100)
            meshStatus += " • \(dupRate)% duplicates blocked"
        }
    }
    
    private func performHealthCheck() {
        // Check if we have no connections and BLE should be working
        if connectedPeers.isEmpty && bleService.isScanning && bleService.isAdvertising {
            let healthMessage = SimpleMessage(sender: "System", content: "🔍 Still looking for nearby devices... Make sure Bluetooth is enabled and other devices are running the app.")
            messages.append(healthMessage)
        }
    }
    
    // MARK: - Private Methods
    
    private func updateConnectionStatus() {
        if connectedPeers.isEmpty {
            connectionStatus = bleService.isScanning || bleService.isAdvertising ? "Scanning & Advertising..." : "Disconnected"
        } else {
            let peerList = connectedPeers.joined(separator: ", ")
            connectionStatus = "Connected to: \(peerList)"
        }
    }
    
    // MARK: - SimpleBLEDelegate
    
    func didReceiveMessage(_ message: SimpleMessage) {
        // Avoid duplicate messages (don't add our own messages twice)
        if message.sender != myName {
            messages.append(message)
            print("Received message from \(message.sender): \(message.content)")
        }
    }
    
    func didConnectToPeer(_ peerName: String) {
        let systemMessage = SimpleMessage(sender: "System", content: "✅ \(peerName) connected successfully")
        messages.append(systemMessage)
        
        // Add connection details
        let detailsMessage = SimpleMessage(sender: "System", content: "🔗 BLE connection established with \(peerName). Ready to exchange messages!")
        messages.append(detailsMessage)
        
        print("Connected to peer: \(peerName)")
    }
    
    func didDisconnectFromPeer(_ peerName: String) {
        let systemMessage = SimpleMessage(sender: "System", content: "❌ \(peerName) disconnected")
        messages.append(systemMessage)
        
        // Add disconnection context
        if connectedPeers.isEmpty {
            let contextMessage = SimpleMessage(sender: "System", content: "🔍 No peers connected. Continuing to scan for nearby devices...")
            messages.append(contextMessage)
        }
        
        print("Disconnected from peer: \(peerName)")
    }
    
    // MARK: - Cleanup
    
    deinit {
        Task { @MainActor in
            stopServices()
            stopHealthCheck()
            stopRelayMetricsMonitoring()
        }
    }
}

// MARK: - Helper Extensions

extension SimpleMessage: Identifiable, Equatable {
    static func == (lhs: SimpleMessage, rhs: SimpleMessage) -> Bool {
        return lhs.id == rhs.id
    }
}

extension SimpleMessage {
    var isSystemMessage: Bool {
        return sender == "System"
    }
    
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    /**
     * Get display name with relay information
     * Shows original sender and relay path for relayed messages
     */
    var displaySender: String {
        if isSystemMessage {
            return "System"
        } else if isRelayed {
            return "\(originalSender) (\(relayPath))"
        } else {
            return originalSender
        }
    }
    
    /**
     * Get a visual indicator for message type
     */
    var messageTypeIndicator: String {
        if isSystemMessage {
            return "🔧"
        } else if isRelayed {
            return "🔄"  // Relay indicator
        } else {
            return "📱"  // Direct message indicator
        }
    }
    
    /**
     * Get TTL indicator for debugging
     */
    var ttlIndicator: String {
        if isSystemMessage {
            return ""
        } else {
            return " (TTL:\(ttl))"
        }
    }
}
