import SwiftUI

// Вкладка «Объекты»: список объектов учёта из кэша, поиск вверху, переход к карточке объекта.
// Список не загружается при каждом открытии — см. правила обновления в DataStore.
// Жест «потянуть вниз для обновления» намеренно не делаем (решение владельца, PLAN.md).
//
// Фильтры (кнопка вверху справа, окно «Фильтры»): состояние, группа, тип объекта, сезон — вместе.
// Заголовок экрана показывает выбранную группу. Выбор запоминается между запусками.
struct NodesListView: View {
    @Environment(DataStore.self) private var dataStore
    @State private var searchText = ""
    /// Фильтры — JSON в настройках приложения (@AppStorage), см. NodeFilter.
    @AppStorage("filters.nodes") private var savedFilter = Data()
    @State private var isFiltersShown = false
    /// Номер объекта, выбранного в списке (его карточка — справа на iPad, поверх списка на iPhone).
    /// Храним номер, а не сам объект: после обновления списка объект берётся свежий из кэша.
    @State private var selectedNodeId: Int?

    /// Какие колонки видны на iPad. .all — список и карточка рядом всегда, и в вертикальном положении
    /// (иначе iOS прячет список за край экрана). Пользователь может скрыть список кнопкой слева вверху.
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            content
                .navigationTitle(selectedGroup(filter.wrappedValue)?.title ?? "Объекты")
                // Маленький заголовок в одном ряду с кнопками (вкладка внизу и так подписана) —
                // экономит ≈50 pt сверху (решение владельца 2026-10-06).
                .navigationBarTitleDisplayMode(.inline)
                // Поле поиска закреплено под панелью и не уезжает при прокрутке — в длинном списке
                // не нужно листать к началу, чтобы искать (решение владельца 2026-10-06).
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Название или адрес")
                .toolbar {
                    if !dataStore.nodes.isEmpty {
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
            DetailColumn(kind: .nodes, item: selectedNodeId.flatMap { dataStore.node(withId: $0) }) { node in
                NodeDetailView(node: node)
            }
        }
        .appSplitViewStyle()
        .onAppear {
            dataStore.listDidAppear(.nodes)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !dataStore.isCacheLoaded {
            // Кэш читается — это доли секунды.
            ProgressView()
        } else if dataStore.nodes.isEmpty {
            EmptyListView(kind: .nodes)
        } else {
            let current = filter.wrappedValue
            let foundNodes = filteredNodes(current)
            // List(selection:) + NavigationLink(value: номер) — нажатие выбирает объект,
            // а NavigationSplitView показывает его карточку.
            List(selection: $selectedNodeId) {
                Section {
                    ForEach(foundNodes) { node in
                        NavigationLink(value: node.id) {
                            NodeRow(node: node)
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        ListStatusHeader(kind: .nodes)
                        if current.isActive {
                            ActiveFilterBar(summary: summary(current), reset: resetFilter)
                        }
                    }
                }
                // Линия над первой строкой не нужна: над ней теперь обычно ничего нет
                // (итог списка — в подзаголовке экрана).
                .listSectionSeparator(.hidden, edges: .top)
            }
            .listStyle(.plain)
            .listTitle(kind: .nodes, shownCount: foundNodes.count,
                       isFiltered: isSearching || current.isActive,
                       groupTitle: selectedGroup(current)?.title)
            .overlay {
                if foundNodes.isEmpty {
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
    private var filter: Binding<NodeFilter> {
        Binding(get: { NodeFilter.decode(savedFilter) },
                set: { savedFilter = $0.encoded })
    }

    private func resetFilter() {
        filter.wrappedValue = NodeFilter()
    }

    /// Выбранная группа — или nil (не выбрана или удалена на сервере).
    private func selectedGroup(_ current: NodeFilter) -> NodeGroup? {
        return dataStore.nodeGroups.first { $0.id == current.groupId }
    }

    /// Объекты, подходящие под фильтры и поиск (поиск — по названию и адресу).
    private func filteredNodes(_ current: NodeFilter) -> [Node] {
        if !isSearching && !current.isActive {
            return dataStore.nodes
        }
        let groupMembers = dataStore.nodeIds(inGroup: current.groupId)
        return dataStore.nodes.filter { node in
            if !current.matches(node, groupMembers: groupMembers, customerIds: dataStore.customerIds(ofNode: node)) {
                return false
            }
            if isSearching {
                return TextFormatting.matches(node.title + " " + node.address, query: searchText)
            }
            return true
        }
    }

    /// Сколько объектов останется, если изменить один фильтр (для чисел у вариантов в окне «Фильтры»).
    private func count(_ change: (inout NodeFilter) -> Void) -> Int {
        var changed = filter.wrappedValue
        change(&changed)
        let groupMembers = dataStore.nodeIds(inGroup: changed.groupId)
        return dataStore.nodes.filter {
            changed.matches($0, groupMembers: groupMembers, customerIds: dataStore.customerIds(ofNode: $0))
        }.count
    }

    /// «Ошибка · Котельные · Жилой дом» — для строки над списком.
    private func summary(_ current: NodeFilter) -> String {
        var parts: [String] = []
        if current.state != .all {
            parts.append(current.state.title)
        }
        if let group = selectedGroup(current) {
            parts.append(group.title)
        }
        if let kind = current.kind {
            parts.append(NodeKind(apiValue: kind).title)
        }
        if let season = current.season {
            parts.append(Node.seasonTitle(season))
        }
        if let customer = dataStore.customers.first(where: { $0.id == current.customerId }) {
            parts.append(customer.title)
        }
        return parts.joined(separator: " · ")
    }

    private var filtersSheet: some View {
        FiltersSheet(isActive: filter.wrappedValue.isActive, reset: resetFilter) {
            Section {
                StateFilterPicker(selection: filter.state) { state in
                    count { $0.state = state }
                }
                FilterPicker(title: "Группа", options: FilterOption.groups(dataStore.nodeGroups),
                             selection: Binding(get: { filter.wrappedValue.groupId.map(String.init) },
                                                set: { filter.wrappedValue.groupId = $0.flatMap { Int($0) } })) { value in
                    count { $0.groupId = value.flatMap { Int($0) } }
                }
                FilterPicker(title: "Потребитель", options: FilterOption.customers(dataStore.customers),
                             selection: Binding(get: { filter.wrappedValue.customerId.map(String.init) },
                                                set: { filter.wrappedValue.customerId = $0.flatMap { Int($0) } })) { value in
                    count { $0.customerId = value.flatMap { Int($0) } }
                }
                FilterPicker(title: "Тип объекта",
                             options: FilterOption.distinct(dataStore.nodes, value: { $0.type ?? "" },
                                                            title: { NodeKind(apiValue: $0).title }),
                             selection: filter.kind) { value in
                    count { $0.kind = value }
                }
                FilterPicker(title: "Сезон",
                             options: FilterOption.distinct(dataStore.nodes, value: { $0.currentSeason ?? "" },
                                                            title: { Node.seasonTitle($0) }),
                             selection: filter.season) { value in
                    count { $0.season = value }
                }
            }
        }
    }
}

/// Строка списка объектов: слева кружок состояния и под ним значок типа (дом, здание…),
/// справа название и адрес. Подписи типа словами нет — хватает значка (VoiceOver прочитает тип).
struct NodeRow: View {
    let node: Node

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RowMarker(state: node.itemState, isStacked: !node.address.isEmpty) {
                Image(systemName: node.kind.symbolName)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(node.kind.title)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(node.title)
                if !node.address.isEmpty {
                    // Не больше двух строк, чтобы на экране помещалось больше объектов.
                    // Полный адрес — в карточке объекта.
                    Text(node.address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}
