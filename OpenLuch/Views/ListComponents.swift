import SwiftUI

// Общие элементы для экранов «Объекты», «Точки», «Оборудование» и «Настройки»:
// цвет состояния, строка «Обновлено…» над списком, ход загрузки и пустой экран.

// MARK: - Подписи списков

extension ListKind {
    /// «128 объектов», «5 точек учёта», «64 единицы оборудования».
    func countText(_ count: Int) -> String {
        switch self {
        case .nodes:
            return TextFormatting.nodesCount(count)
        case .measurePoints:
            return TextFormatting.measurePointsCount(count)
        case .equipment:
            return TextFormatting.equipmentCount(count)
        }
    }

    /// Название списка в строках о ходе загрузки («Точки: ждёт очереди…»).
    var cacheTitle: String {
        switch self {
        case .nodes:
            return "Объекты"
        case .measurePoints:
            return "Точки"
        case .equipment:
            return "Оборудование"
        }
    }

    /// Заголовок пустого экрана во время первой загрузки.
    var loadingTitle: String {
        switch self {
        case .nodes:
            return "Загрузка объектов"
        case .measurePoints:
            return "Загрузка точек учёта"
        case .equipment:
            return "Загрузка оборудования"
        }
    }

    /// Заголовок пустого экрана, когда на сервере ничего нет.
    var emptyTitle: String {
        switch self {
        case .nodes:
            return "Объектов нет"
        case .measurePoints:
            return "Точек учёта нет"
        case .equipment:
            return "Оборудования нет"
        }
    }
}

// MARK: - Цвет состояния

extension ItemState {
    /// Цвет кружка состояния в списках.
    var color: Color {
        switch self {
        case .normal:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        case .noData:
            return .gray
        case .unknown:
            return Color(.systemGray4)
        }
    }
}

/// Цветной кружок состояния объекта или точки.
struct StateDot: View {
    /// Диаметр кружка (нужен и для выравнивания в RowMarker).
    static let size: CGFloat = 10

    let state: ItemState

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: Self.size, height: Self.size)
            // VoiceOver прочитает словами: «Состояние: Ошибка».
            .accessibilityLabel("Состояние: \(state.title)")
    }
}

/// Состояние словами с цветным кружком: «● Ошибка».
struct StateLabel: View {
    let state: ItemState

    var body: some View {
        HStack(spacing: 6) {
            StateDot(state: state)
                .accessibilityHidden(true)
            Text(state.title)
        }
    }
}

// MARK: - Левый столбец строки: состояние и значок

/// Кружок состояния и под ним значок (тип объекта или система точки) — вместо отдельной строки
/// «⌂ Жилой дом» / «💧 Холодное водоснабжение» (решение владельца 2026-10-06: списки компактнее).
/// Кружок стоит на одной линии с названием, значок — со второй строкой (адрес, объект).
/// Если второй строки нет (`isStacked = false`), значок встаёт рядом с кружком в той же строке,
/// иначе он сам сделал бы строку выше.
struct RowMarker<Icon: View>: View {
    let state: ItemState
    var isStacked = true
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        if isStacked {
            VStack(spacing: 6) {
                StateDot(state: state)
                icon()
                    .font(.subheadline)
            }
            // Одинаковая ширина у всех строк — названия начинаются с одной линии.
            .frame(width: 22)
            // По линии текста названия выравниваем низ кружка (как было без значка), а не значок:
            // иначе SwiftUI берёт линию текста значка, и кружок уезжает выше названия.
            .alignmentGuide(.firstTextBaseline) { dimensions in
                dimensions[VerticalAlignment.top] + StateDot.size
            }
        } else {
            HStack(spacing: 8) {
                StateDot(state: state)
                icon()
                    .font(.subheadline)
                    .frame(width: 22)
            }
        }
    }
}

// MARK: - Значок инженерной системы

