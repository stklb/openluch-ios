import BackgroundTasks
import Foundation

// Обновление кэша в фоне силами iOS (решение владельца 2026-10-03): списки объектов, точек
// и оборудования обновляются, даже когда приложение не запущено, — открыл, а данные уже свежие.
//
// Как это устроено в iOS (стандартный механизм BackgroundTasks, «Обновление контента»):
//   • приложение заранее просит «разбуди меня не раньше, чем такой-то момент» (schedule()):
//     когда первый список устареет по самому короткому из сроков в «Настройках» (CacheFreshness);
//   • КОГДА будить — решает сама iOS: учитывает, как часто человек открывает приложение, заряд,
//     сеть, режим энергосбережения. Обычно это раз в несколько часов, может быть реже;
//     приложение, смахнутое вверх в переключателе приложений, iOS не будит, пока его не откроют снова;
//   • проснувшись, смотрим текущую сеть и обновляем только списки, у которых истёк срок
//     для неё (при «Никогда» для сотовой сети по сотовой ничего не скачиваем) — те же правила,
//     что и при открытом приложении. Если обновлять нечего, сразу засыпаем;
//   • скачивает само приложение (обычный URLSession, как и при открытом приложении), а не iOS;
//   • на работу даётся около 30 секунд. Не успели — iOS прерывает задачу. Поэтому каждый список
//     сохраняется сразу, как только скачан: прерывание не теряет уже скачанное;
//   • пользователь может выключить это в «Настройках» iOS → «Основные» → «Обновление контента».
//
// Для отладки (2026-10-06): чем закончилось каждое пробуждение, записывается в UserDefaults
// (видно в «Настройках») и, если включено, приходит уведомлением (BackgroundRefreshNotifications).
//
// Настройки проекта для этого (OpenLuch/Info.plist):
//   UIBackgroundModes = [fetch] и BGTaskSchedulerPermittedIdentifiers = [ru.stklb.luch.refresh].
// Сама задача подключена в OpenLuchApp (.backgroundTask(.appRefresh(...))).
nonisolated enum BackgroundRefresh {

    /// Имя фоновой задачи — то же, что в Info.plist (BGTaskSchedulerPermittedIdentifiers).
    static let taskIdentifier = "ru.stklb.luch.refresh"

    // Ключи в UserDefaults: когда и чем закончилось последнее фоновое обновление (для «Настроек»).
    private static let lastRunKey = "background.lastRunAt"
    private static let lastSavedKey = "background.lastSavedAt"
    private static let lastErrorKey = "background.lastError"
    /// Чем закончилось последнее пробуждение — одной строкой («Обновлены: точки, за 4 с»).
    private static let lastReportKey = "background.lastReport"
    /// На какое время iOS приняла последнюю просьбу разбудить.
    private static let nextWakeKey = "background.nextWakeAt"
    /// Почему iOS не приняла последнюю просьбу разбудить (nil — приняла).
    private static let scheduleErrorKey = "background.scheduleError"

    // MARK: - Запрос к iOS

    /// Попросить iOS разбудить приложение для обновления — не раньше, чем какой-то список
    /// может устареть (CacheFreshness.nextWakeDate). Вызывается, когда приложение уходит в фон,
    /// и при каждом фоновом обновлении. Новая просьба заменяет прежнюю.
    /// Если iOS просьбу не приняла — причина сохраняется и видна в «Настройках» (scheduleError).
    static func schedule(cacheStore: CacheStore, defaults: UserDefaults = .standard) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        let wakeAt = CacheFreshness.nextWakeDate(
            listsUpdatedAt: cacheStore.listFilesModifiedAt(),
            wifiLifetime: CacheFreshness.lifetime(for: .wifi, defaults: defaults),
            cellularLifetime: CacheFreshness.lifetime(for: .cellular, defaults: defaults),
            now: Date())
        request.earliestBeginDate = wakeAt
        do {
            try BGTaskScheduler.shared.submit(request)
            defaults.set(wakeAt, forKey: nextWakeKey)
            defaults.removeObject(forKey: scheduleErrorKey)
        } catch {
            #if targetEnvironment(simulator)
            // На симуляторе фоновые задачи не работают вовсе — это не ошибка, пропускаем.
            return
            #else
            defaults.removeObject(forKey: nextWakeKey)
            defaults.set(scheduleErrorText(error), forKey: scheduleErrorKey)
            #endif
        }
    }

    /// Понятное объяснение, почему iOS не приняла просьбу разбудить приложение.
    private static func scheduleErrorText(_ error: Error) -> String {
        guard let schedulerError = error as? BGTaskScheduler.Error else {
            return error.localizedDescription
        }
        switch schedulerError.code {
        case .unavailable:
            return "iOS не разрешает обновление в фоне (выключено «Обновление контента» или режим энергосбережения)"
        case .notPermitted:
            return "фоновая задача не разрешена в Info.plist"
        case .tooManyPendingTaskRequests:
            return "слишком много запросов фоновых задач"
        default:
            return "ошибка BGTaskScheduler \(schedulerError.code.rawValue)"
        }
    }

    // MARK: - Само обновление

    /// Чем закончилось одно пробуждение — для «Настроек» и уведомления.
    private struct RunReport {
        /// Коротко: «Обновлено», «Ошибка», «Ничего не обновлено».
        let title: String
        /// Подробно: что обновилось или почему нет.
        let details: String
    }

    /// Вызывает iOS через .backgroundTask в OpenLuchApp: обновить устаревшие списки
    /// и записать (и, если включено, прислать уведомлением), чем всё закончилось.
    /// connection — только для тестов; обычно тип подключения берётся у NetworkMonitor.
    @MainActor
    static func run(session: AppSession, defaults: UserDefaults = .standard,
                    connection: ConnectionKind? = nil) async {
        let startedAt = Date()
        defaults.set(startedAt, forKey: lastRunKey)
        // Сразу просим разбудить и в следующий раз — на случай, если iOS прервёт задачу жёстко.
        schedule(cacheStore: session.cacheStore, defaults: defaults)

        let report = await refreshStaleLists(session: session, defaults: defaults, connection: connection)

        // Ещё раз — уже с учётом того, что успели обновить.
        schedule(cacheStore: session.cacheStore, defaults: defaults)

        let seconds = Int(Date().timeIntervalSince(startedAt).rounded())
        var details = "\(report.details) За \(seconds) с."
        if let nextWakeAt = nextWakeAt(defaults: defaults) {
            details += " Следующее — не раньше \(TextFormatting.updatedAt(nextWakeAt))."
        } else if let scheduleError = scheduleError(defaults: defaults) {
            details += " Следующее iOS не приняла: \(scheduleError)."
        }
        defaults.set("\(report.title). \(details)", forKey: lastReportKey)
        BackgroundRefreshNotifications.post(title: "Обновление в фоне: \(report.title.lowercased())",
                                            body: details, defaults: defaults)
    }

    /// Обновить устаревшие списки: объекты (с группами), точки, оборудование — по очереди, каждый сразу в кэш.
    /// Если iOS прервёт задачу, уже сохранённое останется.
    @MainActor
    private static func refreshStaleLists(session: AppSession, defaults: UserDefaults,
                                          connection: ConnectionKind?) async -> RunReport {
        guard let client = session.makeAPIClient(), let token = session.token else {
            return RunReport(title: "Ничего не обновлено", details: "Вход не выполнен.")
        }

        // Что устарело для текущей сети. lastAttemptAt не учитываем: как часто будить, решает
        // schedule(), а iOS и так будит не чаще раза в 15 минут.
        let currentConnection: ConnectionKind
        if let connection {
            currentConnection = connection
        } else {
            currentConnection = await NetworkMonitor.shared.connectionKindWhenKnown()
        }
        let lifetime = CacheFreshness.lifetime(for: currentConnection, defaults: defaults)
        if currentConnection == .noNetwork {
            return RunReport(title: "Ничего не обновлено", details: "Нет сети.")
        }
        if lifetime == nil {
            return RunReport(title: "Ничего не обновлено",
                             details: "\(currentConnection.title): автообновление выключено («Никогда»).")
        }
        let updatedAt = session.cacheStore.listFilesModifiedAt()
        let now = Date()
        let kinds = [ListKind.nodes, ListKind.measurePoints, ListKind.equipment]
        let staleKinds = kinds.indices.filter { index in
            CacheFreshness.shouldRefresh(connection: currentConnection, lifetime: lifetime,
                                         updatedAt: updatedAt[index], lastAttemptAt: nil, now: now)
        }.map { kinds[$0] }
        if staleKinds.isEmpty {
            return RunReport(title: "Ничего не обновлено",
                             details: "\(currentConnection.title): списки ещё свежие.")
        }

        let previousGroups = await session.cacheStore.loadNodes()?.groups ?? []
        var savedKinds: [ListKind] = []
        for kind in staleKinds {
            do {
                let result = try await ListRefresher.downloadAndSave(kind, client: client, token: token,
                                                                     cacheStore: session.cacheStore,
                                                                     previousGroups: previousGroups)
                // Вместе с объектами пришли имя и права пользователя — сохраняем.
                if case .nodes(_, _, let currentUser?, _, _) = result {
                    session.updateCurrentUser(currentUser)
                }
                savedKinds.append(kind)
                defaults.set(Date(), forKey: lastSavedKey)
                defaults.removeObject(forKey: lastErrorKey)
            } catch {
                let apiError = APIError.from(error)
                let saved = savedText(savedKinds)
                if apiError == .cancelled {
                    // iOS прервала задачу (кончилось время) — остальное в следующий раз.
                    return RunReport(title: "Прервано iOS",
                                     details: "\(currentConnection.title): кончилось время на \(listTitle(kind)). \(saved)")
                }
                if case .unauthorized = apiError {
                    // Токен больше не действует: при открытии приложения будет экран входа (кэш сохранится).
                    session.sessionExpired()
                    return RunReport(title: "Ошибка", details: "Сессия истекла, нужно войти заново. \(saved)")
                }
                let message = apiError.errorDescription ?? "неизвестная ошибка"
                defaults.set(message, forKey: lastErrorKey)
                return RunReport(title: "Ошибка",
                                 details: "\(currentConnection.title), \(listTitle(kind)): \(message) \(saved)")
            }
        }
        return RunReport(title: "Обновлено", details: "\(currentConnection.title). \(savedText(savedKinds))")
    }

    /// «Обновлены: объекты, точки.» или «Ничего не сохранено.»
    private static func savedText(_ kinds: [ListKind]) -> String {
        if kinds.isEmpty {
            return "Ничего не сохранено."
        }
        return "Обновлены: " + kinds.map(listTitle).joined(separator: ", ") + "."
    }

    /// Название списка для сообщений.
    private static func listTitle(_ kind: ListKind) -> String {
        switch kind {
        case .nodes:
            return "объекты"
        case .measurePoints:
            return "точки"
        case .equipment:
            return "оборудование"
        }
    }

    // MARK: - Сведения для «Настроек»

    /// Когда последний раз в фоне удалось сохранить хотя бы один список.
    static func lastSuccessAt(defaults: UserDefaults = .standard) -> Date? {
        return defaults.object(forKey: lastSavedKey) as? Date
    }

    /// Когда iOS последний раз запускала фоновое обновление.
    static func lastRunAt(defaults: UserDefaults = .standard) -> Date? {
        return defaults.object(forKey: lastRunKey) as? Date
    }

    /// Ошибка последнего фонового обновления (nil — ошибки не было).
    static func lastError(defaults: UserDefaults = .standard) -> String? {
        return defaults.string(forKey: lastErrorKey)
    }

    /// Чем закончилось последнее пробуждение (nil — iOS ещё ни разу не будила).
    static func lastReport(defaults: UserDefaults = .standard) -> String? {
        return defaults.string(forKey: lastReportKey)
    }

    /// Не раньше какого момента iOS обещала разбудить (nil — просьбы нет или iOS её не приняла).
    static func nextWakeAt(defaults: UserDefaults = .standard) -> Date? {
        return defaults.object(forKey: nextWakeKey) as? Date
    }

    /// Почему iOS не приняла просьбу разбудить (nil — приняла).
    static func scheduleError(defaults: UserDefaults = .standard) -> String? {
        return defaults.string(forKey: scheduleErrorKey)
    }
}
