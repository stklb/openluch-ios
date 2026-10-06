import Foundation

// Несекретные настройки: адрес сервера, логин, имя и права вошедшего пользователя.
// Хранятся в UserDefaults — стандартном хранилище настроек приложения.
// Остаются после выхода из учётной записи, чтобы не вводить их заново (решение владельца).
nonisolated struct SettingsStore: @unchecked Sendable {
    // @unchecked Sendable: UserDefaults можно безопасно использовать из разных потоков
    // (так сказано в документации Apple), но компилятор об этом не знает.
    private let defaults: UserDefaults

    private let serverAddressKey = "serverAddress"
    private let loginKey = "login"
    private let currentUserKey = "currentUser"

    /// `defaults` можно подменить в тестах, чтобы не трогать настоящие настройки.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadServerAddress() -> ServerAddress? {
        guard let data = defaults.data(forKey: serverAddressKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ServerAddress.self, from: data)
    }

    func saveServerAddress(_ address: ServerAddress) {
        if let data = try? JSONEncoder().encode(address) {
            defaults.set(data, forKey: serverAddressKey)
        }
    }

    func loadLogin() -> String {
        return defaults.string(forKey: loginKey) ?? ""
    }

    func saveLogin(_ login: String) {
        defaults.set(login, forKey: loginKey)
    }

    /// Имя и права вошедшего пользователя (CurrentUser). nil — ещё не получены.
    func loadCurrentUser() -> CurrentUser? {
        guard let data = defaults.data(forKey: currentUserKey) else {
            return nil
        }
        return try? JSONDecoder().decode(CurrentUser.self, from: data)
    }

    /// nil — стереть (например, при новом входе: это может быть другой пользователь).
    func saveCurrentUser(_ user: CurrentUser?) {
        if let user, let data = try? JSONEncoder().encode(user) {
            defaults.set(data, forKey: currentUserKey)
        } else {
            defaults.removeObject(forKey: currentUserKey)
        }
    }
}