extension MeasurePoint {
    /// Цвет значка инженерной системы (значки — MeasurePoint.systemSymbolName).
    var systemColor: Color {
        switch systemType {
        case "Heat":
            return .red
        case "HotWater":
            // Красный кран — горячая вода (как в официальной программе); синий — холодная.
            return .red
        case "ColdWater":
            return .blue
        case "Gas":
            return .orange
        case "Electricity":
            return .yellow
        case "Sewage":
            return .brown
        default:
            return .gray
        }
    }
}

/// Цветной значок инженерной системы точки: радиатор, капля, молния…
/// VoiceOver прочитает название системы словами («Теплоснабжение»).
struct SystemIcon: View {
    let point: MeasurePoint

    var body: some View {
        Image(systemName: point.systemSymbolName)
            .foregroundStyle(point.systemColor)
            .accessibilityLabel(point.systemTitle)
    }
}

// MARK: - Фильтр по состоянию

/// Какие записи показывать в списке: все или только с определённым состоянием.
/// Фильтр работает на телефоне, по кэшу — трафика не тратит.
enum StateFilter: String, CaseIterable, Identifiable {
    case all
    case problems
    case error
    case warning
    case noData

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "Все"
        case .problems:
            return "Ошибки и предупреждения"
        case .error:
            return "Ошибка"
        case .warning:
            return "Предупреждение"
        case .noData:
            return "Нет данных"
        }
    }

    /// Подходит ли состояние под фильтр.
    func matches(_ state: ItemState) -> Bool {
        switch self {
        case .all:
            return true
        case .problems:
            return state == .error || state == .warning
        case .error:
            return state == .error
        case .warning:
            return state == .warning
        case .noData:
            return state == .noData
        }
    }
}

/// Кнопка-меню фильтра в панели навигации: «Все», «Ошибка (3)»…
/// Когда фильтр включён, значок закрашивается — видно, что показан не весь список.
/// Вкладка «Объекты» добавляет в это же меню выбор группы (`extraContent` — пункты над состояниями,
/// `isExtraFilterActive` — выбрана ли группа).
struct StateFilterMenu<ExtraContent: View>: View {
    @Binding var filter: StateFilter
    /// Состояния всех записей списка — чтобы показать количество в каждом пункте.
    let states: [ItemState]
    var isExtraFilterActive = false
    @ViewBuilder var extraContent: () -> ExtraContent

    var body: some View {
        Menu {
            extraContent()
            // Раздел меню с подписью «Состояние» (как разделы меню в «Файлах» и «Почте»).
            // Пункты — переключатели: в меню iOS показывает их с галочкой у выбранного.
            // (Picker в меню подпись раздела не показывает — поэтому не он.)
            Section("Состояние") {
                ForEach(StateFilter.allCases) { option in
                    Toggle(itemTitle(option), isOn: Binding(
                        get: { filter == option },
                        set: { isOn in
                            if isOn {
                                filter = option
                            }
                        }
                    ))
                }
            }
        } label: {
            Label("Фильтр",
                  systemImage: filter == .all && !isExtraFilterActive
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private func itemTitle(_ option: StateFilter) -> String {
        if option == .all {
            return option.title
        }
        let count = states.filter { option.matches($0) }.count
        return "\(option.title) (\(count))"
    }
}

extension StateFilterMenu where ExtraContent == EmptyView {
    /// Меню только с фильтром по состоянию (вкладки «Точки», «Оборудование»).
    init(filter: Binding<StateFilter>, states: [ItemState]) {
        self.init(filter: filter, states: states, isExtraFilterActive: false, extraContent: { EmptyView() })
    }
}

// MARK: - Подпись со значком

/// Мелкая серая подпись со значком: «⌂ Жилой дом», «⚡ Электроснабжение».
/// Обычный Label в строке списка оставляет под значок широкую колонку — здесь значок
/// стоит вплотную к тексту.
struct CaptionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Ход загрузки

/// Полоса прогресса и «Получено X КБ из Y КБ» (или «Нет сети, ждём подключения…»).
struct DownloadProgressView: View {
    let progress: DownloadProgress
    /// true — по центру (на пустом экране), false — по левому краю (над списком, в «Настройках»).
    var isCentered = false

    var body: some View {
        VStack(alignment: isCentered ? .center : .leading, spacing: 4) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                // Полный размер неизвестен — просто «крутилка» без полосы.
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: isCentered ? .center : .leading)
            }
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var statusText: String {
        if progress.isWaitingForNetwork {
            return "Нет сети, ждём подключения…"
        }
        if progress.receivedBytes == 0 {
            return "Подключение к серверу…"
        }
        return TextFormatting.downloadProgress(progress)
    }
}

// MARK: - Кнопка «Настройки»

/// Кнопка ⚙︎ слева вверху списка: открывает «Настройки» поверх экрана (стандартное окно-sheet,
/// закрывается кнопкой «Готово» или жестом вниз). Своё состояние «открыто/закрыто» у каждого списка.
private struct SettingsButtonModifier: ViewModifier {
    @State private var isSettingsShown = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isSettingsShown = true
                    } label: {
                        Label("Настройки", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $isSettingsShown) {
                SettingsView()
            }
    }
}

extension View {
    /// Кнопка ⚙︎ «Настройки» в панели навигации (для вкладок «Объекты», «Точки», «Оборудование»).
    func settingsButton() -> some View {
        modifier(SettingsButtonModifier())
    }
}

// MARK: - Строка над списком

extension ListKind {
    /// «128 объектов» или «Показано: 5 из 128» (включён поиск или фильтр).
    @MainActor
    func countLine(dataStore: DataStore, shownCount: Int, isFiltered: Bool) -> String {
        let total = dataStore.itemCount(for: self)
        if isFiltered {
            return "Показано: \(shownCount) из \(total)"
        }
        return countText(total)
    }

