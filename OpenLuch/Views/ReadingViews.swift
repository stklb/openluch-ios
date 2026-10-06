import SwiftUI

// Показ значений параметров (последние данные точки): таблица «подача/обратка» или «фазы A/B/C»
// и одиночные значения по два в строку. Что куда попадает — решает ReadingsLayout.
//
// Как помечаем значения — как в программе ЛЭРС УЧЁТ для ПК и в её PWA (решение владельца 2026-10-07),
// и так ВЕЗДЕ в приложении, где показываются значения параметров:
// - недостоверное (прибор сообщил ошибку) — красно-бордовым;
// - расчётное (посчитал сервер, а не измерил прибор) — зелёным курсивом.
// Цвета — в Assets.xcassets (ReadingBad, ReadingCalculated), отдельно для светлой и тёмной темы.

/// Цвет и начертание значения параметра — одно место для всего приложения.
enum ReadingStyle {
    static let badColor = Color(.readingBad)
    static let calculatedColor = Color(.readingCalculated)

    /// Цвет значения. Устаревшее (идёт обновление) — серое, пока не придёт новое.
    static func color(for value: DataValue, isStale: Bool) -> Color {
        if isStale {
            return .secondary
        }
        if value.isBad == true {
            return badColor
        }
        if value.isCalc == true {
            return calculatedColor
        }
        return .primary
    }

    /// Пометка для VoiceOver (цвет он не передаёт).
    static func accessibilityNote(for value: DataValue) -> String? {
        if value.isBad == true {
            return "недостоверное"
        }
        if value.isCalc == true {
            return "расчётное"
        }
        return nil
    }
}

/// Число в цвете и начертании значения. Единица — не здесь, а в подписи (ReadingLabel).
struct ReadingValueText: View {
    let value: DataValue
    let units: ServerUnits?
    var isStale = false

    var body: some View {
        Text(number)
            .monospacedDigit()
            .italic(value.isCalc == true)
            .foregroundStyle(ReadingStyle.color(for: value, isStale: isStale))
            // Длинное число в узком столбце чуть уменьшается, а не обрезается.
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            // Когда приходит новое значение, цифры меняются плавно, как в приложениях Apple.
            .contentTransition(.numericText())
            .animation(.default, value: value)
            .animation(.default, value: isStale)
            .accessibilityLabel(accessibilityText)
    }

    private var unit: String {
        return DataParameterCatalog.unit(for: value.dataParameter, serverUnits: units)
    }

    private var number: String {
        return TextFormatting.reading(value.value)
    }

    /// «Температура в подаче, 32,5 °C, расчётное» — VoiceOver читает полностью, даже в таблице.
    private var accessibilityText: String {
        var parts = [DataParameterCatalog.title(for: value.dataParameter),
                     unit.isEmpty ? number : "\(number) \(unit)"]
        if let note = ReadingStyle.accessibilityNote(for: value) {
            parts.append(note)
        }
        return parts.joined(separator: ", ")
    }
}

/// Таблица значений: слева величина с единицей («T, °C»), дальше столбцы («Подача», «Обратка», «Δ»
/// или «A», «B», «C»). В ячейках только числа — так они помещаются.
struct ReadingsTableView: View {
    let table: ReadingsLayout.Table
    let units: ServerUnits?
    let isStale: Bool

