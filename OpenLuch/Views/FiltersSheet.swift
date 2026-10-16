import SwiftUI

// Окно «Фильтры» и строка «Фильтр: … Сбросить» над списком — общие для трёх списков
// (решения владельца 2026-10-15). Сами правила фильтров — Models/ListFilters.swift.
//
// Окно — обычная форма (Form) поверх списка, на iPhone — на полэкрана: список за ним виден
// и меняется сразу, пока выбираете. Чисел у вариантов («Тепло (42)») нет — убраны ради простоты
// и скорости: на серверах с тысячами точек их подсчёт тормозил открытие окна (решение владельца 2026-10-16).

/// Вариант фильтра: значение (как его хранит фильтр) и подпись.
struct FilterOption: Identifiable, Hashable {
    let value: String
    let title: String
    /// Значок перед подписью (системы точек — как в списке), nil — без значка.
    var systemImage: String? = nil
    var color: Color = .secondary

    var id: String { value }

    /// Варианты из значений записей: без повторов, по алфавиту подписи.
    static func distinct<Item>(_ items: [Item], value: (Item) -> String,
                               title: (String) -> String) -> [FilterOption] {
        return Set(items.map(value))
            .map { FilterOption(value: $0, title: title($0)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Потребители (номер — строкой), уже по алфавиту (DataStore.customers).
    static func customers(_ customers: [Customer]) -> [FilterOption] {
        return customers.map { FilterOption(value: String($0.id), title: $0.title) }
    }

    /// Группы объектов (номер группы — строкой).
    static func groups(_ groups: [NodeGroup]) -> [FilterOption] {
        return groups.map { FilterOption(value: String($0.id), title: $0.title) }
    }
}

/// Кнопка «Фильтры» в панели над списком. Значок закрашен, когда выбран хоть один фильтр.
struct FilterButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button("Фильтры",
               systemImage: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
               action: action)
    }
}

/// Окно «Фильтры»: строки фильтров (content); вверху «Сбросить» (слева) и «Готово» (справа) —
/// всегда видны, даже когда окно на полэкрана, а строки фильтров уходят ниже края.
struct FiltersSheet<Content: View>: View {
    let isActive: Bool
    let reset: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.dismiss) private var dismiss
    /// Высота окна по содержимому (панель + строки фильтров) — меряется, пока окно открыто.
    @State private var fittedHeight: CGFloat = 300
    /// Текущая высота окна: по содержимому или во весь экран (если пользователь растянул).
    @State private var detent: PresentationDetent = .height(300)

    var body: some View {
        NavigationStack {
            Form {
                content()
            }
            // Без большого пустого отступа над первой строкой (у формы он рассчитан на заголовок раздела).
            .contentMargins(.top, 8, for: .scrollContent)
            // Окно ровно по содержимому (адаптивно): 3 строки — низкое окно, появилась строка
            // с датой — окно подросло. Высота содержимого формы — стандартное измерение iOS 18
            // (onScrollGeometryChange): строки + отступы + панель с «Готово».
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
            } action: { _, newHeight in
                let wasFitted = detent == .height(fittedHeight)
                fittedHeight = newHeight
                if wasFitted {
                    detent = .height(newHeight)
                }
            }
            .navigationTitle("Фильтры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Фильтры не выбраны — кнопка серая (не пропадает, чтобы панель не прыгала).
                    Button("Сбросить", action: reset)
                        .disabled(!isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        dismiss()
                    }
                }
            }
        }
        // На iPhone — по высоте содержимого (можно растянуть на весь экран): список за окном виден
        // и сразу меняется.
        .presentationDetents([.height(fittedHeight), .large], selection: $detent)
    }
}

/// Строка-выбор одного варианта: «Система   Тепло». Выбирать не из чего (меньше двух вариантов
/// и ничего не выбрано) — строки нет.
struct FilterPicker: View {
    let title: String
    let options: [FilterOption]
    /// Выбранный вариант; nil — «Все».
    @Binding var selection: String?

