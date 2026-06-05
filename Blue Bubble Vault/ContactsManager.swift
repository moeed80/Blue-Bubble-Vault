//
//  ContactsManager.swift
//  Blue Bubble Vault
//
//  Created by Antigravity on 6/5/26.
//

import Foundation
import Contacts

public final class ContactsManager {
    public static let shared = ContactsManager()
    
    private let contactStore = CNContactStore()
    
    private init() {}
    
    /// Requests access to system contacts from the user.
    public func requestAccess(completion: @escaping (Bool) -> Void) {
        contactStore.requestAccess(for: .contacts) { granted, error in
            if let error = error {
                print("Error requesting contacts access: \(error.localizedDescription)")
            }
            completion(granted)
        }
    }
    
    /// Checks if contacts access is currently authorized.
    public func checkAuthorizationStatus() -> Bool {
        return CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }
    
    /// Resolves a phone number or email handle into a formatted "First Last" name.
    /// Returns nil if contact is not found, the handle is not a contact identity, or access is denied.
    public func resolveName(for handle: String) -> String? {
        guard checkAuthorizationStatus() else {
            return nil
        }
        
        let cleanedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedHandle.isEmpty else { return nil }
        
        // Simple heuristic: group chats or GUIDs containing semicolons/spaces/chat prefixes are ignored
        if cleanedHandle.hasPrefix("chat") || cleanedHandle.contains(";") {
            return nil
        }
        
        if cleanedHandle.contains("@") {
            return resolveEmail(email: cleanedHandle)
        } else {
            return resolvePhone(phone: cleanedHandle)
        }
    }
    
    private func resolveEmail(email: String) -> String? {
        let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
        
        do {
            let contacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: keys)
            if let contact = contacts.first {
                return CNContactFormatter.string(from: contact, style: .fullName)
            }
        } catch {
            print("Failed to fetch contact by email: \(error.localizedDescription)")
        }
        return nil
    }
    
    private func resolvePhone(phone: String) -> String? {
        let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        let cnPhone = CNPhoneNumber(stringValue: phone)
        let predicate = CNContact.predicateForContacts(matching: cnPhone)
        
        do {
            let contacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: keys)
            if let contact = contacts.first {
                return CNContactFormatter.string(from: contact, style: .fullName)
            }
        } catch {
            // Predicate search could occasionally fail if phone formatting is weird;
            // standard matching handles typical international/local strings.
            print("Failed to fetch contact by phone: \(error.localizedDescription)")
        }
        return nil
    }
}
