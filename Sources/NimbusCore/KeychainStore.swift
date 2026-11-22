import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum KeychainStore {
    public static let service = "com.maestro37.nimbusterm"

    /// Never show the system keychain dialog: an unreadable item is treated as absent,
    /// and the app asks for the password again instead.
    private static func quietContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private static let stampKey = "secretsBuildStamp"

    /// Items are ACL-bound to the code signature. When the executable changes
    /// (a different build), reading an old item would ask for the login
    /// password, so the old items are dropped instead.
    private static var buildStamp: String {
        guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url) else {
            return "unknown"
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func prepareStore() {
        let stamp = buildStamp
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: stampKey) != stamp else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
        lock.lock(); cache.removeAll(); lock.unlock()
        defaults.set(stamp, forKey: stampKey)
    }

    private static let lock = NSLock()
    private static var cache: [String: String] = [:]
    private static var biometricUnlocked = false

    public static var useBiometrics: Bool {
        get { UserDefaults.standard.object(forKey: "useBiometrics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "useBiometrics") }
    }

    public static func biometricsAvailable() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    private static func unlockBiometrics() -> Bool {
        guard useBiometrics, biometricsAvailable(), !biometricUnlocked else { return true }
        if ProcessInfo.processInfo.arguments.contains("--self-test") { return true }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var finished = false
        var success = false
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: L10n.t("Разблокировать сохранённые пароли")
        ) { ok, _ in
            success = ok
            finished = true
        }
        let deadline = Date().addingTimeInterval(60)
        while !finished && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if success { biometricUnlocked = true }
        return success
    }

    @discardableResult
    public static func set(_ secret: String, account: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        var updateQuery = query
        updateQuery[kSecUseAuthenticationContext as String] = quietContext()
        let update = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess {
            lock.lock(); cache[account] = secret; lock.unlock()
            return true
        }
        // An item written by another build cannot be updated; recreate it.
        SecItemDelete(query as CFDictionary)
        var add = query
        add.merge(attributes) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess {
            lock.lock(); cache[account] = secret; lock.unlock()
            return true
        }
        return false
    }

    public static func get(account: String) -> String? {
        lock.lock()
        if let cached = cache[account] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard has(account: account) else { return nil }
        guard unlockBiometrics() else { return nil }
        let result = getResult(account: account)
        guard let value = result.value, !value.isEmpty else { return nil }
        lock.lock(); cache[account] = value; lock.unlock()
        return value
    }

    public static func getResult(account: String) -> (value: String?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var quiet = query
        quiet[kSecUseAuthenticationContext as String] = quietContext()
        var item: CFTypeRef?
        let status = SecItemCopyMatching(quiet as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return (nil, status)
        }
        return (String(data: data, encoding: .utf8), status)
    }

    public static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        lock.lock(); cache.removeValue(forKey: account); lock.unlock()
    }

    public static func has(account: String) -> Bool {
        lock.lock()
        let cached = cache[account] != nil
        lock.unlock()
        if cached { return true }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var check = query
        check[kSecUseAuthenticationContext as String] = quietContext()
        var item: CFTypeRef?
        return SecItemCopyMatching(check as CFDictionary, &item) == errSecSuccess
    }

    public static func clearCache() {
        lock.lock()
        cache.removeAll()
        biometricUnlocked = false
        lock.unlock()
    }
}