    var body: some View {
        if options.count > 1 || selection != nil {
            Picker(title, selection: $selection) {
                Text("Все")
                    .tag(String?.none)
                ForEach(options) { option in
                    Text(option.title)
                        .tag(Optional(option.value))
                }
            }
        }
    }
}

/// Строка-меню, где можно отметить несколько вариантов (состояния, системы, типы связи): компактно,
/// одной строкой. По нажатию — стандартное меню iOS с галочками; оно не закрывается после каждого
/// нажатия, так что можно отметить несколько подряд. Справа в строке — что выбрано («Ошибка, Предупреждение»).
/// Ничего не отмечено — подходят все. Выбирать не из чего (меньше двух вариантов) — строки нет.
struct FilterMultiMenu: View {
    let title: String
    let options: [FilterOption]
    @Binding var selection: Set<String>
    /// Пункт меню, снимающий выбор: «Все состояния», «Все системы».
    let allTitle: String

    var body: some View {
        if options.count > 1 || !selection.isEmpty {
            LabeledContent(title) {
                Menu {
                    ForEach(options) { option in
                        Toggle(isOn: Binding(
                            get: { selection.contains(option.value) },
                            set: { isOn in
                                if isOn {
                                    selection.insert(option.value)
                                } else {
                                    selection.remove(option.value)
                                }
                            }
                        )) {
                            Label {
                                Text(option.title)
                            } icon: {
                                if let systemImage = option.systemImage {
                                    // В меню iOS перекрашивает значки в один цвет — значок с «зашитым»
                                    // цветом (.alwaysOriginal) остаётся цветным, как в строках списков.
                                    Image(uiImage: UIImage(systemName: systemImage)?
                                        .withTintColor(UIColor(option.color), renderingMode: .alwaysOriginal)
                                        ?? UIImage())
                                }
                            }
                        }
                    }
                    if !selection.isEmpty {
                        Divider()
                        Button(allTitle) {
                            selection = []
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(summary)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .imageScale(.small)
                    }
                    .foregroundStyle(.secondary)
                }
                // Меню остаётся открытым — можно отметить несколько вариантов подряд.
                .menuActionDismissBehavior(.disabled)
            }
        }
    }

    /// «Все», «Ошибка» или «Ошибка, Предупреждение» — в порядке вариантов меню.
    private var summary: String {
        if selection.isEmpty {
            return "Все"
        }
        return options.filter { selection.contains($0.value) }.map(\.title).joined(separator: ", ")
    }
}

/// Строка «Состояние» — FilterMultiMenu с цветными кружками, как в строках списков.
struct StateFilterMenu: View {
    @Binding var selection: Set<StateFilter>

    var body: some View {
        FilterMultiMenu(
            title: "Состояние",
            options: StateFilter.allCases.map { state in
                FilterOption(value: state.rawValue, title: state.title,
                             systemImage: "circle.fill", color: state.itemState.color)
            },
            selection: Binding(get: { Set(selection.map(\.rawValue)) },
                               set: { selection = Set($0.compactMap(StateFilter.init(rawValue:))) }),
            allTitle: "Все состояния"
        )
    }
}

/// Строка над списком, когда выбраны фильтры: «Фильтр: Ошибка · Тепло» и «Сбросить».
/// Видно, почему список короче, — и фильтры, запомненные с прошлого раза, не забудутся.
struct ActiveFilterBar: View {
    let summary: String
    let reset: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("Фильтр: \(summary)", systemImage: "line.3.horizontal.decrease.circle.fill")
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Сбросить", action: reset)
                .buttonStyle(.borderless)
        }
        .font(.footnote)
        .textCase(nil)
    }
}

/// Пустой результат из-за фильтров: что выбрано и кнопка «Сбросить фильтры».
struct FilteredEmptyView: View {
    let summary: String
    let reset: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Ничего не найдено", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("Фильтр: \(summary).")
        } actions: {
            Button("Сбросить фильтры", action: reset)
        }
    }
}
