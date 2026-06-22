//
//  ExportProgressView.swift
//  Blue Bubble Vault
//
//  Created by Moeed Ahmad on 6/5/26.
//

import SwiftUI

// MARK: - Export Progress Sheet View
struct ExportProgressView: View {
    let progress: Double
    let stage: String
    let isCompleted: Bool
    let isFailed: Bool
    let destinationURL: URL?
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            Text(statusTitle)
                .font(.title2)
                .fontWeight(.bold)
            
            if isCompleted {
                // Success Badge
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.green)
                    .transition(.scale)
            } else if isFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.orange)
                    .transition(.scale)
            } else {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 300)
            }
            
            VStack(spacing: 12) {
                Text(stage)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                if isCompleted {
                    Text("Generated locally: A4 PDF, CSV, manifest JSON, and diagnostic HTML. Attachments are copied only when enabled and available.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    
                    if let url = destinationURL {
                        Text(url.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(6)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                } else if isFailed {
                    Text("No export package was completed. You can adjust the destination or filters and try again.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            }
            
            if isCompleted || isFailed {
                Button("Dismiss") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button("Dismiss") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(width: 420, height: 300)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var statusTitle: String {
        if isFailed {
            return "Export Failed"
        }
        if isCompleted {
            return "Export Package Created"
        }
        return "Exporting Conversation..."
    }
}
