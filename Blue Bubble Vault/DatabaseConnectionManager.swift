//
//  DatabaseConnectionManager.swift
//  Blue Bubble Vault
//
//  Created by Antigravity on 6/5/26.
//

import Foundation

public struct DatabaseSource: Identifiable, Hashable {
    public enum SourceType: Hashable {
        case icloud
        case usbBackup(udid: String, deviceName: String, backupDate: Date)
    }
    
    public var id: String {
        switch type {
        case .icloud:
            return "icloud"
        case .usbBackup(let udid, _, _):
            return "usb-\(udid)"
        }
    }
    
    public let type: SourceType
    public let path: String
    
    public var displayName: String {
        switch type {
        case .icloud:
            return "iCloud Live Messages"
        case .usbBackup(_, let deviceName, let date):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let dateStr = formatter.string(from: date)
            return "\(deviceName) (Backup: \(dateStr))"
        }
    }
    
    public var isUSBBackup: Bool {
        switch type {
        case .icloud: return false
        case .usbBackup: return true
        }
    }
}

public final class DatabaseConnectionManager {
    public static let shared = DatabaseConnectionManager()
    
    private init() {}
    
    /// Returns the live iCloud message database source.
    public func getICloudSource() -> DatabaseSource {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let chatDbPath = homeDir.appendingPathComponent("Library/Messages/chat.db").path
        return DatabaseSource(type: .icloud, path: chatDbPath)
    }
    
    /// Scans the MobileSync backup directory to find all unencrypted iOS backup databases.
    public func scanUSBBackups() -> [DatabaseSource] {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let backupsURL = homeDir.appendingPathComponent("Library/Application Support/MobileSync/Backup")
        
        var sources: [DatabaseSource] = []
        
        guard fileManager.fileExists(atPath: backupsURL.path) else {
            return []
        }
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            
            for folderURL in contents {
                let udid = folderURL.lastPathComponent
                let infoPlistURL = folderURL.appendingPathComponent("Info.plist")
                
                guard fileManager.fileExists(atPath: infoPlistURL.path) else {
                    continue
                }
                
                // Parse the device and backup metadata
                if let plistData = try? Data(contentsOf: infoPlistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                    
                    let deviceName = plist["Device Name"] as? String ?? "Unknown iPhone"
                    let backupDate = plist["Last Backup Date"] as? Date ?? Date(timeIntervalSince1970: 0)
                    
                    // In iOS backups, Library/SMS/sms.db is hashed to:
                    // 3d/3d0d13e22d319ae2d96bc384d7322d4f8df28d6e
                    let dbURL = folderURL.appendingPathComponent("3d/3d0d13e22d319ae2d96bc384d7322d4f8df28d6e")
                    
                    if fileManager.fileExists(atPath: dbURL.path) {
                        sources.append(DatabaseSource(
                            type: .usbBackup(udid: udid, deviceName: deviceName, backupDate: backupDate),
                            path: dbURL.path
                        ))
                    }
                }
            }
        } catch {
            print("Failed to read MobileSync backups directory: \(error.localizedDescription)")
        }
        
        // Sort latest backups first
        return sources.sorted {
            switch ($0.type, $1.type) {
            case (.usbBackup(_, _, let d1), .usbBackup(_, _, let d2)):
                return d1 > d2
            default:
                return false
            }
        }
    }
}
