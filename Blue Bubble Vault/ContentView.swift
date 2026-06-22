//
//  ContentView.swift
//  Blue Bubble Vault
//
//  Created by Moeed Ahmad on 6/5/26.
//

import SwiftUI
import AppKit
import CoreGraphics

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState = AppState()
    @State private var showingExportSheet = false
    @State private var exportProgress: Double = 0.0
    @State private var exportStage = "Preparing database queries..."
    @State private var timer: Timer? = nil
    @State private var selectedExportURL: URL? = nil
    @State private var exportFailed = false
    
    var body: some View {
        Group {
            if !appState.hasFDA && appState.selectedSource?.path != "simulated_demo" {
                FDAOnboardingView(appState: appState)
            } else {
                MainDashboardView(appState: appState, showingExportSheet: $showingExportSheet, triggerExport: selectExportDestination)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .environmentObject(appState)
        .onAppear {
            appState.schedulePermissionRefreshIfNeeded()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                appState.schedulePermissionRefreshIfNeeded(delay: 0.4)
            }
        }
        .sheet(isPresented: $showingExportSheet) {
            ExportProgressView(progress: exportProgress, stage: exportStage, isCompleted: exportProgress >= 1.0 && !exportFailed, isFailed: exportFailed, destinationURL: selectedExportURL) {
                showingExportSheet = false
            }
        }
    }
    
    // Presents a native macOS save panel so the user can name the export folder.
    private func selectExportDestination() {
        guard let thread = appState.selectedThread else {
            exportStage = "No conversation thread selected."
            exportProgress = 1.0
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Conversation"
        panel.message = "Blue Bubble Vault will create a new folder containing the PDF, CSV, manifest, diagnostic HTML, and copied attachments."
        panel.canCreateDirectories = true
        panel.nameFieldLabel = "Folder Name"
        panel.nameFieldStringValue = ExportPDFService.shared.defaultFolderName(for: thread, messages: appState.messages, appState: appState)
        panel.prompt = "Create Export Folder"
        panel.isExtensionHidden = true

        panel.begin { response in
            if response == .OK, let url = panel.url {
                self.selectedExportURL = url
                self.startRealExport(to: url)
            }
        }
    }

    // Perform a real export process for the currently selected thread as a local package.
    private func startRealExport(to destination: URL) {
        guard let thread = appState.selectedThread else {
            exportStage = "No conversation thread selected."
            exportProgress = 1.0
            return
        }

        let messagesToExport = appState.messages
        guard !messagesToExport.isEmpty else {
            exportStage = "No messages are available to export for the selected thread."
            exportProgress = 1.0
            return
        }

        showingExportSheet = true
        exportProgress = 0.05
        exportStage = "Preparing the export package..."
        selectedExportURL = nil
        exportFailed = false

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            DispatchQueue.main.async {
                if self.exportProgress < 0.9 {
                    self.exportProgress = min(self.exportProgress + 0.035, 0.9)
                }
            }
        }

        Task { @MainActor in
            do {
                exportProgress = 0.2
                exportStage = "Rendering the A4 PDF and sidecar files..."

                let result = try await ExportPDFService.shared.exportThreadPackage(
                    to: destination,
                    thread: thread,
                    messages: messagesToExport,
                    appState: appState
                )

                selectedExportURL = result.packageDirectoryURL
                exportProgress = 1.0
                if result.copiedAttachmentCount > 0 {
                    exportStage = "Export package completed. Copied \(result.copiedAttachmentCount) attachment file(s)."
                } else if appState.includeMedia && result.missingAttachmentCount > 0 {
                    exportStage = "Export package completed. Attachment metadata was recorded for unavailable files."
                } else {
                    exportStage = "Export package completed successfully."
                }
            } catch {
                print("Error during export: \(error.localizedDescription)")
                exportStage = "Export Failed: \(error.localizedDescription)"
                exportFailed = true
                exportProgress = 1.0
            }

            timer?.invalidate()
            timer = nil
        }
    }

    private func writeThreadPDF(to url: URL, thread: ChatThread, messages: [MessageItem]) async throws {
        _ = try await ExportPDFService.shared.exportThread(to: url, thread: thread, messages: messages, appState: appState)
    }
}

// MARK: - Brand Logo
struct BrandLogoView: View {
    let size: CGFloat
    var cornerRadius: CGFloat? = nil
    var showsShadow: Bool = false
    
    private var resolvedCornerRadius: CGFloat {
        cornerRadius ?? size * 0.22
    }
    
    var body: some View {
        Image("BrandLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(showsShadow ? 0.16 : 0), radius: showsShadow ? 10 : 0, x: 0, y: showsShadow ? 4 : 0)
            .accessibilityHidden(true)
    }
}

// MARK: - Main Dashboard View
struct MainDashboardView: View {
    @ObservedObject var appState: AppState
    @Binding var showingExportSheet: Bool
    let triggerExport: () -> Void

