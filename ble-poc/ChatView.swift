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
        // iPad specific improvements
        .navigationViewStyle(.stack)
    }
    
    // MARK: - Header View
    
    private var headerView: some View {
        VStack(spacing: 8) {
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
                        Text(message.isSystemMessage ? "System" : message.sender)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(message.isSystemMessage ? .orange : .blue)
                        
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

// MARK: - Preview

#Preview {
    SimpleChatView()
}
