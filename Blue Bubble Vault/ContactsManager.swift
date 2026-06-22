//
//  ContactsManager.swift
//  Blue Bubble Vault
//
//  Created by Antigravity on 6/5/26.
//

import Foundation
import Contacts
import AppKit

public enum ContactsAuthorizationState: String {
    case authorized
    case notDetermined
    case denied
    case restricted
    case unknown
}

public struct ContactLookupRecord {
    public let displayName: String
    public let phoneNumbers: [String]
    public let emailAddresses: [String]

    public init(displayName: String, phoneNumbers: [String], emailAddresses: [String]) {
        self.displayName = displayName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
    }
}

public final class ContactsManager {
    public static let shared = ContactsManager()
    
    private let cacheLock = NSLock()
    private var cachedResolvedNamesByLookupKey: [String: String]?
    
    private init() {}
    
    /// Requests access to system contacts from the user.
    public func requestAccess(completion: @escaping (Bool) -> Void) {
        let state = authorizationState()
        if state == .authorized {
            completion(true)
            return
        }

        guard state == .notDetermined else {
            completion(false)
            return
        }

        CNContactStore().requestAccess(for: .contacts) { granted, error in
            if let error = error {
                print("Error requesting contacts access: \(error.localizedDescription)")
            }
            if granted {
                self.invalidateCache()
            }
            completion(granted)
        }
    }
    
    /// Checks if contacts access is currently authorized.
    public func checkAuthorizationStatus() -> Bool {
        authorizationState() == .authorized
    }

