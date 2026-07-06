/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import SwiftUI
import Defaults

private func applyChatPanelCornerMask(_ view: NSView, radius: CGFloat) {
    view.wantsLayer = true
    view.layer?.masksToBounds = true
    view.layer?.cornerRadius = radius
    view.layer?.backgroundColor = NSColor.clear.cgColor
    if #available(macOS 13.0, *) {
        view.layer?.cornerCurve = .continuous
    }
}

// MARK: - Assistant Panel (single window — message history + input combined)
class AssistantPanel: NSPanel {

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        setupWindow()
        setupContentView()
    }

    override var canBecomeKey: Bool {
        return true  // Can receive focus for text input
    }

    override var canBecomeMain: Bool {
        return true
    }

    // Handle ESC key globally for the panel
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC key
            ScreenAssistantManager.shared.closePanels()
        } else {
            super.keyDown(with: event)
        }
    }

    private func setupWindow() {
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true  // Enable dragging
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isFloatingPanel = true

        styleMask.insert(.fullSizeContentView)

        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary
        ]

        ScreenCaptureVisibilityManager.shared.register(self, scope: .panelsOnly)

        acceptsMouseMovedEvents = true
    }

    private func setupContentView() {
        let contentView = AssistantView()
        let hostingView = NSHostingView(rootView: contentView)
        applyChatPanelCornerMask(hostingView, radius: 16)
        self.contentView = hostingView

        let preferredSize = CGSize(width: 560, height: 620)
        hostingView.setFrameSize(preferredSize)
        setContentSize(preferredSize)
    }

    func positionInCenter() {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let panelFrame = frame

        let xPosition = (screenFrame.width - panelFrame.width) / 2 + screenFrame.minX
        let yPosition = screenFrame.minY + (screenFrame.height - panelFrame.height) / 2

        setFrameOrigin(NSPoint(x: xPosition, y: yPosition))
    }

    deinit {
        ScreenCaptureVisibilityManager.shared.unregister(self)
    }
}

// MARK: - Chat Messages View (Redesigned for standalone panel)
struct AssistantView: View {
    @ObservedObject var screenAssistantManager = ScreenAssistantManager.shared
    @Default(.obsidianVaultModeEnabled) private var vaultModeEnabled
    @State private var messageText = ""
    @State private var showingApiKeyAlert = false
    @FocusState private var isTextFieldFocused: Bool

    private var currentProvider: AIModelProvider {
        Defaults[.selectedAIProvider]
    }

    private var currentModel: AIModel? {
        Defaults[.selectedAIModel]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            inputRow
        }
        .background(ChatPanelsVisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: 8)
        .alert("API Key Required", isPresented: $showingApiKeyAlert) {
            Button("Open Model Settings") {
                openModelSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please configure your API key for the selected AI provider in model settings.")
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Obsidian Assistent")
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Spacer()

            Picker("", selection: $vaultModeEnabled) {
                Text("Vault").tag(true)
                Text("Chat").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            .help("Vault: liest/schreibt deinen Obsidian Vault automatisch mit. Chat: normale Fragen ohne Vault-Bezug.")

            Button(action: {
                screenAssistantManager.resetConversationContext()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                    Text("Reset")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(8)
            }
            .disabled(screenAssistantManager.isLoading)
            .buttonStyle(PlainButtonStyle())
            .help("Clear conversation")

            Button(action: {
                screenAssistantManager.closePanels()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Close assistant")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.gray.opacity(0.05))
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if screenAssistantManager.chatMessages.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "note.text")
                                .font(.system(size: 52))
                                .foregroundColor(.blue.opacity(0.6))

                            VStack(spacing: 8) {
                                Text("Obsidian Assistent")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.primary)

                                Text("Frag etwas zu deinem Vault oder bitte um eine neue/aktualisierte Notiz.")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 80)
                    } else {
                        ForEach(screenAssistantManager.chatMessages) { message in
                            StreamingChatMessageBubble(message: message)
                                .id(message.id)
                        }

                        if screenAssistantManager.isLoading {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Denkt nach…")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                        }
                    }
                }
                .padding(.vertical, 20)
            }
            .onChange(of: screenAssistantManager.chatMessages.count) { _, _ in
                if let lastMessage = screenAssistantManager.chatMessages.last {
                    withAnimation(.easeOut(duration: 0.5)) {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: screenAssistantManager.isLoading) { _, _ in
                if screenAssistantManager.isLoading {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.easeOut(duration: 0.5)) {
                            if let lastMessage = screenAssistantManager.chatMessages.last {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private var inputRow: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: iconForProvider(currentProvider))
                        .font(.caption)
                        .foregroundColor(.blue)

                    Text(currentModel?.name ?? currentProvider.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Change", action: openModelSelection)
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            HStack(spacing: 12) {
                TextField("Frag den Obsidian Assistenten…", text: $messageText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isTextFieldFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                    .onSubmit {
                        sendMessage()
                    }

                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 12))
                        .padding(8)
                        .background(canSend ? Color.blue : Color.gray)
                        .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!canSend)
            }
            .padding(12)
        }
    }

    private func iconForProvider(_ provider: AIModelProvider) -> String {
        switch provider {
        case .local: return "server.rack"
        case .claude: return "doc.text"
        default: return "brain.head.profile"
        }
    }

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendMessage() {
        let provider = Defaults[.selectedAIProvider]
        let apiKey: String = {
            switch provider {
            case .claude: return Defaults[.claudeApiKey]
            case .local: return "local"
            default: return ""
            }
        }()

        if apiKey.isEmpty {
            showingApiKeyAlert = true
            return
        }

        let userMessage = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userMessage.isEmpty else { return }

        screenAssistantManager.sendMessage(userMessage)
        messageText = ""
    }

    private func openModelSelection() {
        let panel = ModelSelectionPanel()
        panel.positionInCenter()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Enhanced Chat Message Bubble (No Auto-Streaming)
struct StreamingChatMessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.isFromUser {
                Spacer()
            }
            
            // Avatar
            if !message.isFromUser {
                Image(systemName: "brain.head.profile")
                    .font(.title2)
                    .foregroundColor(.blue)
                    .frame(width: 32, height: 32)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Circle())
            }
            
            VStack(alignment: message.isFromUser ? .trailing : .leading, spacing: 8) {
                // Header with name and timestamp
                HStack {
                    Text(message.isFromUser ? "You" : "AI Assistant")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(message.isFromUser ? .blue : .green)
                    
                    Spacer()
                    
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Message content - NO AUTO STREAMING
                MarkdownText(content: message.content)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(message.isFromUser ? Color.blue : Color.gray.opacity(0.15))
                    )
                    .foregroundColor(message.isFromUser ? .white : .primary)
            }
            .frame(maxWidth: 400, alignment: message.isFromUser ? .trailing : .leading)
            
            // User avatar
            if message.isFromUser {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
                    .frame(width: 32, height: 32)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - Note: MarkdownText is defined in ScreenAssistantPanel.swift to avoid redeclaration conflicts.

// MARK: - Visual Effect View for Chat Panels (to avoid conflicts)
struct ChatPanelsVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

