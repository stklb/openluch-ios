import Foundation
import UserNotifications

// Уведомления о работе фонового обновления — для отладки (решение владельца 2026-10-06).
//
// Зачем: фоновое обновление запускает iOS, когда сама сочтёт нужным, и увидеть это иначе нельзя.
// Если переключатель «Уведомлять о работе в фоне» в «Настройках» включён, после каждого
// пробуждения в Центре уведомлений появляется запись: что обновилось, или почему нет
// (всё свежее, нет сети, вход не выполнен, ошибка, iOS прервала задачу).
// Ни одной записи за ночь — значит, iOS ни разу не будила приложение.
//
// Это обычные «локальные» уведомления: их создаёт само приложение на телефоне,
// сервер Apple и платный аккаунт разработчика для них не нужны.
// Переключатель показывается только в отладочной сборке (запуск из Xcode), в App Store его нет.
nonisolated enum BackgroundRefreshNotifications {

    /// Ключ в UserDefaults: включены ли уведомления (по умолчанию — нет).
    static let enabledKey = "debug.backgroundRefreshNotifications"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        return defaults.bool(forKey: enabledKey)
    }

    /// Попросить у пользователя разрешение на уведомления (системное окно «Разрешить уведомления?»).
    /// Окно iOS показывает только один раз; дальше ответ меняют в Настройках iOS → «Уведомления».
    /// Возвращает true, если уведомления разрешены.
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = try? await center.requestAuthorization(options: [.alert, .sound])
        return granted ?? false
    }

    /// Показать запись в Центре уведомлений, если уведомления включены в «Настройках».
    /// У каждой записи своё имя (UUID), чтобы новые не заменяли старые: утром видна вся ночь.
    static func post(title: String, body: String, defaults: UserDefaults = .standard) {
        guard isEnabled(defaults: defaults) else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // trigger: nil — показать сразу.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        // Вариант с замыканием, а не async: он не зависит от отмены задачи — запись появится,
        // даже если iOS как раз прерывает фоновую задачу (кончилось время).
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
