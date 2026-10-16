import SwiftUI

// Вкладка «Оборудование»: справочник оборудования из кэша, поиск вверху.
// В строке — модель, заводской номер, объект, где установлено, и даты поверки.
// Справочник тяжёлый (в ответе сервера — полные описания моделей приборов), поэтому он хранится
// на телефоне и обновляется по тем же правилам, что объекты и точки (см. DataStore).
// Жест «потянуть вниз» намеренно не делаем.
//
// По нажатию на строку — карточка оборудования (EquipmentDetailView).
// Фильтры (кнопка вверху справа, окно «Фильтры»): поверка (в том числе «Нужно поверить до» выбранной
// даты), тип, группа объектов — вместе. Выбор запоминается между запусками.
struct EquipmentListView: View {
    @Environment(DataStore.self) private var dataStore
    @State private var searchText = ""
    /// Фильтры — JSON в настройках приложения (@AppStorage), см. EquipmentFilter.
    @AppStorage("filters.equipment") private var savedFilter = Data()
    @State private var isFiltersShown = false

    /// Номер оборудования, выбранного в списке (карточка — справа на iPad, поверх списка на iPhone).
    /// Храним номер, а не саму запись: после обновления списка она берётся свежая из кэша.
    @State private var selectedEquipmentId: Int?

