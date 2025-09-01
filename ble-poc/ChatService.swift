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
 * Simple message structure for demo
 *
 * This is basically a text message with some metadata:
 * - id: Unique identifier for each message (like "ABC123")
 * - sender: Who sent it (like "User1234")
 * - content: The actual message text (like "Hello!")
 * - timestamp: When it was sent
 *
 * Example message:
 * {
 *   "id": "550e8400-e29b-41d4-a716-446655440000",
 *   "sender": "User1234",
 *   "content": "Hello there!",
 *   "timestamp": "2024-01-01T12:00:00Z"
 * }
 */
struct SimpleMessage: Codable {
    let id: String
    let sender: String
    let content: String
    let timestamp: Date
    
    init(sender: String, content: String) {
        self.id = UUID().uuidString  // Generate unique ID automatically
        self.sender = sender
        self.content = content
        self.timestamp = Date()      // Current time
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
 * Simplified BLE service for peer-to-peer messaging demonstration
 *
 * This class does TWO jobs at once (like being both a walkie-talkie transmitter AND receiver):
 *
 * 1. CENTRAL ROLE (Scanner): Looks for other devices to connect to
 *    - Like walking around with a radar looking for friends
 *    - Finds devices, connects to them, sends/receives messages
 *
 * 2. PERIPHERAL ROLE (Advertiser): Makes itself visible to other devices
 *    - Like putting up a big sign saying "I'm here, come chat with me!"
 *    - Other devices can find you and connect to you
 *
 * Why both roles? Because in BLE, you need one device to be a "Central" (scanner)
 * and one to be a "Peripheral" (advertiser). Since we don't know which device
 * will be which, EVERY device does BOTH roles. This way any two devices can
 * always connect to each other.
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
     * When the service is created, we set up the two Core Bluetooth managers:
     * - centralManager: For finding and connecting to other devices
     * - peripheralManager: For being visible and accepting connections
     *
     * Both managers will call our delegate methods when things happen.
     */
    override init() {
        super.init()
        
        // Create the managers - they'll start calling our delegate methods immediately
        centralManager = CBCentralManager(delegate: self, queue: nil)
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
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
     * Send a message to ALL connected devices.
     *
     * This is the tricky part - since we're both Central AND Peripheral, we need to send the message in TWO ways:
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
     * Example flow:
     * 1. User types "Hello!" and hits send
     * 2. We create a SimpleMessage with sender=myName, content="Hello!"
     * 3. Convert message to JSON data
     * 4. Send via both peripheral (broadcast) and central (direct) methods
     * 5. All connected devices receive the message
     */
    func sendMessage(_ content: String) {
        // Step 1: Create the message object
        let message = SimpleMessage(sender: myName, content: content)
        
        // Step 2: Convert to JSON data for transmission
        guard let data = try? JSONEncoder().encode(message),
              let messageChar = messageCharacteristic else {
            print("❌ Failed to encode message or characteristic not ready")
            return
        }
        
        // Step 3a: PERIPHERAL SIDE - Broadcast to devices connected TO US
        // This sends to any device that is acting as Central and connected to us
        peripheralManager.updateValue(data, for: messageChar, onSubscribedCentrals: nil)
        
        // Step 3b: CENTRAL SIDE - Send directly to devices WE connected to
        // This sends to any device that we connected to (where we're acting as Central)
        for peripheral in connectedPeripherals {
            if let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }),
               let characteristic = service.characteristics?.first(where: { $0.uuid == Self.messageCharacteristicUUID }) {
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
            }
        }
        
        print("📤 Sent message: \(content)")
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
            // Received a message
            if let message = try? JSONDecoder().decode(SimpleMessage.self, from: data) {
                print("Received message from \(message.sender): \(message.content)")
                delegate?.didReceiveMessage(message)
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
                
                print("Received message from central: \(message.sender): \(message.content)")
                delegate?.didReceiveMessage(message)
                
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
