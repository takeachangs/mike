import Foundation
import Security

/// The OpenAI API key, kept in the login Keychain rather than a file. OPENAI_API_KEY in the environment still wins,
/// so a terminal launch with the key exported needs no setup.
public enum Keychain {
    static let service = "com.takeachangs.mike", account = "openai-api-key"

    public static var openAIKey: String? {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty { return env }
        return stored
    }

    public static var stored: String? {
        var out: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether a key is saved, without reading it: reading the secret of an item an earlier (differently signed) build
    /// saved asks for the login password, a lookup of its attributes doesn't.
    public static var hasOpenAIKey: Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// Saves the key (updating the saved one in place, so a refused save never loses it), or removes it when empty.
    /// Returns false when the Keychain refused.
    @discardableResult public static func setOpenAIKey(_ key: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [errSecSuccess, errSecItemNotFound].contains(SecItemDelete(base as CFDictionary)) }
        let updated = SecItemUpdate(base as CFDictionary, [kSecValueData as String: Data(trimmed.utf8)] as CFDictionary)
        guard updated == errSecItemNotFound else { return updated == errSecSuccess }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