    private var isFilteringExport: Bool {
        appState.dateFilterMode == .range ||
        !appState.keywordFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        NavigationSplitView {
            // Sidebar: Source Picker & Contact List
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    BrandLogoView(size: 34, cornerRadius: 10)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Blue Bubble Vault")
                            .font(.headline)
                            .fontWeight(.semibold)
                        Text("Local message archive")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                
                // Database Source Selector
                VStack(alignment: .leading, spacing: 4) {
                    Text("Database Source")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    Picker("", selection: $appState.selectedSource) {
                        ForEach(appState.databaseSources) { source in
                            Text(source.displayName).tag(Optional(source))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.horizontal, 12)
                
                // Search Box
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search chats...", text: $appState.searchText)
                        .textFieldStyle(.plain)
                    if !appState.searchText.isEmpty {
                        Button(action: { appState.searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal, 12)
                
    // Contact Sync Toggle
    Toggle(isOn: $appState.isContactSyncEnabled) {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 14))
                Text("Sync Contacts")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Text(appState.contactSyncHelpText)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(3)

            if appState.shouldShowContactsSettingsButton {
                Button("Open Contacts Settings") {
                    appState.openContactsSettings()
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
        }
    }
    .toggleStyle(.switch)
    .padding(.horizontal, 12)
    .padding(.top, 4)
                
                // Contacts / Threads List
                List(appState.filteredThreads, selection: $appState.selectedThread) { thread in
                    HStack {
                        // Contact Avatar Circle
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.8)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                            .frame(width: 32, height: 32)
                            .overlay(
                                Text(String((appState.resolvedNames[thread.chatIdentifier] ?? thread.title).prefix(1)).uppercased())
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                            )
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.resolveThreadTitle(thread))
                                .font(.body)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            
                            Text(thread.chatIdentifier)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        // Message Count Badge
                        Text("\(thread.messageCount)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .clipShape(Capsule())
                    }
                    .padding(.vertical, 4)
                    .tag(thread)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
        } detail: {
            // Main Content Area: Header Configuration, Live Preview Feed, Status Bar
            VStack(spacing: 0) {
                if let selectedThread = appState.selectedThread {
                    // 1. Thread Header & Filters Panel
                    VStack(spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(appState.resolveThreadTitle(selectedThread))
                                    .font(.title2)
                                    .fontWeight(.bold)
                                Text(selectedThread.chatIdentifier)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            
                            if appState.selectedSource?.path == "simulated_demo" {
                                Text("DEMO MODE")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.orange.opacity(0.2))
                                    .foregroundColor(.orange)
                                    .cornerRadius(4)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        
                        Divider()
                        
                        // Filters Section
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                            GridRow {
                                Text("Time Period:")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                
                                Picker("", selection: $appState.dateFilterMode) {
                                    ForEach(DateFilterMode.allCases) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 280)
                            }
                            
                            if appState.dateFilterMode == .range {
                                GridRow {
                                    Text("Date Range:")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)
                                    
                                    HStack(spacing: 12) {
                                        DatePicker("Start", selection: $appState.startDate, displayedComponents: .date)
                                            .labelsHidden()
                                            .frame(width: 130)
                                        
                                        Text("to")
                                            .foregroundColor(.secondary)
                                        
                                        DatePicker("End", selection: $appState.endDate, displayedComponents: .date)
                                            .labelsHidden()
                                            .frame(width: 130)
                                    }
                                }
                            }
                            
                            GridRow {
                                Text("Keyword search:")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                
                                HStack {
                                    Image(systemName: "line.3.horizontal.decrease.circle")
                                        .foregroundColor(.secondary)
                                    TextField("Filter messages in view...", text: $appState.keywordFilter)
                                        .textFieldStyle(.plain)
                                }
                                .padding(6)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                    .background(Color(NSColor.windowBackgroundColor))
                    
                    Divider()
                    
                    // 2. Chat History Preview
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(appState.messages) { message in
                                    MessageBubbleView(message: message)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(20)
                        }
                        .background(Color(NSColor.textBackgroundColor))
                        .onChange(of: appState.messages.count) { _ in
                            if let lastMsg = appState.messages.last {
                                proxy.scrollTo(lastMsg.id, anchor: .bottom)
                            }
                        }
                    }
                    
                    Divider()
                    
                    // 3. Export Configuration and Pre-Flight Checks (Bottom Bar)
                    VStack(spacing: 12) {
                        HStack(spacing: 24) {
                            // Attachment Toggle
                            Toggle(isOn: $appState.includeMedia) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Include Media Attachments")
                                        .fontWeight(.medium)
                                    Text("Copy available local attachment files into the export package")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            
                            Spacer()
                            
                            // Storage Pre-Flight Metrics
                            HStack(spacing: 16) {
                                if isFilteringExport {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("Messages to Export:")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text("\(appState.messages.count)")
                                            .font(.subheadline)
                                            .fontWeight(.bold)
                                    }
                                    
                                    Divider()
                                        .frame(height: 30)
                                }
                                
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("Estimated Export Size:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(formatBytes(appState.estimatedExportSize))
                                        .font(.subheadline)
                                        .fontWeight(.bold)
                                }
                                
                                Divider()
                                    .frame(height: 30)
                                
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("Available Mac Space:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(formatBytes(appState.availableSpace))
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                }
                                
                                // Status Indicator
                                if appState.isSpaceSafe {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 8, height: 8)
                                        Text("Safe")
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .foregroundColor(.green)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.green.opacity(0.15))
                                    .cornerRadius(6)
                                } else {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 8, height: 8)
                                        Text("Insufficient Space")
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .foregroundColor(.red)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.red.opacity(0.15))
                                    .cornerRadius(6)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        
                        // Action Buttons
                        HStack {
                            if appState.selectedSource?.path == "simulated_demo" {
                                Button("Back to FDA Check") {
                                    appState.selectedSource = appState.databaseSources.first
                                }
                                .buttonStyle(.bordered)
                            }
                            
                            Spacer()
                            
                            Button("Cancel") {
                                appState.selectedThread = nil
                            }
                            .buttonStyle(.bordered)
                            .keyboardShortcut(.cancelAction)
                            
                            Button("Export Package") {
                                triggerExport()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!appState.isSpaceSafe || appState.messages.isEmpty)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }
                    .background(Color(NSColor.windowBackgroundColor))
                    
                } else {
                    // Empty State
                    VStack(spacing: 16) {
                        Image(systemName: "tray.2.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.5))
                        
                        Text("No Chat Selected")
                            .font(.headline)
                        
                        Text("Choose a database source from the sidebar, then select a conversation thread to review and export.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))
                }
            }
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Message Bubble Component
struct MessageBubbleView: View {
    @EnvironmentObject var appState: AppState
    let message: MessageItem
    
    var body: some View {
        HStack {
            if message.isFromMe { Spacer() }
            
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                // Sender label for incoming group messages
                if !message.isFromMe && !message.senderID.isEmpty {
                    Text(appState.resolvedNames[message.senderID] ?? message.senderID)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
                }
                
                // Bubble container
                VStack(alignment: .leading, spacing: 8) {
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.body)
                            .foregroundColor(message.isFromMe ? .white : .primary)
                    }
                    
                    // Display attachments inside the bubble if present
                    if !message.attachments.isEmpty {
                        ForEach(message.attachments) { attachment in
                            HStack(spacing: 8) {
                                Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(message.isFromMe ? .white : .blue)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: attachment.filename).lastPathComponent)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(message.isFromMe ? .white : .primary)
                                    Text(formatBytes(attachment.totalBytes))
                                        .font(.system(size: 9))
                                        .foregroundColor(message.isFromMe ? .white.opacity(0.7) : .secondary)
                                }
                            }
                            .padding(8)
                            .background(message.isFromMe ? Color.white.opacity(0.15) : Color.black.opacity(0.05))
                            .cornerRadius(6)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.isFromMe ?
                    LinearGradient(colors: [Color.blue, Color.blue.opacity(0.85)], startPoint: .top, endPoint: .bottom) :
                    LinearGradient(colors: [Color.primary.opacity(0.07), Color.primary.opacity(0.07)], startPoint: .top, endPoint: .bottom)
                )
                .cornerRadius(16)
                
                // Timestamp
                Text(formatDate(message.date))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.8))
                    .padding(.horizontal, 6)
            }
            
            if !message.isFromMe { Spacer() }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - FDA Onboarding Screen
struct FDAOnboardingView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Header brand mark
            BrandLogoView(size: 86, cornerRadius: 24, showsShadow: true)
            
            VStack(spacing: 8) {
                Text("Full Disk Access Required")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Blue Bubble Vault executes 100% locally to archive your chats. Because Apple databases are protected, macOS requires Full Disk Access to search and read them.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            if let warning = FDAPermissionManager.shared.permissionPersistenceWarning {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(warning)
                        .font(.callout)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: 460)
            }
            
            // Step-by-Step Instructions card
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "1.circle.fill").foregroundColor(.blue)
                    Text("If needed, move the app to Applications, then click **Open System Settings** below.")
                }
                
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "2.circle.fill").foregroundColor(.blue)
                    Text("Find **Blue Bubble Vault** in the list and toggle the switch to **ON**.")
                }
                
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "3.circle.fill").foregroundColor(.blue)
                    Text("Relaunch or click **Check Access Again** below to load your data.")
                }
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
            .cornerRadius(12)
            .frame(maxWidth: 460)
            
            HStack(spacing: 16) {
                Button("Open System Settings") {
                    appState.requestFDAPermission()
                    appState.schedulePermissionRefreshIfNeeded(delay: 1.0)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                Button("Check Access Again") {
                    withAnimation {
                        appState.refreshPermissionsAndReloadSelectedSource()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            
            Divider()
                .frame(width: 200)
            
            // Safe Sandbox Escape Hatch
            VStack(spacing: 6) {
                Text("Just testing or have no local database?")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Button("Launch Simulated Demo Mode") {
                    withAnimation {
                        // Select the simulated source
                        if let demoSource = appState.databaseSources.first(where: { $0.path == "simulated_demo" }) {
                            appState.selectedSource = demoSource
                        }
                    }
                }
                .buttonStyle(.link)
            }
            
            Spacer()
        }
        .padding(40)
        .background(Color(NSColor.textBackgroundColor))
    }
}
