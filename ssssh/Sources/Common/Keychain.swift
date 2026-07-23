import Foundation
import LocalAuthentication
import Security

/// Thin wrapper over Keychain Services for storing SSH private key material.
/// Items are stored `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, gated
/// behind Face ID/Touch ID (falling back to the device passcode) via
/// `kSecAttrAccessControl`, and are never synced to iCloud Keychain.
enum Keychain {
    enum KeychainError: LocalizedError {
        case unhandled(OSStatus)
        case itemNotFound
        case authenticationCanceled
        case interactionNotAllowed

        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                return (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
            case .itemNotFound:
                return "The key's private material could not be found in the Keychain."
            case .authenticationCanceled:
                return "Authentication was canceled."
            case .interactionNotAllowed:
                return "Couldn't show a Face ID/Touch ID prompt in this context. Open ssssh in the foreground once, then try again."
            }
        }
    }

    static func save(tag: String, data: Data) throws {
        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryCurrentSet, .or, .devicePasscode],
            &accessControlError
        ) else {
            throw KeychainError.unhandled(errSecParam)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: accessControl
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    /// Loads `tag`'s data, prompting for Face ID/Touch ID (or the device
    /// passcode) via `context` -- required because `save` protects the item
    /// with `kSecAttrAccessControl`. `reason` surfaces directly in that
    /// system prompt, so callers should pass something specific (e.g. which
    /// host this is for) rather than relying on the generic default --
    /// otherwise an unattended auto-reconnect's Face ID prompt gives the
    /// user no context for why it's appearing.
    static func load(tag: String, reason: String = "authenticate to use this SSH key", context: LAContext = LAContext()) throws -> Data {
        context.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound { throw KeychainError.itemNotFound }
            if status == errSecUserCanceled { throw KeychainError.authenticationCanceled }
            if status == errSecInteractionNotAllowed { throw KeychainError.interactionNotAllowed }
            throw KeychainError.unhandled(status)
        }
        return data
    }

    static func delete(tag: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}
