import SwiftUI

// Вкладка «Точки»: список обычных точек учёта из кэша, поиск вверху, переход к карточке точки.
// Список может быть большим (1500+ точек ≈ 3 МБ на сервере) — поэтому он хранится на телефоне
// и обновляется редко (см. DataStore). Жест «потянуть вниз» намеренно не делаем.
struct MeasurePointsListView: View {
    @Environment(DataStore.self) private var dataStore
    @State private var searchText = ""
    @State private var stateFilter: StateFilter = .all

    var body: some View {
        NavigationStack {
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
                            StateFilterMenu(filter: $stateFilter,
                                            states: dataStore.measurePoints.map { $0.itemState })
                        }
                    }
                }
                .settingsButton()
                .appNavigationDestinations()
        }
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
            let foundPoints = filteredPoints
            List {
                Section {
                    ForEach(foundPoints) { point in
                        NavigationLink(value: point) {
                            MeasurePointRow(point: point, showsNode: true)
                        }
                    }
                } header: {
                    ListStatusHeader(kind: .measurePoints)
                }
                // Линия над первой строкой не нужна: над ней теперь обычно ничего нет
                // (итог списка — в подзаголовке экрана).
                .listSectionSeparator(.hidden, edges: .top)
            }
            .listStyle(.plain)
            .listTitle(kind: .measurePoints, shownCount: foundPoints.count,
                          isFiltered: isSearching || stateFilter != .all)
            .overlay {
                if foundPoints.isEmpty {
                    if isSearching {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        ContentUnavailableView("Таких точек нет",
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

    /// Поиск — на телефоне: по полному названию (в нём есть и объект) и адресу.
    private var filteredPoints: [MeasurePoint] {
        if !isSearching && stateFilter == .all {
            return dataStore.measurePoints
        }
        return dataStore.measurePoints.filter { point in
            if !stateFilter.matches(point.itemState) {
                return false
            }
            if isSearching {
                return TextFormatting.matches(point.fullTitle + " " + (point.address ?? ""), query: searchText)
            }
            return true
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
