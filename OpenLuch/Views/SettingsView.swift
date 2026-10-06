import SwiftUI

// «Настройки» — открываются поверх списка (sheet) кнопкой ⚙︎ слева вверху (settingsButton()):
// сервер и выход, кэш объектов, точек и оборудования
// (сведения, «Обновить», «Очистить кэш»), сохранённые PDF-отчёты,
// автообновление справочников (сроки по Wi-Fi и по сотовой сети, фоновое обновление) и сведения о приложении.
struct SettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(DataStore.self) private var dataStore

    @State private var isLogoutConfirmationShown = false
    @State private var isClearCacheConfirmationShown = false
    @State private var isDeleteReportsConfirmationShown = false
    /// Срок годности кэша списков, в минутах (0 — «Никогда»); правила — в CacheFreshness.
    @AppStorage(CacheFreshness.wifiKey) private var wifiLifetimeMinutes = CacheFreshness.defaultWifiMinutes
    @AppStorage(CacheFreshness.cellularKey) private var cellularLifetimeMinutes = CacheFreshness.defaultCellularMinutes
    /// Разрешено ли обновление в фоне в Настройках iOS и включён ли режим энергосбережения.
    @State private var backgroundRefreshStatus = UIBackgroundRefreshStatus.available
    @State private var isLowPowerModeEnabled = false
    /// Отладка: присылать уведомление после каждого пробуждения в фоне (BackgroundRefreshNotifications).
    @AppStorage(BackgroundRefreshNotifications.enabledKey) private var isBackgroundNotificationsEnabled = false
    /// Уведомления запрещены в Настройках iOS — показать подсказку под переключателем.
    @State private var isNotificationPermissionDenied = false
    @Environment(\.scenePhase) private var scenePhase
    /// Сохранённые PDF-отчёты (читаются при открытии вкладки).
    @State private var savedReports: [SavedReport] = []
    /// Закрыть окно настроек.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                cacheSection
                autoRefreshSection
                reportsSection
                aboutSection
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Стандартная кнопка закрытия окна справа вверху (как в окнах настроек приложений Apple).
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        dismiss()
                    }
                }
            }
        }
        // При каждом открытии вкладки — актуальный размер кэша.
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                readBackgroundRefreshStatus()
            }
        }
        .task {
            readBackgroundRefreshStatus()
            await dataStore.refreshCacheSize()
            savedReports = await session.reportStore.loadAll()
        }
    }

    // MARK: - Сервер

    private var serverSection: some View {
        Section("Сервер") {
            // Строка с адресом — она же ссылка на экран «О сервере» (стрелка › справа).
            NavigationLink {
                ServerInfoView()
            } label: {
                LabeledContent("Адрес", value: session.serverAddress?.displayText ?? "—")
            }
            // Имя и логин — одной строкой, значения справа в две строки мелким шрифтом
            // (решение владельца 2026-10-06: окно настроек компактнее).
            LabeledContent("Пользователь") {
                VStack(alignment: .trailing, spacing: 2) {
                    if let displayName = session.displayName {
                        Text(displayName)
                    }
                    Text(session.savedLogin)
                }
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
            }
            Button("Выйти", role: .destructive) {
                isLogoutConfirmationShown = true
            }
            .confirmationDialog("Выйти из учётной записи?",
                                isPresented: $isLogoutConfirmationShown,
                                titleVisibility: .visible) {
                Button("Выйти", role: .destructive) {
                    Task {
                        // Сначала останавливаем загрузки, потом выходим (выход стирает кэш).
                        await dataStore.stop()
                        await session.logOut()
                    }
                }
            } message: {
                Text("Сохранённые на устройстве списки будут удалены. Адрес сервера и логин останутся.")
            }
        }
    }

    // MARK: - Кэш

    /// Кэш одной строкой: размер, сколько чего сохранено и когда обновлено; под ней — «Очистить кэш».
    /// Кнопки «Обновить» нет (решение владельца 2026-10-06): списки обновляются сами по срокам
    /// из «Автообновления»; загрузить всё заново можно через «Очистить кэш».
    private var cacheSection: some View {
        Section {
            cacheSummaryRow

            Button("Очистить кэш", role: .destructive) {
                isClearCacheConfirmationShown = true
            }
            .disabled(dataStore.cacheSizeBytes == 0 && dataStore.nodes.isEmpty && dataStore.measurePoints.isEmpty
                      && dataStore.equipment.isEmpty)
            .confirmationDialog("Очистить кэш?",
                                isPresented: $isClearCacheConfirmationShown,
                                titleVisibility: .visible) {
                Button("Очистить", role: .destructive) {
                    Task {
                        await dataStore.clearCache()
                    }
                }
            } message: {
                Text("Сохранённые списки будут удалены с устройства и загружены заново: по Wi-Fi — сразу, по сотовой сети — при открытии вкладки. Без интернета списков не будет, пока они не загрузятся.")
            }
        } header: {
            Text("Кэш")
        } footer: {
            Text("Объекты, точки и оборудование хранятся на устройстве и открываются без интернета.")
        }
    }

    /// «Сохранено  42 КБ» / «1 объект · 5 точек · 64 ед. оборудования» / «Обновлено сегодня в 03:38»;
    /// ниже — ход загрузки или ошибка, если список сейчас обновляется или не обновился.
    private var cacheSummaryRow: some View {
        let kinds: [ListKind] = [.nodes, .measurePoints, .equipment]

        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Сохранено", value: TextFormatting.bytes(dataStore.cacheSizeBytes))
            Group {
                Text(cachedCountsText)
                Text(cacheUpdatedText)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            ForEach(kinds, id: \.self) { kind in
                cacheStateLine(for: kind)
            }
        }
    }

    /// «1 объект · 5 точек · 64 ед. оборудования»; ещё не загруженный список — «точки — нет».
    private var cachedCountsText: String {
        let nodes = dataStore.updatedAt(for: .nodes) == nil
            ? "объекты — нет" : TextFormatting.nodesCount(dataStore.itemCount(for: .nodes))
        let points = dataStore.updatedAt(for: .measurePoints) == nil
            ? "точки — нет" : TextFormatting.pointsShortCount(dataStore.itemCount(for: .measurePoints))
        let equipment = dataStore.updatedAt(for: .equipment) == nil
            ? "оборудование — нет" : "\(dataStore.itemCount(for: .equipment)) ед. оборудования"
        return "\(nodes) · \(points) · \(equipment)"
    }

    /// Когда обновлено. Если списки обновлялись в разное время — самое раннее (честно о самом старом).
    private var cacheUpdatedText: String {
        let dates = [ListKind.nodes, .measurePoints, .equipment].compactMap { dataStore.updatedAt(for: $0) }
        guard let oldest = dates.min() else {
            return "Ещё не загружались"
        }
        return "Обновлено \(TextFormatting.updatedAt(oldest))"
    }

    /// Ход загрузки списка или ошибка последнего обновления (в обычном состоянии — ничего).
    @ViewBuilder
    private func cacheStateLine(for kind: ListKind) -> some View {
        switch dataStore.state(for: kind) {
        case .idle:
            EmptyView()
        case .queued:
            Text("\(kind.cacheTitle): ждёт очереди…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .loading(let progress):
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.cacheTitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                DownloadProgressView(progress: progress)
            }
        case .failed(let message):
            Label("\(kind.cacheTitle): не удалось обновить: \(message)",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Отчёты

    private var reportsSection: some View {
        let totalBytes = savedReports.reduce(Int64(0)) { $0 + Int64($1.sizeBytes) }

        return Section {
            // Количество и размер — одной строкой.
            LabeledContent("Сохранено",
                           value: savedReports.isEmpty
                               ? "нет"
                               : "\(TextFormatting.reportsCount(savedReports.count)) · \(TextFormatting.bytes(totalBytes))")
            Button("Удалить все отчёты", role: .destructive) {
                isDeleteReportsConfirmationShown = true
            }
            .disabled(savedReports.isEmpty)
            .confirmationDialog("Удалить все отчёты?",
                                isPresented: $isDeleteReportsConfirmationShown,
                                titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    Task {
                        try? await session.reportStore.deleteAll()
                        savedReports = await session.reportStore.loadAll()
                    }
                }
            } message: {
                Text("Сохранённые PDF-отчёты будут удалены с устройства. Копии, сохранённые в других папках или отправленные, останутся.")
            }
        } header: {
            Text("Отчёты")
        }
    }

    // MARK: - Автообновление

    private var autoRefreshSection: some View {
        Section {
            Picker("По Wi-Fi", selection: $wifiLifetimeMinutes) {
                ForEach(CacheFreshness.wifiOptions, id: \.self) { minutes in
                    Text(CacheFreshness.title(minutes: minutes)).tag(minutes)
                }
            }
            Picker("По сотовой сети", selection: $cellularLifetimeMinutes) {
                ForEach(CacheFreshness.cellularOptions, id: \.self) { minutes in
                    Text(CacheFreshness.title(minutes: minutes)).tag(minutes)
                }
            }
            lastBackgroundRefreshRows
        } header: {
            Text("Автообновление справочников")
        } footer: {
            backgroundRefreshStatusText
        }
        // Поменяли срок — сразу проверяем, не устарело ли что-то (и заново просим iOS разбудить вовремя).
        .onChange(of: wifiLifetimeMinutes) {
            dataStore.autoRefreshIfNeeded()
            BackgroundRefresh.schedule(cacheStore: session.cacheStore)
        }
        .onChange(of: cellularLifetimeMinutes) {
            dataStore.autoRefreshIfNeeded()
            BackgroundRefresh.schedule(cacheStore: session.cacheStore)
        }
    }

    /// Разрешено ли обновление в фоне в Настройках iOS — строка мелким шрифтом в пояснении.
    /// Если не разрешено — оранжевым. Ссылки в тексте ведут на страницу приложения в Настройках iOS:
    /// «app-settings:» — стандартный адрес (UIApplication.openSettingsURLString); открыть сразу
    /// общий пункт «Основные» → «Обновление контента» iOS приложениям не позволяет.
    @ViewBuilder
    private var backgroundRefreshStatusText: some View {
        if isLowPowerModeEnabled {
            // В режиме энергосбережения iOS не будит приложения в фоне, даже если обновление разрешено.
            Text("В режиме энергосбережения обновления в фоне нет.")
                .foregroundStyle(.orange)
        } else {
            switch backgroundRefreshStatus {
            case .available:
                Text("Обновление в фоне включено ([изменить](app-settings:)).")
            case .denied:
                Text("Обновление в фоне выключено. [Включить](app-settings:)")
                    .foregroundStyle(.orange)
            default:
                // .restricted — запрещено не пользователем, а ограничениями устройства (например, «Экранным временем»).
                Text("Обновление в фоне запрещено ограничениями устройства.")
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Когда последний раз списки обновились в фоне и не было ли ошибки.
    @ViewBuilder
    private var lastBackgroundRefreshRows: some View {
        LabeledContent("Последнее в фоне") {
            if let lastAt = BackgroundRefresh.lastSuccessAt() {
                Text(TextFormatting.updatedAt(lastAt))
            } else {
                Text("ещё не было")
            }
        }
        if let error = BackgroundRefresh.lastError() {
            Label("Последняя попытка не удалась: \(error)", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        // iOS не приняла просьбу разбудить приложение — тогда в фоне ничего не будет.
        if let scheduleError = BackgroundRefresh.scheduleError() {
            Label("iOS не приняла запрос обновления в фоне: \(scheduleError)",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        #if DEBUG
        backgroundRefreshDebugRows
        #endif
    }

    #if DEBUG
    /// Отладка фонового обновления (только в сборке из Xcode, в App Store этих строк нет):
    /// чем закончилось последнее пробуждение, когда следующее и переключатель уведомлений.
    @ViewBuilder
    private var backgroundRefreshDebugRows: some View {
        LabeledContent("Следующее — не раньше") {
            if let nextWakeAt = BackgroundRefresh.nextWakeAt() {
                Text(TextFormatting.updatedAt(nextWakeAt))
            } else {
                Text("не запрошено")
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            if let lastRunAt = BackgroundRefresh.lastRunAt() {
                Text("Последний запуск iOS: \(TextFormatting.updatedAt(lastRunAt))")
                Text(BackgroundRefresh.lastReport() ?? "")
                    .foregroundStyle(.secondary)
            } else {
                Text("iOS ещё ни разу не запускала обновление в фоне")
            }
        }
        .font(.footnote)
        Toggle("Уведомлять о работе в фоне", isOn: $isBackgroundNotificationsEnabled)
            .onChange(of: isBackgroundNotificationsEnabled) {
                guard isBackgroundNotificationsEnabled else {
                    return
                }
                // Включили — спрашиваем разрешение (системное окно появится только в первый раз).
                Task {
                    let isGranted = await BackgroundRefreshNotifications.requestPermission()
                    isNotificationPermissionDenied = !isGranted
                    if !isGranted {
                        isBackgroundNotificationsEnabled = false
                    }
                }
            }
        if isNotificationPermissionDenied {
            Text("Уведомления запрещены. [Разрешить](app-settings:) в Настройках iOS.")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }
    #endif

    /// Перечитать, разрешено ли обновление в фоне, — при открытии вкладки и при возвращении
    /// в приложение (например, из Настроек iOS или после Пункта управления с энергосбережением).
    private func readBackgroundRefreshStatus() {
        backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    // MARK: - О приложении

    private var aboutSection: some View {
        Section {
            // Ссылки поддержки и политики конфиденциальности: App Store требует их в карточке приложения,
            // а проверяющие Apple любят видеть их и в самом приложении. Link открывает почту / Safari.
            Link(destination: URL(string: "mailto:support@stklb.ru")!) {
                LabeledContent("Поддержка", value: "support@stklb.ru")
            }
            Link("Политика конфиденциальности",
                 destination: URL(string: "https://stklb.ru/openluch/privacy/")!)
        } header: {
            Text("О приложении")
        } footer: {
            // Версия — в пояснении, а не отдельной строкой (окно настроек компактнее).
            Text("OpenLuch \(appVersion). Неофициальный клиент для системы ЛЭРС УЧЁТ. Не связан с разработчиком системы.")
        }
    }

    /// «1.0 (1)» — версия и номер сборки из настроек проекта.
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}
