import SwiftUI

// Вкладка «Объекты»: список объектов учёта из кэша, поиск вверху, переход к карточке объекта.
// Список не загружается при каждом открытии — см. правила обновления в DataStore.
// Жест «потянуть вниз для обновления» намеренно не делаем (решение владельца, PLAN.md).
//
// Группы объектов: если на сервере они есть, в меню фильтра (кнопка вверху справа) появляется
// раздел «Группа»: «Все объекты» или одна группа. Заголовок экрана показывает выбранную группу,
// значок фильтра закрашивается. Выбор запоминается между запусками.
struct NodesListView: View {
    @Environment(DataStore.self) private var dataStore
    @State private var searchText = ""
    @State private var stateFilter: StateFilter = .all
    /// Выбранная группа объектов; 0 — все объекты. @AppStorage — запоминается в настройках приложения.
    @AppStorage("nodes.selectedGroupId") private var selectedGroupId = 0

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(selectedGroup?.title ?? "Объекты")
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
                            // Количество в пунктах — по объектам выбранной группы.
                            StateFilterMenu(filter: $stateFilter, states: nodesInSelectedGroup.map { $0.itemState },
                                            isExtraFilterActive: selectedGroup != nil) {
                                if !dataStore.nodeGroups.isEmpty {
                                    groupMenu
                                }
                            }
                        }
                    }
                }
                .settingsButton()
                .appNavigationDestinations()
        }
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
            let foundNodes = filteredNodes
            List {
                Section {
                    ForEach(foundNodes) { node in
                        NavigationLink(value: node) {
                            NodeRow(node: node)
                        }
                    }
                } header: {
                    ListStatusHeader(kind: .nodes)
                }
                // Линия над первой строкой не нужна: над ней теперь обычно ничего нет
                // (итог списка — в подзаголовке экрана).
                .listSectionSeparator(.hidden, edges: .top)
            }
            .listStyle(.plain)
            .listTitle(kind: .nodes, shownCount: foundNodes.count,
                       isFiltered: isSearching || stateFilter != .all || selectedGroup != nil,
                       groupTitle: selectedGroup?.title)
            .overlay {
                if foundNodes.isEmpty {
                    if isSearching {
                        ContentUnavailableView.search(text: searchText)
                    } else if let selectedGroup, stateFilter == .all {
                        ContentUnavailableView("В группе нет объектов",
                                               systemImage: "folder",
                                               description: Text("В группе «\(selectedGroup.title)» нет объектов, доступных этой учётной записи."))
                    } else {
                        ContentUnavailableView("Таких объектов нет",
                                               systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text("Фильтр: «\(stateFilter.title)»."))
                    }
                }
            }
        }
    }

    private var isSearching: Bool {
        return !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Группы

    /// Выбранная группа — или nil («Все объекты», а также если группу удалили на сервере).
    private var selectedGroup: NodeGroup? {
        if selectedGroupId == 0 {
            return nil
        }
        return dataStore.nodeGroups.first { $0.id == selectedGroupId }
    }

    /// Раздел меню фильтра «Группа»: «Все объекты» и группы — с количеством объектов, галочка у выбранной.
    private var groupMenu: some View {
        Section("Группа") {
            groupToggle(title: "Все объекты (\(dataStore.nodes.count))", groupId: 0)
            ForEach(dataStore.nodeGroups) { group in
                groupToggle(title: "\(group.title) (\(group.memberIds.count))", groupId: group.id)
            }
        }
    }

    /// Объекты выбранной группы (или все, если группа не выбрана).
    private var nodesInSelectedGroup: [Node] {
        guard let group = selectedGroup else {
            return dataStore.nodes
        }
        let memberIds = Set(group.memberIds)
        return dataStore.nodes.filter { memberIds.contains($0.id) }
    }

    /// Пункт меню группы: переключатель с галочкой у выбранной (как в StateFilterMenu).
    private func groupToggle(title: String, groupId: Int) -> some View {
        Toggle(title, isOn: Binding(
            get: { selectedGroupId == groupId },
            set: { isOn in
                if isOn {
                    selectedGroupId = groupId
                }
            }
        ))
    }

    // MARK: - Поиск и фильтр

    /// Поиск, фильтр и группа — на телефоне, по уже загруженному списку (поиск — по названию и адресу).
    private var filteredNodes: [Node] {
        let group = selectedGroup
        if !isSearching && stateFilter == .all && group == nil {
            return dataStore.nodes
        }
        // Номера объектов группы — множеством, чтобы проверка была быстрой и на 1000+ объектов.
        let groupMemberIds = Set(group?.memberIds ?? [])
        return dataStore.nodes.filter { node in
            if group != nil && !groupMemberIds.contains(node.id) {
                return false
            }
            if !stateFilter.matches(node.itemState) {
                return false
            }
            if isSearching {
                return TextFormatting.matches(node.title + " " + node.address, query: searchText)
            }
            return true
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
