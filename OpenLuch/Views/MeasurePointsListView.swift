import SwiftUI

// Вкладка «Точки»: список обычных точек учёта из кэша, поиск вверху, переход к карточке точки.
// Список может быть большим (1500+ точек ≈ 3 МБ на сервере) — поэтому он хранится на телефоне
// и обновляется редко (см. DataStore). Жест «потянуть вниз» намеренно не делаем.
// Фильтры (кнопка вверху справа, окно «Фильтры»): состояние, системы (несколько сразу), группа объектов,
// тип связи — вместе. Выбор запоминается между запусками.
struct MeasurePointsListView: View {
    @Environment(DataStore.self) private var dataStore
    @State private var searchText = ""
    /// Фильтры — JSON в настройках приложения (@AppStorage), см. PointFilter.
    @AppStorage("filters.points") private var savedFilter = Data()
    @State private var isFiltersShown = false

    /// Номер точки, выбранной в списке (карточка — справа на iPad, поверх списка на iPhone).
    /// Храним номер, а не саму запись: после обновления списка она берётся свежая из кэша.
    @State private var selectedPointId: Int?

    /// Какие колонки видны на iPad. .all — список и карточка рядом всегда, и в вертикальном положении
    /// (иначе iOS прячет список за край экрана). Пользователь может скрыть список кнопкой слева вверху.
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            content
                .navigationTitle("Точки")
                // Маленький заголовок в одном ряду с кнопками (вкладка внизу и так подписана) —
                // экономит ≈50 pt сверху (решение владельца 2026-10-06).
                .navigationBarTitleDisplayMode(.inline)
                // Поле поиска закреплено под панелью и не уезжает при прокрутке — в длинном списке
                // не нужно листать к началу, чтобы искать (решение владельца 2026-10-06).
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Название, объект или адрес")
                .toolbar {
                    if !dataStore.measurePoints.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            FilterButton(isActive: filter.wrappedValue.isActive) {
                                isFiltersShown = true
                            }
                        }
                    }
                }
                .sheet(isPresented: $isFiltersShown) {
                    filtersSheet
                }
                .settingsButton()
                .listColumnWidth()
        } detail: {
            DetailColumn(kind: .measurePoints, item: selectedPointId.flatMap { dataStore.measurePoint(withId: $0) }) { point in
                MeasurePointDetailView(point: point)
            }
        }
        .appSplitViewStyle()
        .onAppear {
            dataStore.listDidAppear(.measurePoints)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !dataStore.isCacheLoaded {
            ProgressView()
        } else if dataStore.measurePoints.isEmpty {
            EmptyListView(kind: .measurePoints)
        } else {
            let current = filter.wrappedValue
            let foundPoints = filteredPoints(current)
            // Нажатие на строку выбирает её, NavigationSplitView показывает карточку.
            List(selection: $selectedPointId) {
                Section {
                    ForEach(foundPoints) { point in
                        NavigationLink(value: point.id) {
                            MeasurePointRow(point: point, showsNode: true)
                        }
                    }
                } header: {
                    // Заголовок — только если в нём что-то есть: пустой занимает место (см. ListStatusHeader).
                    if ListStatusHeader.hasContent(kind: .measurePoints, dataStore: dataStore) || current.isActive {
                        VStack(alignment: .leading, spacing: 4) {
                            ListStatusHeader(kind: .measurePoints)
                            if current.isActive {
                                ActiveFilterBar(summary: summary(current), reset: resetFilter)
                            }
                        }
                    }
                }
                // Линия над первой строкой не нужна: над ней теперь обычно ничего нет
                // (итог списка — в подзаголовке экрана).
                .listSectionSeparator(.hidden, edges: .top)
            }
            .listStyle(.plain)
            .listTitle(kind: .measurePoints, shownCount: foundPoints.count,
                       isFiltered: isSearching || current.isActive)
            .overlay {
                if foundPoints.isEmpty {
                    if isSearching {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        FilteredEmptyView(summary: summary(current), reset: resetFilter)
                    }
                }
            }
        }
    }

    private var isSearching: Bool {
        return !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Фильтры

    /// Фильтры: читаются из настроек и туда же сохраняются при каждом изменении.
    private var filter: Binding<PointFilter> {
        Binding(get: { PointFilter.decode(savedFilter) },
                set: { savedFilter = $0.encoded })
    }

    private func resetFilter() {
        filter.wrappedValue = PointFilter()
    }

    /// Точки, подходящие под фильтры и поиск (поиск — по полному названию, в нём есть и объект, и адресу).
    private func filteredPoints(_ current: PointFilter) -> [MeasurePoint] {
        if !isSearching && !current.isActive {
            return dataStore.measurePoints
        }
        let groupMembers = dataStore.nodeIds(inGroup: current.groupId)
        return dataStore.measurePoints.filter { point in
            if !current.matches(point, groupMembers: groupMembers, customerIds: dataStore.customerIds(ofPoint: point)) {
                return false
            }
            if isSearching {
                return TextFormatting.matches(point.fullTitle + " " + (point.address ?? ""), query: searchText)
            }
            return true
        }
    }

    /// Подпись системы по коду сервера («Heat» → «Теплоснабжение»).
    /// nonisolated — передаётся в map/distinct как обычная функция, главный поток ей не нужен.
    private nonisolated static func systemTitle(_ systemType: String) -> String {
        return MeasurePoint.systemTitle(for: systemType)
    }

    /// Подпись типа связи по коду сервера; не указан — «Не указан».
    private nonisolated static func commLinkTitle(_ commLinkType: String) -> String {
        return MeasurePoint.commLinkTitle(for: commLinkType) ?? "Не указан"
    }

    /// «Ошибка · Теплоснабжение, ГВС · Котельные · GPRS» — для строки над списком.
    private func summary(_ current: PointFilter) -> String {
        var parts: [String] = []
        if !current.states.isEmpty {
            // В порядке вариантов окна: «Ошибка, Предупреждение».
            parts.append(StateFilter.allCases.filter(current.states.contains).map(\.title).joined(separator: ", "))
        }
        if !current.systems.isEmpty {
            parts.append(current.systems.map(MeasurePointsListView.systemTitle).sorted().joined(separator: ", "))
        }
        if let group = dataStore.nodeGroups.first(where: { $0.id == current.groupId }) {
            parts.append(group.title)
        }
        if !current.commLinks.isEmpty {
            parts.append(current.commLinks.map(MeasurePointsListView.commLinkTitle).sorted().joined(separator: ", "))
        }
        if let customer = dataStore.customers.first(where: { $0.id == current.customerId }) {
            parts.append(customer.title)
        }
        return parts.joined(separator: " · ")
    }

    private var filtersSheet: some View {
        FiltersSheet(isActive: filter.wrappedValue.isActive, reset: resetFilter) {
            Section {
                StateFilterMenu(selection: filter.states)
                FilterPicker(title: "Группа объектов", options: FilterOption.groups(dataStore.nodeGroups),
                             selection: Binding(get: { filter.wrappedValue.groupId.map(String.init) },
                                                set: { filter.wrappedValue.groupId = $0.flatMap { Int($0) } }))
                FilterPicker(title: "Потребитель", options: FilterOption.customers(dataStore.customers),
                             selection: Binding(get: { filter.wrappedValue.customerId.map(String.init) },
                                                set: { filter.wrappedValue.customerId = $0.flatMap { Int($0) } }))
                // Системы — со значками, как в строках списка (градусник, краны, молния…).
                FilterMultiMenu(title: "Система",
                                options: FilterOption.distinct(dataStore.measurePoints, value: { $0.systemType ?? "" },
                                                               title: MeasurePointsListView.systemTitle)
                                    .map { option in
                                        FilterOption(value: option.value, title: option.title,
                                                     systemImage: MeasurePoint.systemSymbolName(for: option.value),
                                                     color: MeasurePoint.systemColor(for: option.value))
                                    },
                                selection: filter.systems, allTitle: "Все системы")
                // Типы связи — со значками, как в программе ЛЭРС для ПК (глобус, вышка, телефон…).
                FilterMultiMenu(title: "Тип связи",
                                options: FilterOption.distinct(dataStore.measurePoints, value: { $0.commLinkType ?? "" },
                                                               title: MeasurePointsListView.commLinkTitle)
                                    .map { option in
                                        FilterOption(value: option.value, title: option.title,
                                                     systemImage: MeasurePoint.commLinkSymbolName(for: option.value),
                                                     color: .accentColor)
                                    },
                                selection: filter.commLinks, allTitle: "Все типы связи")
            }
        }
    }
}

/// Строка списка точек: состояние и значок системы, название точки, объект.
struct MeasurePointRow: View {
    let point: MeasurePoint
    /// Показывать ли объект (в карточке объекта он и так понятен).
    let showsNode: Bool

    var body: some View {
        let parentTitle = showsNode ? (point.parentTitle ?? "") : ""

        // Слева кружок состояния и цветной значок системы (под кружком или рядом, если строка одна).
        // Подписи системы словами нет — хватает значка (VoiceOver прочитает систему).
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RowMarker(state: point.itemState, isStacked: !parentTitle.isEmpty) {
                SystemIcon(point: point)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(point.title)
                if !parentTitle.isEmpty {
                    Text(parentTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
