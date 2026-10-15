import SwiftUI

// Окно «Фильтры» и строка «Фильтр: … Сбросить» над списком — общие для трёх списков
// (решения владельца 2026-10-15). Сами правила фильтров — Models/ListFilters.swift.
//
// Окно — обычная форма (Form) поверх списка, на iPhone — на полэкрана: список за ним виден
// и меняется сразу, пока выбираете. В каждой строке-выборе у вариантов — сколько записей останется
// с учётом остальных выбранных фильтров («Тепло (42)»).

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

    var body: some View {
        NavigationStack {
            Form {
                content()
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
        // На iPhone — на полэкрана (можно растянуть): список за окном виден и сразу меняется.
        .presentationDetents([.medium, .large])
    }
}

/// Строка-выбор одного варианта: «Система   Тепло (42)». Выбирать не из чего (меньше двух вариантов
/// и ничего не выбрано) — строки нет.
struct FilterPicker: View {
    let title: String
    let options: [FilterOption]
    /// Выбранный вариант; nil — «Все».
    @Binding var selection: String?
    /// Сколько записей останется при этом варианте (nil — «Все») с учётом остальных фильтров.
    let count: (String?) -> Int

    var body: some View {
        if options.count > 1 || selection != nil {
            Picker(title, selection: $selection) {
                Text("Все (\(count(nil)))")
                    .tag(String?.none)
                ForEach(options) { option in
                    Text("\(option.title) (\(count(option.value)))")
                        .tag(Optional(option.value))
                }
            }
        }
    }
}

/// Строка «Состояние» — тот же выбор одного варианта, для StateFilter.
struct StateFilterPicker: View {
    @Binding var selection: StateFilter
    /// Сколько записей останется при этом состоянии с учётом остальных фильтров.
    let count: (StateFilter) -> Int

    var body: some View {
        FilterPicker(
            title: "Состояние",
            options: StateFilter.allCases.filter { $0 != .all }.map { FilterOption(value: $0.rawValue, title: $0.title) },
            selection: Binding(get: { selection == .all ? nil : selection.rawValue },
                               set: { selection = $0.flatMap(StateFilter.init(rawValue:)) ?? .all }),
            count: { value in count(value.flatMap(StateFilter.init(rawValue:)) ?? .all) }
        )
    }
}

/// Раздел, где можно отметить несколько вариантов (системы точек учёта): нажатие на строку ставит
/// или снимает галочку справа — так Apple показывает выбор пунктов из списка (переключатели — для
/// настроек «вкл/выкл»). Ничего не отмечено — подходят все.
struct FilterChecklist: View {
    let title: String
    let options: [FilterOption]
    @Binding var selection: Set<String>
    /// Сколько записей с этим вариантом с учётом остальных фильтров.
    let count: (String) -> Int

    var body: some View {
        if options.count > 1 || !selection.isEmpty {
            Section {
                ForEach(options) { option in
                    let isSelected = selection.contains(option.value)
                    Button {
                        if isSelected {
                            selection.remove(option.value)
                        } else {
                            selection.insert(option.value)
                        }
                    } label: {
                        HStack {
                            Label {
                                Text("\(option.title) (\(count(option.value)))")
                                    .foregroundStyle(Color.primary)
                            } icon: {
                                if let systemImage = option.systemImage {
                                    Image(systemName: systemImage)
                                        .foregroundStyle(option.color)
                                }
                            }
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    // VoiceOver: «Теплоснабжение (3), выбрано».
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            } header: {
                Text(title)
            } footer: {
                Text("Можно отметить несколько. Ничего не отмечено — все.")
            }
        }
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
