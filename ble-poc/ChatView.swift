//
// SimpleChatView.swift
// bitchat
//
// Simple chat view for BLE messaging demonstration
// This is free and unencumbered software released into the public domain.
//

import SwiftUI

struct SimpleChatView: View {
    @StateObject private var viewModel = SimpleChatViewModel()
    @State private var messageText = ""
    @State private var showingNameAlert = false
    @State private var newName = ""
    @State private var showingRelayStats = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Status header
            headerView
            
            // Messages list
            messagesView
            
            // Input area
            inputView
        }
        .navigationTitle("BLE Chat Demo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("Stats") {
                    showingRelayStats = true
                }
                .foregroundColor(.purple)
                
                Button("Refresh") {
                    viewModel.refreshConnections()
                }
                .foregroundColor(.blue)
                
                Button("Clear") {
                    viewModel.clearMessages()
                }
                
                Button("Name") {
                    newName = viewModel.myName
                    showingNameAlert = true
                }
            }
        }
        .alert("Change Name", isPresented: $showingNameAlert) {
            TextField("Enter your name", text: $newName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                viewModel.changeName(newName)
            }
        } message: {
            Text("Enter a new name for this device")
        }
        .sheet(isPresented: $showingRelayStats) {
            RelayStatsView(viewModel: viewModel)
        }
        // iPad specific improvements
        .navigationViewStyle(.stack)
    }
    
    // MARK: - Header View
    
    private var headerView: some View {
        VStack(spacing: 8) {
            // Connection status row
            HStack {
                Circle()
                    .fill(viewModel.isConnected ? .green : .orange)
                    .frame(width: 12, height: 12)
                
                Text(viewModel.connectionStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("You: \(viewModel.myName)")
                    .font(.caption)
                    .foregroundColor(.primary)
            }
            
            // Mesh status row
            HStack {
                Circle()
                    .fill(viewModel.isConnected ? .purple : .gray)
                    .frame(width: 8, height: 8)
                
                Text(viewModel.meshStatus)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if viewModel.relayMetrics.messagesReceived > 0 {
                    Text("\(viewModel.relayMetrics.messagesReceived) msgs")
                        .font(.caption2)
                        .foregroundColor(.purple)
                }
            }
            
            if !viewModel.connectedPeers.isEmpty {
                HStack {
                    Text("Connected:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    ForEach(viewModel.connectedPeers, id: \.self) { peer in
                        Text(peer)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(8)
                    }
                    
                    Spacer()
                }
            } else {
                // Show refresh hint when no peers connected
                HStack {
                    Text("No devices connected")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    
                    Spacer()
                    
                    Button("Tap Refresh", action: {
                        viewModel.refreshConnections()
                    })
                    .font(.caption2)
                    .foregroundColor(.blue)
                }
            }
            
            Divider()
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
    
    // MARK: - Messages View
    
    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) { _ in
                // Auto-scroll to bottom when new message arrives
                if let lastMessage = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    private func messageRow(_ message: SimpleMessage) -> some View {
        HStack {
            if message.sender == viewModel.myName {
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    HStack {
                        Text(message.formattedTime)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Text("You")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                    }
                    
                    Text(message.content)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(16)
                }
                .frame(maxWidth: 250, alignment: .trailing)
                
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(message.messageTypeIndicator)
                            .font(.caption2)
                        
                        Text(message.displaySender)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(message.isSystemMessage ? .orange : .blue)
                        
                        if !message.isSystemMessage {
                            Text(message.ttlIndicator)
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                        
                        Spacer()
                        
                        Text(message.formattedTime)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Text(message.content)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(message.isSystemMessage ? Color.orange.opacity(0.2) : Color.gray.opacity(0.2))
                        .foregroundColor(.primary)
                        .cornerRadius(16)
                }
                .frame(maxWidth: 250, alignment: .leading)
                
                Spacer()
            }
        }
    }
    
    // MARK: - Input View
    
    private var inputView: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack {
                TextField("Type a message...", text: $messageText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onSubmit {
                        sendMessage()
                    }
                
                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.blue)
                        .cornerRadius(18)
                }
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
    }
    
    // MARK: - Actions
    
    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        viewModel.sendMessage(messageText)
        messageText = ""
    }
}

// MARK: - Relay Statistics View

struct RelayStatsView: View {
    @ObservedObject var viewModel: SimpleChatViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Network Overview
                    statsSection("Network Overview") {
                        statRow("Network Degree", value: "\(viewModel.networkDegree) connections")
                        statRow("Mesh Status", value: viewModel.meshStatus)
                        statRow("Connected Peers", value: viewModel.connectedPeers.joined(separator: ", "))
                    }
                    
                    // Message Statistics
                    statsSection("Message Statistics") {
                        statRow("Total Messages", value: "\(viewModel.relayMetrics.messagesReceived)")
                        statRow("Direct Messages", value: "\(viewModel.relayMetrics.directMessages)")
                        statRow("Relayed Messages", value: "\(viewModel.relayMetrics.relayedMessages)")
                        statRow("Relay Ratio", value: "\(Int(viewModel.relayMetrics.relayRatio * 100))%")
                        if viewModel.relayMetrics.averageHopCount > 0 {
                            statRow("Avg Hop Count", value: String(format: "%.1f", viewModel.relayMetrics.averageHopCount))
                        }
                    }
                    
                    // Relay Performance
                    statsSection("Relay Performance") {
                        statRow("Relays Scheduled", value: "\(viewModel.relayMetrics.relaysScheduled)")
                        statRow("Relays Executed", value: "\(viewModel.relayMetrics.relaysExecuted)")
                        statRow("Relays Cancelled", value: "\(viewModel.relayMetrics.relaysCancelled)")
                        statRow("Relay Efficiency", value: "\(Int(viewModel.relayEfficiency * 100))%")
                        statRow("Messages Relayed", value: "\(viewModel.relayMetrics.messagesRelayed)")
                    }
                    
                    // Duplicate Detection
                    statsSection("Duplicate Detection") {
                        statRow("Duplicates Blocked", value: "\(viewModel.relayMetrics.duplicatesBlocked)")
                        statRow("Detection Rate", value: "\(Int(viewModel.duplicateRate * 100))%")
                    }
                    
                    // Actions
                    VStack(spacing: 12) {
                        Button("Show Detailed Stats in Chat") {
                            viewModel.showRelayStats()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("Reset Metrics") {
                            viewModel.resetRelayMetrics()
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.orange)
                    }
                    .padding(.top)
                }
                .padding()
            }
            .navigationTitle("Relay Statistics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func statsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }
    
    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundColor(.primary)
        }
        .font(.subheadline)
    }
}

// MARK: - Preview

#Preview {
    SimpleChatView()
}