    public func authorizationState() -> ContactsAuthorizationState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }

    public func openContactsPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Resolves a phone number or email handle into a formatted "First Last" name.
    /// Returns nil if contact is not found, the handle is not a contact identity, or access is denied.
    public func resolveName(for handle: String) -> String? {
        guard checkAuthorizationStatus() else {
            return nil
        }
        
        let index = resolvedNamesByLookupKey()
        if let resolvedName = Self.resolvedName(for: handle, in: index) {
            return resolvedName
        }

        return resolveNameWithContactPredicates(for: handle)
    }

    /// Resolves a batch of handles against the cached Contacts index.
    /// This intentionally avoids per-handle predicate lookups, which are too expensive for large real threads.
    public func resolveNames(for handles: Set<String>) -> [String: String] {
        guard checkAuthorizationStatus(), !handles.isEmpty else {
            return [:]
        }

        return Self.resolvedNames(for: handles, in: resolvedNamesByLookupKey())
    }

    public static func resolvedName(for handle: String, in records: [ContactLookupRecord]) -> String? {
        let index = buildResolvedNameIndex(from: records)
        return resolvedName(for: handle, in: index)
    }

    public static func resolvedName(for handle: String, in index: [String: String]) -> String? {
        let lookupKeys = lookupKeys(for: handle)
        guard !lookupKeys.isEmpty else { return nil }

        return lookupKeys.sorted().compactMap { index[$0] }.first
    }

    public static func resolvedNames(for handles: Set<String>, in index: [String: String]) -> [String: String] {
        var resolved: [String: String] = [:]

        for handle in handles {
            if let displayName = resolvedName(for: handle, in: index) {
                resolved[handle] = displayName
            }
        }

        return resolved
    }

    public static func buildResolvedNameIndex(from records: [ContactLookupRecord]) -> [String: String] {
        var index: [String: String] = [:]

        for record in records {
            let displayName = record.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty else { continue }

            let identities = record.phoneNumbers + record.emailAddresses
            for identity in identities {
                for key in lookupKeys(for: identity) where index[key] == nil {
                    index[key] = displayName
                }
            }
        }

        return index
    }

    public static func lookupKeys(for handle: String) -> Set<String> {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Ignore group chat identifiers and composite handle lists.
        if trimmed.hasPrefix("chat") || trimmed.contains(";") {
            return []
        }

        if trimmed.contains("@") {
            return ["email:\(trimmed.lowercased())"]
        }

        let digits = asciiDigits(in: trimmed)
        guard digits.count >= 7 else { return [] }

        var keys: Set<String> = ["phone:digits:\(digits)"]

        if digits.count == 10 {
            keys.insert("phone:us:\(digits)")
            keys.insert("phone:e164:+1\(digits)")
        } else if digits.count == 11, digits.first == "1" {
            let nationalNumber = String(digits.dropFirst())
            keys.insert("phone:us:\(nationalNumber)")
            keys.insert("phone:e164:+\(digits)")
        } else if trimmed.hasPrefix("+") {
            keys.insert("phone:e164:+\(digits)")
        }

        return keys
    }

    private static func asciiDigits(in text: String) -> String {
        text.unicodeScalars.reduce(into: "") { result, scalar in
            if scalar.value >= 48 && scalar.value <= 57 {
                result.unicodeScalars.append(scalar)
            }
        }
    }

    static func phoneSearchCandidates(for handle: String) -> [String] {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = asciiDigits(in: trimmed)
        guard digits.count >= 7 else { return [] }

        var candidates: [String] = [trimmed, digits]

        if digits.count == 10 {
            candidates.append("+1\(digits)")
        } else if digits.count == 11, digits.first == "1" {
            candidates.append("+\(digits)")
            candidates.append(String(digits.dropFirst()))
        } else if trimmed.hasPrefix("+") {
            candidates.append("+\(digits)")
        }

        var seen = Set<String>()
        return candidates.filter { candidate in
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalized.isEmpty && seen.insert(normalized).inserted
        }
    }

    private func resolvedNamesByLookupKey() -> [String: String] {
        cacheLock.lock()
        if let cachedResolvedNamesByLookupKey {
            cacheLock.unlock()
            return cachedResolvedNamesByLookupKey
        }

        let loadedIndex = loadResolvedNamesByLookupKey()
        cachedResolvedNamesByLookupKey = loadedIndex
        cacheLock.unlock()

        return loadedIndex
    }

    private func invalidateCache() {
        cacheLock.lock()
        cachedResolvedNamesByLookupKey = nil
        cacheLock.unlock()
    }

    private func loadResolvedNamesByLookupKey() -> [String: String] {
        let keys = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ] as [CNKeyDescriptor]

        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true

        var records: [ContactLookupRecord] = []
        let contactStore = CNContactStore()

        do {
            try contactStore.enumerateContacts(with: request) { contact, _ in
                let displayName = self.displayName(for: contact)
                guard !displayName.isEmpty else { return }

                records.append(
                    ContactLookupRecord(
                        displayName: displayName,
                        phoneNumbers: contact.phoneNumbers.map { $0.value.stringValue },
                        emailAddresses: contact.emailAddresses.map { String($0.value) }
                    )
                )
            }
        } catch {
            return [:]
        }

        return Self.buildResolvedNameIndex(from: records)
    }

    private func displayName(for contact: CNContact) -> String {
        let parts = [contact.givenName, contact.familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let fullName = parts.joined(separator: " ")
        if !fullName.isEmpty {
            return fullName
        }

        return contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveNameWithContactPredicates(for handle: String) -> String? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("@") {
            return resolveEmailWithPredicate(trimmed)
        }

        for candidate in Self.phoneSearchCandidates(for: trimmed) {
            if let resolvedName = resolvePhoneWithPredicate(candidate) {
                return resolvedName
            }
        }

        return nil
    }

    private func resolveEmailWithPredicate(_ email: String) -> String? {
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: email.lowercased())
        return firstDisplayName(matching: predicate, contactStore: CNContactStore())
    }

    private func resolvePhoneWithPredicate(_ phone: String) -> String? {
        let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phone))
        return firstDisplayName(matching: predicate, contactStore: CNContactStore())
    }

    private func firstDisplayName(matching predicate: NSPredicate, contactStore: CNContactStore) -> String? {
        let keys = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor
        ] as [CNKeyDescriptor]

        do {
            let contacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: keys)
            return contacts.lazy.map { self.displayName(for: $0) }.first { !$0.isEmpty }
        } catch {
            return nil
        }
    }
}
