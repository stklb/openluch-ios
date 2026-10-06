import Foundation

// Как компактно разложить последние данные точки на экране (решение владельца 2026-10-07):
// - тепло и вода — таблица «Подача / Обратка / Δ» (Δ — разность, как в официальном клиенте ЛЭРС): место параметра видно по окончанию его кода
//   (T_in → подача, T_out → обратка, T_delta → разность);
// - электричество — таблица по фазам «A / B / C» (UA, UB, UC → строка «U»);
// - всё остальное (Tхв, Tнв, ВНР, суммы по фазам, энергия по тарифам…) — по одному значению,
//   на экране по два в строку.
// Порядок строк — как пришли значения (а они уже в порядке, выбранном в ЛЭРС для точки).
nonisolated struct ReadingsLayout {

    /// Таблица: заголовки столбцов и строки величин.
    struct Table: Hashable {
        let columnTitles: [String]
        let rows: [Row]
    }

    /// Строка таблицы: величина («T», «U») и её значения по столбцам.
    struct Row: Hashable {
        let symbol: String
        /// По одной ячейке на столбец; nil — такого значения прибор не прислал.
        let cells: [DataValue?]

        /// Значение, по которому берём единицу измерения строки (у всех ячеек строки она одна).
        var firstValue: DataValue? {
            return cells.compactMap { $0 }.first
        }
    }

    let tables: [Table]
    /// Значения, не попавшие ни в одну таблицу.
    let singles: [DataValue]

    init(values: [DataValue]) {
        var pipes = TableBuilder()
        var phases = TableBuilder()
        for (index, value) in values.enumerated() {
            guard let place = Self.place(for: value.dataParameter) else {
                continue
            }
            switch place.kind {
            case .pipes:
                pipes.put(index: index, symbol: place.symbol, column: place.column)
            case .phases:
                phases.put(index: index, symbol: place.symbol, column: place.column)
            }
        }

        // Строка «подача/обратка» нужна, только если есть подача или обратка: одинокая разность
        // (например, Q — потреблённое тепло в показаниях счётчиков) показывается сама по себе.
        let pipeRows = pipes.rows { cells in cells[0] != nil || cells[1] != nil }
        // Столбец «Δ» (разность) — только если разность есть хотя бы у одной величины.
        let hasDelta = pipeRows.contains { $0.cells[2] != nil }
        let pipeColumnCount = hasDelta ? 3 : 2
        let phaseRows = phases.rows { _ in true }

        var tables: [Table] = []
        var placedIndices: Set<Int> = []
        if !pipeRows.isEmpty {
            tables.append(Table(columnTitles: Array(["Подача", "Обратка", "Δ"].prefix(pipeColumnCount)),
                                rows: pipeRows.map { row in
                                    Row(symbol: row.symbol,
                                        cells: row.cells.prefix(pipeColumnCount).map { $0.map { values[$0] } })
                                }))
            placedIndices.formUnion(pipeRows.flatMap { $0.cells.compactMap { $0 } })
        }
        if !phaseRows.isEmpty {
            tables.append(Table(columnTitles: ["A", "B", "C"],
                                rows: phaseRows.map { row in
                                    Row(symbol: row.symbol, cells: row.cells.map { $0.map { values[$0] } })
                                }))
            placedIndices.formUnion(phaseRows.flatMap { $0.cells.compactMap { $0 } })
        }
        self.tables = tables
        self.singles = values.indices.filter { !placedIndices.contains($0) }.map { values[$0] }
    }

    // MARK: - Где место параметра

    private enum Kind {
        case pipes
        case phases
    }

    private struct Place {
        let kind: Kind
        /// Обозначение строки таблицы.
        let symbol: String
        let column: Int
    }

    /// Величины, которые бывают в подаче и обратке: температура, давление, масса, объём, тепло.
    private static let pipeQuantities: Set<String> = ["T", "P", "M", "V", "Q"]

    /// Окончание кода → столбец таблицы «Подача / Обратка / Δ».
    private static let pipeSuffixes: [(suffix: String, column: Int)] = [("_in", 0), ("_out", 1), ("_delta", 2)]

    /// Электрические величины по фазам: начало кода → обозначение строки.
    /// Код фазы — начало + буква фазы: "UA", "CosPhiB", "PhiUIC".
    /// Суммы по всем фазам ("U", "Pp", "CosPhi"…) и углы между фазами ("PhiUAB") в таблицу не входят.
    private static let phaseQuantities: [(prefix: String, symbol: String)] = [
        ("U", "U"), ("I", "I"), ("P", "P"), ("Q", "Q"), ("S", "S"), ("CosPhi", "cos φ"), ("PhiUI", "φ U–I")
    ]

    private static func place(for code: String) -> Place? {
        for (suffix, column) in pipeSuffixes where code.hasSuffix(suffix) {
            let quantity = String(code.dropLast(suffix.count))
            if pipeQuantities.contains(quantity) {
                return Place(kind: .pipes, symbol: quantity, column: column)
            }
        }
        for (prefix, symbol) in phaseQuantities {
            for (column, phase) in ["A", "B", "C"].enumerated() where code == prefix + phase {
                return Place(kind: .phases, symbol: symbol, column: column)
            }
        }
        return nil
    }

    /// Собирает строки таблицы: обозначение → номера значений по столбцам.
    private struct TableBuilder {
        struct BuilderRow {
            let symbol: String
            var cells: [Int?] = [nil, nil, nil]
        }

        private var rowsInOrder: [BuilderRow] = []

        mutating func put(index: Int, symbol: String, column: Int) {
            if let rowIndex = rowsInOrder.firstIndex(where: { $0.symbol == symbol }) {
                // Если значение для этой ячейки уже есть (сервер прислал параметр дважды),
                // второе останется среди одиночных — ничего не потеряется.
                if rowsInOrder[rowIndex].cells[column] == nil {
                    rowsInOrder[rowIndex].cells[column] = index
                }
            } else {
                var row = BuilderRow(symbol: symbol)
                row.cells[column] = index
                rowsInOrder.append(row)
            }
        }

        func rows(where isKept: ([Int?]) -> Bool) -> [BuilderRow] {
            return rowsInOrder.filter { isKept($0.cells) }
        }
    }
}
