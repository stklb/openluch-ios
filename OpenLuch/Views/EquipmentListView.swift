import SwiftUI

// Вкладка «Оборудование»: справочник оборудования из кэша, поиск вверху.
// В строке — модель, заводской номер, объект, где установлено, и даты поверки.
// Справочник тяжёлый (в ответе сервера — полные описания моделей приборов), поэтому он хранится
// на телефоне и обновляется по тем же правилам, что объекты и точки (см. DataStore).
// Жест «потянуть вниз» намеренно не делаем.
//
// По нажатию на строку — карточка оборудования (EquipmentDetailView).
struct EquipmentListView: View {
    @Environment(DataStore.self) private var dataStore
    @State private var searchText = ""

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
            let foundEquipment = filteredEquipment
            // Сегодняшний день считаем один раз на весь список, а не в каждой строке.
            let today = Equipment.calendarDay(of: Date())
            // Нажатие на строку выбирает её, NavigationSplitView показывает карточку.
            List(selection: $selectedEquipmentId) {
                Section {
                    ForEach(foundEquipment) { item in
                        NavigationLink(value: item.id) {
                            EquipmentRow(equipment: item, today: today)
                        }
                    }
                } header: {
                    ListStatusHeader(kind: .equipment)
                }
                // Линия над первой строкой не нужна: над ней теперь обычно ничего нет
                // (итог списка — в подзаголовке экрана).
                .listSectionSeparator(.hidden, edges: .top)
            }
            .listStyle(.plain)
            .listTitle(kind: .equipment, shownCount: foundEquipment.count, isFiltered: isSearching)
            .overlay {
                if foundEquipment.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private var isSearching: Bool {
        return !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Поиск — на телефоне: по модели, заводскому номеру и названию объекта.
    private var filteredEquipment: [Equipment] {
        if !isSearching {
            return dataStore.equipment
        }
        return dataStore.equipment.filter { item in
            let text = item.modelTitle + " " + (item.serialNumber ?? "") + " " + (item.placesTitle ?? "")
            return TextFormatting.matches(text, query: searchText)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: equipment.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                titleText
                    .lineLimit(2)
                Text(equipment.placesTitle ?? "Не установлено на объекте")
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
