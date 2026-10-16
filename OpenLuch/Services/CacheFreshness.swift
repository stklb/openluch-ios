import Foundation

// Срок годности кэша списков (объекты, точки, оборудование) — решение владельца 2026-10-04.
//
// В «Настройках» два пункта: сколько живёт кэш при работе по Wi-Fi и по сотовой сети.
// Каждый список обновляется сам, когда его срок истёк с учётом ТЕКУЩЕГО подключения:
//   • пока приложение открыто — проверка раз в 15 секунд (DataStore);
//   • в фоне — когда iOS разбудит приложение (BackgroundRefresh): обновляем только устаревшее,
//     а будить просим не раньше, чем первый список может устареть.
// Кнопка «Обновить» в «Настройках» работает всегда, независимо от сроков.
//
// Те же сроки — у тяжёлых данных одной точки: датчиков (~365 КБ) и списка отчётов (~450 КБ)
// (решение владельца 2026-10-16). Но это не автообновление, а срок годности: проверяется ТОЛЬКО когда
// пользователь открыл вкладку «Датчики» или окно «Отчёт» этой точки (isStaleOnOpen). Ни в фоне, ни
// вместе со списками они не скачиваются — BackgroundRefresh и DataStore обновляют только три списка.
nonisolated enum CacheFreshness {

    // MARK: - Настройки

    /// Ключи в UserDefaults (их же использует @AppStorage в «Настройках»). Значение — минуты, 0 — «Никогда».
    static let wifiKey = "cache.wifiLifetimeMinutes"
    static let cellularKey = "cache.cellularLifetimeMinutes"

    /// По умолчанию: Wi-Fi — 1 час (как было раньше), сотовая сеть — 12 часов.
    static let defaultWifiMinutes = 60
    static let defaultCellularMinutes = 12 * 60

    /// «Никогда не обновлять автоматически» (только для сотовой сети).
    static let never = 0

    /// Варианты выбора в «Настройках».
    static let wifiOptions = [15, 30, 60, 3 * 60, 6 * 60, 12 * 60, 24 * 60]
    static let cellularOptions = [60, 3 * 60, 6 * 60, 12 * 60, 24 * 60, 36 * 60, never]

    /// Подпись варианта: «Раз в 15 минут», «Раз в 3 часа», «Никогда».
    static func title(minutes: Int) -> String {
        switch minutes {
        case never:
            return "Никогда"
        case 15:
            return "Раз в 15 минут"
        case 30:
            return "Раз в 30 минут"
        case 60:
            return "Раз в час"
        case 3 * 60:
            return "Раз в 3 часа"
        case 6 * 60:
            return "Раз в 6 часов"
        case 12 * 60:
            return "Раз в 12 часов"
        case 24 * 60:
            return "Раз в сутки"
        case 36 * 60:
            return "Раз в 36 часов"
        default:
            return "Раз в \(minutes) мин"
        }
    }

    /// Срок годности кэша для подключения. nil — автоматически не обновляем
    /// (сети нет или для сотовой сети выбрано «Никогда»).
    static func lifetime(for connection: ConnectionKind, defaults: UserDefaults = .standard) -> TimeInterval? {
        let minutes: Int
        switch connection {
        case .noNetwork:
            return nil
        case .wifi:
            minutes = defaults.object(forKey: wifiKey) as? Int ?? defaultWifiMinutes
        case .cellular:
            minutes = defaults.object(forKey: cellularKey) as? Int ?? defaultCellularMinutes
        }
        if minutes <= never {
            return nil
        }
        return TimeInterval(minutes * 60)
    }

    // MARK: - Правило обновления

    /// После неудачной попытки — не повторять чаще, чем раз в срок годности, но и не реже раза в час
    /// (при сроке 12 часов повтор через час, а не через 12).
    static let maximumRetryDelay: TimeInterval = 60 * 60

    /// Пора ли обновить один список.
    /// - lifetime: срок годности для текущего подключения (nil — не обновляем автоматически);
    /// - updatedAt: когда список последний раз сохранён (nil — ещё ни разу);
    /// - lastAttemptAt: когда последний раз пробовали загрузить (удачно или нет).
    static func shouldRefresh(connection: ConnectionKind, lifetime: TimeInterval?, updatedAt: Date?,
                              lastAttemptAt: Date?, now: Date) -> Bool {
        guard let lifetime else {
            return false
        }
        // Недавно уже пробовали (удачно или нет) — ждём.
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < min(lifetime, maximumRetryDelay) {
            return false
        }
        guard let updatedAt else {
            // Списка ещё нет. По Wi-Fi — загружаем; по сотовой сети — нет: там первым загружается
            // только список открытой вкладки (DataStore.listDidAppear), чтобы не тратить связь на всё сразу.
            return connection == .wifi
        }
        return now.timeIntervalSince(updatedAt) >= lifetime
    }

    /// Пора ли перекачать данные, которые загружаются при открытии экрана (датчики, список отчётов точки).
    /// - savedAt: когда сохранены (nil — ещё ни разу: загружаем при любой сети, иначе экрану нечего показать);
    /// - lifetime: срок для текущего подключения (`lifetime(for:)`; nil — «Никогда» или нет сети: показываем сохранённое).
    static func isStaleOnOpen(savedAt: Date?, lifetime: TimeInterval?, now: Date) -> Bool {
        guard let savedAt else {
            return true
        }
        guard let lifetime else {
            return false
        }
        return now.timeIntervalSince(savedAt) >= lifetime
    }

    // MARK: - Когда будить в фоне

    /// iOS всё равно не будит чаще, чем примерно раз в 15 минут.
    static let minimumWakeDelay: TimeInterval = 15 * 60

    /// Когда просить iOS разбудить приложение: в момент, когда первый список устареет
    /// по самому короткому из сроков (мы заранее не знаем, какая сеть будет при пробуждении).
    /// Например, Wi-Fi 6 часов, сотовая 24 часа, списки обновлены в 10:00 → будить не раньше 16:00.
    static func nextWakeDate(listsUpdatedAt: [Date?], wifiLifetime: TimeInterval?,
                             cellularLifetime: TimeInterval?, now: Date) -> Date {
        let earliest = now.addingTimeInterval(minimumWakeDelay)
        guard let shortest = [wifiLifetime, cellularLifetime].compactMap({ $0 }).min() else {
            // Автообновление выключено для всех сетей — будим изредка, раз в сутки.
            return now.addingTimeInterval(24 * 60 * 60)
        }
        var wake = now.addingTimeInterval(shortest)
        for updatedAt in listsUpdatedAt {
            // Списка нет — он «устарел» уже сейчас.
            let expiresAt = updatedAt?.addingTimeInterval(shortest) ?? now
            wake = min(wake, expiresAt)
        }
        return max(wake, earliest)
    }
}
