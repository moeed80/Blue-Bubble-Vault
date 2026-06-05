//
//  FDAPermissionManager.swift
//  Blue Bubble Vault
//
//  Created by Antigravity on 6/5/26.
//

import Foundation
import Cocoa

public final class FDAPermissionManager {
    public static let shared = FDAPermissionManager()
    
    private init() {}
    
    /// Checks if Full Disk Access is currently granted.
    /// It attempts to read the `~/Library/Messages` folder. If access is blocked by macOS TCC,
    /// it catches the permission error and returns false.
    public func checkFullDiskAccess() -> Bool {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let messagesURL = homeDir.appendingPathComponent("Library/Messages")
        
        do {
            // Attempting to read the contents of the directory.
            // Under TCC restrictions without FDA, this will throw an error (POSIX EPERM or Cocoa 257).
            _ = try FileManager.default.contentsOfDirectory(at: messagesURL, includingPropertiesForKeys: nil)
            return true
        } catch {
            let nsError = error as NSError
            
            // Common cocoa permission code is 257 (NSFileReadNoPermissionError)
            if nsError.code == NSFileReadNoPermissionError {
                return false
            }
            
            // Check POSIX error code for Operation Not Permitted (EPERM = 1)
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EPERM) {
                return false
            }
            
            // If the folder simply does not exist (e.g. fresh installation or no Messages configuration),
            // we will fallback to checking the Safari directory, which is also protected by FDA.
            if !FileManager.default.fileExists(atPath: messagesURL.path) {
                let safariURL = homeDir.appendingPathComponent("Library/Safari")
                do {
                    _ = try FileManager.default.contentsOfDirectory(at: safariURL, includingPropertiesForKeys: nil)
                    return true
                } catch {
                    let safariError = error as NSError
                    if safariError.code == NSFileReadNoPermissionError || 
                       (safariError.domain == NSPOSIXErrorDomain && safariError.code == Int(EPERM)) {
                        return false
                    }
                }
            }
            
            // If we get here and the error isn't a permission error, we assume FDA isn't the blocker.
            // (e.g., folder missing is not a permission issue).
            return true
        }
    }
    
    /// Opens macOS System Settings to the Privacy & Security -> Full Disk Access panel.
    public func openSystemSettingsForFDA() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
