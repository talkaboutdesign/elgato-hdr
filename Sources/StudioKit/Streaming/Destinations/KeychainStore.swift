// Stream keys as Keychain generic passwords: service `dev.max.elgato-hdr.stream-key`, account = destination id.
// Keys are read only at the moment a stream (or a connection test) starts, never kept in observable UI state, never
// logged. Calls can block while macOS asks the user to allow access, so callers run them off the main thread.
import Foundation
import Security

/// Where stream keys are kept: the Keychain in the app, memory in tests that must not depend on a usable keychain.
protocol StreamKeyStore {
    func set(_ key: String, for account: String) throws
    func get(_ account: String) throws -> String?
    func delete(_ account: String) throws
    func contains(_ account: String) -> Bool
}

struct KeychainStore: StreamKeyStore {
    static let streamKeyService = "dev.max.elgato-hdr.stream-key"

    enum Failure: Error, Equatable {
        /// The item exists but this build may not read it: an ad-hoc signed rebuild, a denied or unanswerable
        /// prompt, or a locked keychain. The fix is to enter the key again.
        case accessDenied
        case unexpected(OSStatus)

        var message: String {
            switch self {
            case .accessDenied: return "The Keychain did not allow access to the stream key. Enter the key again."
            case .unexpected(let s): return "Keychain error \(s)."
            }
        }
    }

    let service: String
    init(service: String = KeychainStore.streamKeyService) { self.service = service }

    private func base(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }
    private static func failure(_ status: OSStatus) -> Failure {
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecNoAccessForItem: return .accessDenied
        default: return .unexpected(status)
        }
    }

    func set(_ key: String, for account: String) throws {
        let data = Data(key.utf8)
        var add = base(account)
        add[kSecValueData] = data
        add[kSecAttrLabel] = "\(AppInfo.name) stream key"
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData: data] as CFDictionary)
            // An item this build may not update (written by an older ad-hoc signature): replace it.
            if status != errSecSuccess, (try? delete(account)) != nil { status = SecItemAdd(add as CFDictionary, nil) }
        }
        guard status == errSecSuccess else { throw Self.failure(status) }
    }

    func get(_ account: String) throws -> String? {
        var query = base(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw Self.failure(status) }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
    }

    func contains(_ account: String) -> Bool {
        var query = base(account)
        query[kSecReturnAttributes] = true
        // Attributes need no access to the secret, so this never prompts.
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
