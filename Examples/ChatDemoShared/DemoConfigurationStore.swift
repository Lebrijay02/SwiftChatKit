//
//  DemoConfigurationStore.swift
//  ChatDemo
//
//  Everything but the key in `UserDefaults`; the key in the Keychain. Splitting
//  them is the point of this file — it is the smallest honest version of the
//  advice in `OpenAIBackendConfig.apiKey`.
//

import Foundation
import Security

enum DemoConfigurationStore {

    private static let defaultsKey = "ChatDemo.configuration"
    private static let keychainAccount = "ChatDemo.apiKey"
    private static var keychainService: String {
        Bundle.main.bundleIdentifier ?? "ChatDemo"
    }

    // MARK: - Configuration

    static func load() -> DemoConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(DemoConfiguration.self, from: data)
    }

    static func save(_ configuration: DemoConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        saveAPIKey("")
    }

    // MARK: - API key

    static func loadAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return "" }

        return key
    }

    /// Delete-then-add rather than `SecItemUpdate`, so this one path covers
    /// both "never set" and "changed in the sheet".
    static func saveAPIKey(_ key: String) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(identity as CFDictionary)

        guard !key.isEmpty, let data = key.data(using: .utf8) else { return }

        var attributes = identity
        attributes[kSecValueData as String] = data
        // The demo has no background work, so the key never needs to be
        // readable while the device is locked.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
