//
// BLEDemoView.swift
// bitchat
//
// BLE messaging demonstration view
// This is free and unencumbered software released into the public domain.
//

import SwiftUI

/// Main demo view for BLE messaging proof of concept
struct BLEDemoView: View {
    @State private var showingInfo = false
    
    var body: some View {
        NavigationStack {
            SimpleChatView()
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Info") {
                            showingInfo = true
                        }
                    }
                }
        }
        .sheet(isPresented: $showingInfo) {
            NavigationStack {
                DemoInfoView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                showingInfo = false
                            }
                        }
                    }
            }
        }
    }
}

/// Information view explaining how the BLE demo works
struct DemoInfoView: View {
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("🔗 Bluetooth Low Energy Chat")
                                .font(.title2)
                                .fontWeight(.bold)
                            
                            Text("This is a simplified proof of concept demonstrating peer-to-peer messaging using Bluetooth Low Energy (BLE).")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("How it Works")
                                .font(.title3)
                                .fontWeight(.semibold)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top) {
                                    Text("1.")
                                        .fontWeight(.medium)
                                        .foregroundColor(.blue)
                                    Text("Each device acts as both a **scanner** (central) and **advertiser** (peripheral)")
                                }
                                
                                HStack(alignment: .top) {
                                    Text("2.")
                                        .fontWeight(.medium)
                                        .foregroundColor(.blue)
                                    Text("Devices automatically discover and connect to each other")
                                }
                                
                                HStack(alignment: .top) {
                                    Text("3.")
                                        .fontWeight(.medium)
                                        .foregroundColor(.blue)
                                    Text("Messages are sent directly between connected devices")
                                }
                                
                                HStack(alignment: .top) {
                                    Text("4.")
                                        .fontWeight(.medium)
                                        .foregroundColor(.blue)
                                    Text("No internet or cellular connection required")
                                }
                            }
                        }
                    }
                    
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Technical Details")
                                .font(.title3)
                                .fontWeight(.semibold)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                detailRow("Service UUID:", "12345678-1234-5678-9ABC-123456789ABC")
                                detailRow("Message Char:", "87654321-4321-8765-CBA9-987654321CBA")
                                detailRow("Name Char:", "11111111-2222-3333-4444-555555555555")
                                detailRow("Message Format:", "JSON encoded SimpleMessage struct")
                                detailRow("Auto-connect:", "Devices connect automatically when discovered")
                            }
                        }
                    }
                    
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Testing Instructions")
                                .font(.title3)
                                .fontWeight(.semibold)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("• Install this app on two iOS devices")
                                Text("• Make sure Bluetooth is enabled on both devices")
                                Text("• Open the BLE Chat tab on both devices")
                                Text("• Devices should automatically discover and connect")
                                Text("• Start sending messages between the devices")
                                Text("• Watch the connection status at the top")
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                    
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Limitations")
                                .font(.title3)
                                .fontWeight(.semibold)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("• Range: ~10-100 meters depending on environment")
                                Text("• Only direct peer-to-peer (no mesh routing)")
                                Text("• Message size limited by BLE MTU (~512 bytes)")
                                Text("• iOS app backgrounding may limit connectivity")
                            }
                            .foregroundColor(.orange)
                        }
                    }
                    
                    Spacer(minLength: 50)
                }
                .padding()
            }
            .navigationTitle("BLE Demo Info")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
//                .fontFamily(.monospaced)
//                .foregroundColor(.primary)
        }
    }
}

// MARK: - Preview

#Preview("Demo") {
    BLEDemoView()
}

#Preview("Info") {
    DemoInfoView()
}
