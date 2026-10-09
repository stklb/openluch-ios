import Foundation
import Security

// Хранение токена входа в Keychain — защищённом хранилище iOS для паролей и ключей.
// Данные там зашифрованы, и другие приложения их прочитать не могут.
//
// Храним ТОЛЬКО токен; пароль на телефоне не сохраняется (решение владельца, см. PLAN.md).
//
// Особенность iOS: записи Keychain остаются даже после удаления приложения.
// Поэтому вход считается выполненным, только если есть И токен, И сохранённый адрес сервера
// (адрес хранится в UserDefaults и удаляется вместе с приложением), — см. AppSession.
nonisolated struct KeychainTokenStore: Sendable {
    /// Имя «раздела» в Keychain. В тестах подменяется, чтобы не трогать настоящий токен.
    let service: String
    private let account = "token"

    init(service: String = "ru.stklb.luch.token") {
        self.service = service
    }

    /// Сохраняет токен (старый, если был, заменяется).
    func save(_ token: String) throws {
        try delete()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            // Доступен после первой разблокировки телефона и только на этом устройстве
            // (не переносится на другой телефон через резервную копию).
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    /// Возвращает сохранённый токен или nil, если его нет.
    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Удаляет токен. Если его не было — это не ошибка.
    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError(status: status)
        }
    }
}

/// Ошибка Keychain. `status` — системный код ошибки (OSStatus).
nonisolated struct KeychainError: LocalizedError, Sendable {
    let status: OSStatus

    var errorDescription: String? {
        return "Не удалось сохранить данные входа на устройстве (код Keychain \(status))."
    }
}