    /// «Обновлено сегодня в 03:38» или nil, если список ещё не загружался.
    @MainActor
    func updatedLine(dataStore: DataStore) -> String? {
        guard let updatedAt = dataStore.updatedAt(for: self) else {
            return nil
        }
        return "Обновлено \(TextFormatting.updatedAt(updatedAt))"
    }
}

/// Середина панели над списком — две строки по центру вместо заголовка (решение владельца 2026-10-06):
///   «64 единицы оборудования»
///   «Обновлено сегодня в 14:08»
/// Заголовок экрана не нужен — вкладка внизу и так подписана. Системный подзаголовок iOS 26
/// не подошёл: если строка не помещалась между кнопками, iOS сдвигала её влево или обрезала «…».
/// Если выбрана группа объектов — первая строка её название, вторая — сколько показано.
/// navigationTitle у экрана остаётся: его читает VoiceOver и показывает меню кнопки «Назад».
private struct ListTitle: ViewModifier {
    @Environment(DataStore.self) private var dataStore

    let kind: ListKind
    let shownCount: Int
    let isFiltered: Bool
    let groupTitle: String?

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(firstLine)
                            .font(.subheadline.weight(.semibold))
                        if let secondLine {
                            Text(secondLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                }
            }
    }

    private var countLine: String {
        return kind.countLine(dataStore: dataStore, shownCount: shownCount, isFiltered: isFiltered)
    }

    private var firstLine: String {
        return groupTitle ?? countLine
    }

    private var secondLine: String? {
        if groupTitle != nil {
            return countLine
        }
        return kind.updatedLine(dataStore: dataStore)
    }
}

extension View {
    /// Две строки по центру панели: количество и время обновления (см. ListTitle).
    func listTitle(kind: ListKind, shownCount: Int, isFiltered: Bool, groupTitle: String? = nil) -> some View {
        modifier(ListTitle(kind: kind, shownCount: shownCount, isFiltered: isFiltered, groupTitle: groupTitle))
    }
}

/// Оранжевая строка о проблеме со связью: «Нет интернета», «Обнаружены белые списки…»
/// или «Интернет есть, сервер ЛЭРС не отвечает» (см. ConnectionProblemDetector).
/// Показывается вместо обычной ошибки связи. Если проблемы нет — ничего не показывает.
struct ConnectionProblemNotice: View {
    /// false — не показывать «сервер не отвечает» (на экране входа своя, более полезная ошибка:
    /// «Проверьте адрес и порт»).
    var showsServerUnreachable = true