    var body: some View {
        // Каждая строка — HStack, где все столбцы (и название строки тоже) одинаково гибкие:
        // ширина делится поровну, и столбцы разных строк стоят ровно друг под другом.
        // (Grid на iOS 26 делил ширину иначе и уменьшал шрифт — проверено 2026-10-07.)
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // Над названиями строк — пусто.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 0)
                ForEach(table.columnTitles, id: \.self) { title in
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            // Заголовки столбцов VoiceOver не нужны: каждая ячейка читается полным названием.
            .accessibilityHidden(true)

            ForEach(table.rows, id: \.self) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    rowTitle(row)
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        Group {
                            if let cell {
                                ReadingValueText(value: cell, units: units, isStale: isStale)
                            } else {
                                // Такого значения прибор не прислал.
                                Text("—")
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func rowTitle(_ row: ReadingsLayout.Row) -> some View {
        let unit = row.firstValue.map { DataParameterCatalog.unit(for: $0.dataParameter, serverUnits: units) } ?? ""
        return ReadingLabel(symbol: row.symbol, unit: unit)
            // Название строки — такой же гибкий столбец, как столбцы с числами.
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Подпись значения: «T, °C», «f, Гц» — обозначение обычным цветом, единица серым.
/// Единица — всегда здесь, а не после числа (решение владельца 2026-10-07): одинаково в таблицах
/// и в одиночных значениях, а числа стоят ровно по правому краю.
struct ReadingLabel: View {
    let symbol: String
    let unit: String

    var body: some View {
        Group {
            if unit.isEmpty {
                Text(symbol)
            } else {
                Text(symbol) + Text(", \(unit)").foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        // VoiceOver читает полное название вместе со значением (см. ReadingValueText).
        .accessibilityHidden(true)
    }
}

/// Одиночные значения в два столбца: «Tхв, °C  5,00 │ Tнв, °C  −60,0». Между столбцами — вертикальный
/// разделитель на всю высоту блока (решение владельца 2026-10-07). Значения раскладываются по строкам:
/// первое — слева, второе — справа, третье — снова слева… Если два столбца не помещаются по ширине
/// (длинные обозначения или числа) — один столбец.
struct ReadingsPairsView: View {
    let values: [DataValue]
    let units: ServerUnits?
    let isStale: Bool

    var body: some View {
        // ViewThatFits — стандартный способ «покажи первый вариант, который помещается».
        ViewThatFits(in: .horizontal) {
            twoColumns
            column(values)
        }
        .padding(.vertical, 4)
    }

    /// Два столбца с разделителем. Divider внутри HStack стандартно становится вертикальным
    /// и тянется на всю высоту блока — даже если справа значений меньше.
    @ViewBuilder
    private var twoColumns: some View {
        if values.count < 2 {
            column(values)
        } else {
            let left = values.indices.filter { $0 % 2 == 0 }.map { values[$0] }
            let right = values.indices.filter { $0 % 2 == 1 }.map { values[$0] }
            HStack(alignment: .top, spacing: 12) {
                column(left)
                Divider()
                column(right)
            }
        }
    }

    /// Столбец строк «обозначение, единица … число». Высота строк одинаковая в обоих столбцах,
    /// поэтому строки левого и правого столбца стоят ровно друг напротив друга.
    private func column(_ items: [DataValue]) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, value in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ReadingLabel(symbol: DataParameterCatalog.symbol(for: value.dataParameter),
                                 unit: DataParameterCatalog.unit(for: value.dataParameter, serverUnits: units))
                    ReadingValueText(value: value, units: units, isStale: isStale)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// Подпись под разделом: что значат цвета. Только если такие значения есть в разделе;
/// сами слова показаны тем же цветом и начертанием — подпись сама служит образцом.
struct ReadingsLegend: View {
    let values: [DataValue]

    var body: some View {
        let hasCalculated = values.contains { $0.isCalc == true && $0.isBad != true }
        let hasBad = values.contains { $0.isBad == true }
        if hasCalculated || hasBad {
            legendText(hasCalculated: hasCalculated, hasBad: hasBad)
        }
    }

    private func legendText(hasCalculated: Bool, hasBad: Bool) -> Text {
        let calculated = Text("расчётные").italic().foregroundStyle(ReadingStyle.calculatedColor)
        let bad = Text("недостоверные").foregroundStyle(ReadingStyle.badColor)
        if hasCalculated && hasBad {
            return Text("Значения: \(calculated), \(bad).")
        }
        if hasCalculated {
            return Text("Значения \(calculated) — посчитаны сервером, а не измерены прибором.")
        }
        return Text("Значения \(bad) — прибор сообщил об ошибке измерения.")
    }
}