    /// Какие колонки видны на iPad. .all — список и карточка рядом всегда, и в вертикальном положении
    /// (иначе iOS прячет список за край экрана). Пользователь может скрыть список кнопкой слева вверху.
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            content
                .navigationTitle("Оборудование")
                // Маленький заголовок в одном ряду с кнопками (вкладка внизу и так подписана) —
                // экономит ≈50 pt сверху (решение владельца 2026-10-06).
                .navigationBarTitleDisplayMode(.inline)
                // Поле поиска закреплено под панелью и не уезжает при прокрутке — в длинном списке
                // не нужно листать к началу, чтобы искать (решение владельца 2026-10-06).
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Модель, номер или объект")
                .toolbar {
                    if !dataStore.equipment.isEmpty {
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
            DetailColumn(kind: .equipment, item: selectedEquipmentId.flatMap { dataStore.equipment(withId: $0) }) { item in
                EquipmentDetailView(equipment: item)
            }
        }
        .appSplitViewStyle()
        .onAppear {
            dataStore.listDidAppear(.equipment)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !dataStore.isCacheLoaded {
            ProgressView()
        } else if dataStore.equipment.isEmpty {
            EmptyListView(kind: .equipment)
        } else {
            let current = filter.wrappedValue
            // Сегодняшний день считаем один раз на весь список, а не в каждой строке.
            let today = Equipment.calendarDay(of: Date())
            let foundEquipment = filteredEquipment(current, today: today)
            // Нажатие на строку выбирает её, NavigationSplitView показывает карточку.
            List(selection: $selectedEquipmentId) {
                Section {
                    ForEach(foundEquipment) { item in
                        NavigationLink(value: item.id) {
                            EquipmentRow(equipment: item, today: today)
                        }
                    }
                } header: {
                    // Заголовок — только если в нём что-то есть: пустой занимает место (см. ListStatusHeader).
                    if ListStatusHeader.hasContent(kind: .equipment, dataStore: dataStore) || current.isActive {
                        VStack(alignment: .leading, spacing: 4) {
                            ListStatusHeader(kind: .equipment)
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
            .listTitle(kind: .equipment, shownCount: foundEquipment.count,
                       isFiltered: isSearching || current.isActive)
            .overlay {
                if foundEquipment.isEmpty {
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
    private var filter: Binding<EquipmentFilter> {
        Binding(get: { EquipmentFilter.decode(savedFilter) },
                set: { savedFilter = $0.encoded })
    }

    private func resetFilter() {
        filter.wrappedValue = EquipmentFilter()
    }

    /// Оборудование, подходящее под фильтры и поиск (поиск — по модели, заводскому номеру и объекту).
    private func filteredEquipment(_ current: EquipmentFilter, today: String) -> [Equipment] {
        if !isSearching && !current.isActive {
            return dataStore.equipment
        }
        let groupMembers = dataStore.nodeIds(inGroup: current.groupId)
        return dataStore.equipment.filter { item in
            if !current.matches(item, groupMembers: groupMembers, today: today) {
                return false
            }
            if isSearching {
                let text = item.modelTitle + " " + (item.serialNumber ?? "") + " " + (item.placesTitle ?? "")
                return TextFormatting.matches(text, query: searchText)
            }
            return true
        }
    }

    /// «Нужно поверить до 01.03.2027 · Прибор учёта · Котельные» — для строки над списком.
    private func summary(_ current: EquipmentFilter) -> String {
        var parts: [String] = []
        switch current.calibration {
        case .all:
            break
        case .dueBefore:
            let day = current.dueBeforeDay ?? EquipmentFilter.defaultDueBeforeDay()
            parts.append("Нужно поверить до \(TextFormatting.calendarDay(day))")
        case .overdue:
            parts.append("Поверка истекла")
        case .noDate:
            parts.append("Дата поверки не указана")
        }
        if let kind = current.kind {
            parts.append(kind)
        }
        if let group = dataStore.nodeGroups.first(where: { $0.id == current.groupId }) {
            parts.append(group.title)
        }
        return parts.joined(separator: " · ")
    }

    /// Выбор «Поверка». Сменили на другой вариант — выбранная дата забывается
    /// (иначе фильтр считался бы включённым, хотя показано «Все»).
    private var calibrationSelection: Binding<String?> {
        Binding(get: {
            let calibration = filter.wrappedValue.calibration
            return calibration == .all ? nil : calibration.rawValue
        }, set: { value in
            var changed = filter.wrappedValue
            changed.calibration = value.flatMap(CalibrationFilter.init(rawValue:)) ?? .all
            if changed.calibration != .dueBefore {
                changed.dueBeforeDay = nil
            }
            filter.wrappedValue = changed
        })
    }

    /// Дата «Нужно поверить до…»: стандартный компактный выбор даты (нажал — открылся календарь).
    private var dueBeforeDate: Binding<Date> {
        Binding(get: {
            let day = filter.wrappedValue.dueBeforeDay ?? EquipmentFilter.defaultDueBeforeDay()
            return Equipment.date(fromCalendarDay: day) ?? Date()
        }, set: { date in
            filter.wrappedValue.dueBeforeDay = Equipment.calendarDay(of: date)
        })
    }

    private var filtersSheet: some View {
        FiltersSheet(isActive: filter.wrappedValue.isActive, reset: resetFilter) {
            Section {
                FilterPicker(title: "Поверка",
                             options: CalibrationFilter.allCases.filter { $0 != .all }
                                .map { FilterOption(value: $0.rawValue, title: $0.title) },
                             selection: calibrationSelection)
                if filter.wrappedValue.calibration == .dueBefore {
                    DatePicker("До", selection: dueBeforeDate, displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "ru_RU"))
                }
                FilterPicker(title: "Тип",
                             options: FilterOption.distinct(dataStore.equipment, value: { $0.kindTitle },
                                                            title: { $0 }),
                             selection: filter.kind)
                FilterPicker(title: "Группа объектов", options: FilterOption.groups(dataStore.nodeGroups),
                             selection: Binding(get: { filter.wrappedValue.groupId.map(String.init) },
                                                set: { filter.wrappedValue.groupId = $0.flatMap { Int($0) } }))
            }
        }
    }
}

/// Строка списка оборудования в две строки (решение владельца 2026-10-06: список компактнее):
///   значок · «Модель № заводской номер»            дата следующей поверки ›
///            объект (или «Не установлено на объекте»)
/// Справа — только дата следующей поверки, как дата письма в «Почте»: мелким шрифтом (footnote)
/// и с годом из двух цифр «до 01.07.27» (решение владельца 2026-10-06); истёкшая — оранжевым с ⚠︎.
/// Дата прошлой поверки и подробности — в карточке оборудования.
struct EquipmentRow: View {
    let equipment: Equipment
    /// Сегодняшний день «гггг-мм-дд» — чтобы отметить истёкший срок поверки.
    let today: String
    /// Вторая строка вместо объекта установки — на экране оборудования объекта, где объект и так
    /// известен («Устройство опроса», «Модем»…). nil — объект установки, как в общем списке.
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: equipment.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                titleText
                    .lineLimit(2)
                Text(subtitle ?? equipment.placesTitle ?? "Не установлено на объекте")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            nextCalibrationLabel
                // Дата не сжимается и не переносится — сжимается название.
                .fixedSize()
        }
    }

    /// «ТВ7 № 12345»: модель обычным цветом, номер — серым.
    private var titleText: Text {
        var text = Text(equipment.modelTitle)
        if let serialNumber = equipment.serialNumber, !serialNumber.isEmpty {
            text = text + Text(" № \(serialNumber)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        return text
    }

    /// Дата следующей поверки справа. Срок истёк — оранжевым с треугольником.
    @ViewBuilder
    private var nextCalibrationLabel: some View {
        if let next = equipment.nextCalibrationDay {
            // На экране — коротко («01.07.27»), VoiceOver читает полную дату.
            let shortDay = TextFormatting.shortCalendarDay(next)
            let day = TextFormatting.calendarDay(next)
            if equipment.isCalibrationOverdue(today: today) {
                Label(shortDay, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(CompactLabelStyle())
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Срок поверки истёк \(day)")
            } else {
                Text("до \(shortDay)")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Следующая поверка \(day)")
            }
        }
    }
}

/// Значок и текст вплотную (стандартный Label в строке списка ставит большой отступ).
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}