    var body: some View {
        if let problem = ConnectionProblemNotice.visibleProblem(showsServerUnreachable: showsServerUnreachable) {
            Label(problem.message, systemImage: problem.systemImage)
                .foregroundStyle(.orange)
        }
    }

    /// Какую проблему показать (nil — никакую).
    static func visibleProblem(showsServerUnreachable: Bool = true) -> ConnectionProblem? {
        let problem = ConnectionProblemDetector.shared.problem
        if problem == .serverUnreachable && !showsServerUnreachable {
            return nil
        }
        return problem
    }
}

/// Строка над списком: ход загрузки или ошибка обновления (итог списка — в панели сверху, см. ListTitle).
/// Ошибка не скрывает данные — она показывается здесь, над старым списком.
/// Если показывать нечего — строки нет совсем (не занимает места).
struct ListStatusHeader: View {
    @Environment(DataStore.self) private var dataStore

    let kind: ListKind

    var body: some View {
        let state = dataStore.state(for: kind)
        let hasConnectionProblem = ConnectionProblemDetector.shared.problem != nil

        if state != .idle || hasConnectionProblem {
            VStack(alignment: .leading, spacing: 6) {
                ConnectionProblemNotice()
                switch state {
                case .idle:
                    EmptyView()
                case .queued:
                    Text("Обновление ждёт очереди…")
                        .foregroundStyle(.secondary)
                case .loading(let progress):
                    HStack(alignment: .top, spacing: 12) {
                        DownloadProgressView(progress: progress)
                        Button("Отмена") {
                            dataStore.cancel(kind)
                        }
                        .buttonStyle(.borderless)
                    }
                case .failed(let message):
                    // Если причина известна, она уже написана строкой выше — не повторяем.
                    if !hasConnectionProblem {
                        Label("Не удалось обновить: \(message)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .font(.footnote)
            .textCase(nil)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Пустой список

/// Что показать, когда в списке ничего нет: идёт первая загрузка, ошибка,
/// список ещё не загружался или на сервере действительно пусто.
struct EmptyListView: View {
    @Environment(DataStore.self) private var dataStore

    let kind: ListKind

    var body: some View {
        switch dataStore.state(for: kind) {
        case .loading(let progress):
            ContentUnavailableView {
                Label(kind.loadingTitle,
                      systemImage: "arrow.down.circle")
            } description: {
                Text("Список сохранится на устройстве и дальше будет открываться сразу, даже без интернета.")
            } actions: {
                VStack(spacing: 12) {
                    DownloadProgressView(progress: progress, isCentered: true)
                        .frame(maxWidth: 280)
                    Button("Отмена") {
                        dataStore.cancel(kind)
                    }
                }
            }

        case .queued:
            ContentUnavailableView {
                Label("Ждёт загрузки", systemImage: "clock")
            } description: {
                Text("Сейчас загружается другой список. Этот загрузится следом.")
            }

        case .failed(let message):
            ContentUnavailableView {
                let problem = ConnectionProblemDetector.shared.problem
                Label("Не удалось загрузить", systemImage: problem?.systemImage ?? "wifi.exclamationmark")
            } description: {
                // Если причина известна (нет интернета, белые списки…) — пишем её вместо общей ошибки.
                Text(ConnectionProblemDetector.shared.problem?.message ?? message)
            } actions: {
                Button("Повторить") {
                    dataStore.refresh(kind)
                }
                .buttonStyle(.borderedProminent)
            }

        case .idle:
            if dataStore.updatedAt(for: kind) != nil {
                // Загружали — и на сервере пусто.
                ContentUnavailableView(kind.emptyTitle,
                                       systemImage: "tray",
                                       description: Text("На сервере нет записей, доступных этой учётной записи."))
            } else {
                // Ещё не загружали (например, загрузку отменили).
                ContentUnavailableView {
                    Label("Список ещё не загружен", systemImage: "tray.and.arrow.down")
                } description: {
                    Text("Загрузка может занять время на медленной связи.")
                } actions: {
                    Button("Загрузить") {
                        dataStore.refresh(kind)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
