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
}
