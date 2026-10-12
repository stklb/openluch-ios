import SwiftUI
import Charts

// Экран «Графики и архив» точки учёта: часовые, суточные и месячные данные на графиках и в таблице.
// Открывается из вкладки «Данные» карточки точки. Данные и их загрузка — в PointArchiveModel
// (архив живёт в памяти, пока открыта карточка точки, на телефоне не сохраняется).
//
// Как устроен экран (решения владельца 2026-10-11, пробный экран обсуждали по шагам):
//   • вверху — период («Часы | Сутки | Месяцы») сегментами и параметр меню («Тепло», «Масса»…):
//     параметров много и у разных точек они разные, сегменты бы не поместились;
//   • основной график — подача и обратка плавными линиями с легендой; разность (ΔQ, ΔM, ΔT…) — на
//     отдельном маленьком графике под ним, со своей шкалой: она в десятки раз меньше и на общей
//     шкале прижималась бы к нулю. Графики листаются вбок вместе;
//   • на экране — один экран данных (сутки, 2 недели, год), остальное листается. Границы графика
//     заданы сразу и с запасом (ArchiveGrid); ещё не загруженные участки — серые, и как только график
//     остановился, загружается порция, которую видно (PointArchiveModel.show);
//   • над графиком — суммы (для температур и давлений — средние) видимой части; касание графика
//     показывает значения за этот час, день или месяц, повторное касание снимает выбор;
//   • неполный период (текущий месяц) — бледным пунктиром;
//   • под графиком — таблица видимой части. Значения — как везде в приложении: общее округление
//     (TextFormatting.reading), недостоверные — красно-бордовым, расчётные — зелёным курсивом;
//     единица — в подписи, а не после числа.
struct PointArchiveView: View {
    let point: MeasurePoint
    let model: PointArchiveModel

    @State private var period: ArchivePeriod = .days
    /// Выбранный пункт меню «Параметр»; nil — первый доступный.
    @State private var metricId: String?
    /// Левый край видимой части графика — меняется, когда листаем.
    @State private var scrollStart = Date()
    /// Выбранный касанием час, день или месяц — показываем его значения.
    @State private var selectedDate: Date?

    private let calendar = ArchiveDates.calendar
    private let russian = Locale(identifier: "ru_RU")

    var body: some View {
        List {
            Section {
                Picker("Период", selection: $period) {
                    ForEach(ArchivePeriod.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Параметр", selection: metricSelection) {
                    ForEach(metrics) { item in
                        Text(item.title).tag(item.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(metrics.isEmpty)
            }

            if let metric {
                chartSection(metric)
                statusSection
                tableSection(metric)
            } else {
                statusSection
                emptySection
            }
        }
        .listSectionSpacing(.compact)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Графики и архив")
                        .font(.headline)
                    Text(point.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .onChange(of: period) {
            selectedDate = nil
            scrollToEnd()
        }
        // Нашлись первые данные (например, после «Искать раньше») — показать самые свежие из них.
        .onChange(of: records.isEmpty) {
            if !records.isEmpty {
                scrollToLatestRecord()
            }
        }
        // Загружаем то, что видно, когда график остановился (0,3 с без сдвигов), а не на каждом сдвиге
        // пальца. .task(id:) перезапускается при каждом сдвиге — поэтому срабатывает только после остановки.
        // Так же — при открытии экрана и смене периода (первая, самая свежая порция).
        .task(id: VisibleWindow(period: period, start: scrollStart)) {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled {
                return
            }
            // Запас в полшага с обеих сторон: край графика бывает сдвинут на несколько часов
            // (прилипание при листании), и из-за этого не стоит качать целую соседнюю порцию.
            let halfStep = period.adding(1, to: scrollStart, calendar: calendar).timeIntervalSince(scrollStart) / 2
            model.show(period, from: scrollStart.addingTimeInterval(halfStep),
                       to: scrollStart.addingTimeInterval(period.visibleSeconds - halfStep))
        }
        .onAppear {
            scrollToEnd()
        }
        // Ушли с экрана графиков — загрузку прерываем (загруженное остаётся, пока открыта карточка точки).
        .onDisappear {
            model.stop()
        }
        .animation(.default, value: selectedDate)
    }

    // MARK: - Данные

    private var archive: PointArchiveModel.PeriodArchive {
        return model.archive(period)
    }

    private var records: [ArchiveRecord] {
        return archive.records
    }

    /// Пункты меню «Параметр» — те, по которым у точки есть данные.
    private var metrics: [ArchiveMetric] {
        return ArchiveMetrics.available(in: records)
    }

    private var metric: ArchiveMetric? {
        return metrics.first { $0.id == metricId } ?? metrics.first
    }

    /// Выбор в меню. Пункт запоминаем по id — при смене периода остаётся тот же («Тепло» и т.п.).
    private var metricSelection: Binding<String> {
        Binding(get: { metric?.id ?? "" },
                set: { metricId = $0 })
    }

    /// Записи, которые сейчас видны на графике.
    private var visibleRecords: [ArchiveRecord] {
        let end = scrollStart.addingTimeInterval(period.visibleSeconds)
        return records.filter { $0.date >= scrollStart && $0.date < end }
    }

    /// Единица параметра: °C, т, Гкал… (у всех параметров одного пункта меню — одна).
    private func unit(of metric: ArchiveMetric) -> String {
        guard let code = metric.codes.first else {
            return ""
        }
        return DataParameterCatalog.unit(for: code, serverUnits: model.units)
    }

    // MARK: - Листание

    /// Что видно на графике: период и левый край (ключ для загрузки видимого).
    private struct VisibleWindow: Equatable {
        let period: ArchivePeriod
        let start: Date
    }

    private var grid: ArchiveGrid {
        return model.grid(period)
    }

    /// Показать самые свежие данные (правый край графика).
    private func scrollToEnd() {
        scrollStart = grid.end.addingTimeInterval(-period.visibleSeconds)
    }

    /// Показать экран, который заканчивается самой свежей записью.
    private func scrollToLatestRecord() {
        guard let last = records.last?.date else {
            return
        }
        let end = period.adding(1, to: last, calendar: calendar)
        scrollStart = max(grid.start, end.addingTimeInterval(-period.visibleSeconds))
    }

    // MARK: - Итог над графиком

    @ViewBuilder
    private func summary(_ metric: ArchiveMetric) -> some View {
        if let selectedStart = selectedStart(metric) {
            selectionSummary(metric, start: selectedStart)
        } else {
            periodSummary(metric)
        }
    }

    /// Значения выбранного часа, дня или месяца — вместо итога видимой части.
    private func selectionSummary(_ metric: ArchiveMetric, start: Date) -> some View {
        let record = records.first { $0.date == start }
        let values = metric.codes.compactMap { record?.value(of: $0) }
        return VStack(alignment: .leading, spacing: 2) {
            Text(dateTitle(start))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            valuesLine(metric.codes.compactMap { code in
                record?.value(of: code).map { (code, $0.value) }
            })
            Text(selectionNote(metric, record: record, values: values))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func selectionNote(_ metric: ArchiveMetric, record: ArchiveRecord?, values: [DataValue]) -> String {
        var notes = [unit(of: metric)]
        if record?.isIncomplete == true {
            notes.append("неполные данные")
        }
        if values.contains(where: { $0.isBad == true }) {
            notes.append("есть недостоверные")
        }
        notes.append("коснитесь ещё раз, чтобы снять выбор")
        return notes.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Суммы (накапливаемые величины) или средние (температуры, давления) видимой части.
    private func periodSummary(_ metric: ArchiveMetric) -> some View {
        let visible = visibleRecords
        let totals: [(String, Double)] = metric.codes.compactMap { code in
            let values = visible.compactMap { $0.value(of: code)?.value }
            if values.isEmpty {
                return nil
            }
            let sum = values.reduce(0, +)
            return (code, metric.isAccumulated ? sum : sum / Double(values.count))
        }
        let what = metric.isAccumulated ? "сумма за период" : "средние за период"
        let unit = unit(of: metric)
        return VStack(alignment: .leading, spacing: 2) {
            Text(rangeTitle(visible))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            valuesLine(totals)
            Text(unit.isEmpty ? what : "\(unit), \(what)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// «T1 40,0   T2 32,1   ΔT 7,81» — в одну строку: не помещается — шрифт чуть уменьшается.
    /// Больше трёх значений (тарифы электроэнергии) — в две строки.
    private func valuesLine(_ items: [(String, Double)]) -> some View {
        Text(items.map { "\(ArchiveMetrics.symbol(for: $0.0)) \(TextFormatting.reading($0.1))" }
            .joined(separator: "   "))
            .font(.title3.bold())
            .monospacedDigit()
            .lineLimit(items.count > 3 ? 2 : 1)
            .minimumScaleFactor(0.6)
    }

    private func rangeTitle(_ visible: [ArchiveRecord]) -> String {
        guard let first = visible.first?.date, let last = visible.last?.date else {
            return "Нет данных за эти дни"
        }
        return "\(dateTitle(first)) – \(dateTitle(last))"
    }

    // MARK: - Графики

    private func chartSection(_ metric: ArchiveMetric) -> some View {
        Section {
            summary(metric)
            chart(metric, codes: metric.mainCodes, isSeparate: false)
                .frame(height: 260)
            ForEach(metric.separateCodes, id: \.self) { code in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(ArchiveMetrics.symbol(for: code)), \(unit(of: metric))")
                        .font(.subheadline.bold())
                        .foregroundStyle(ArchiveColors.color(for: code, index: 0))
                    chart(metric, codes: [code], isSeparate: true)
                        .frame(height: 140)
                }
            }
        } footer: {
            Text("Листайте график вбок — более ранние данные загрузятся сами. Коснитесь графика — покажутся значения за этот час, день или месяц. Пунктиром — неполный период.")
        }
    }

    /// Точка линии графика.
    private struct ChartPoint: Identifiable {
        /// Серия — отдельная линия: код параметра и номер куска (линия прерывается там, где записей нет),
        /// а у отрезка неполного периода — своя.
        let series: String
        let code: String
        let date: Date
        let value: Double

        var id: String {
            return "\(series) \(date.timeIntervalSince1970)"
        }
    }

    /// Линии полных периодов. Где записей нет (пропуск у прибора или участок не загружен), линия
    /// прерывается, а не соединяет соседние точки. Неполный период (текущий месяц) — отдельным бледным
    /// пунктиром от предыдущей точки: значение ещё будет расти, сравнивать его с полными месяцами нельзя.
    private func chartPoints(codes: [String]) -> (solid: [ChartPoint], incomplete: [ChartPoint]) {
        var solid: [ChartPoint] = []
        var incomplete: [ChartPoint] = []
        for code in codes {
            var previous: ChartPoint?
            var piece = 0
            for record in records {
                guard let value = record.value(of: code) else {
                    continue
                }
                if let previous, period.adding(1, to: previous.date, calendar: calendar) != record.date {
                    piece += 1
                }
                let point = ChartPoint(series: "\(code) \(piece)", code: code, date: record.date, value: value.value)
                if record.isIncomplete {
                    let series = "\(code) неполный \(record.date.timeIntervalSince1970)"
                    if let previous {
                        incomplete.append(ChartPoint(series: series, code: code, date: previous.date,
                                                     value: previous.value))
                    }
                    incomplete.append(ChartPoint(series: series, code: code, date: record.date, value: value.value))
                } else {
                    solid.append(point)
                }
                previous = point
            }
        }
        return (solid, incomplete)
    }

    /// График параметров. Основной и отдельный (Δ) листаются вместе: оба привязаны к одному
    /// `scrollStart` и одному выбранному часу (дню, месяцу).
    private func chart(_ metric: ArchiveMetric, codes: [String], isSeparate: Bool) -> some View {
        let points = chartPoints(codes: codes)
        let unit = unit(of: metric)
        return Chart {
            ForEach(points.solid) { point in
                LineMark(x: .value("Время", point.date, unit: period.calendarUnit),
                         y: .value(unit, point.value),
                         series: .value("Параметр", point.series))
                .foregroundStyle(by: .value("Параметр", ArchiveMetrics.legendTitle(for: point.code)))
                .interpolationMethod(.monotone)
            }
            ForEach(points.incomplete) { point in
                LineMark(x: .value("Время", point.date, unit: period.calendarUnit),
                         y: .value(unit, point.value),
                         series: .value("Параметр", point.series))
                .foregroundStyle(by: .value("Параметр", ArchiveMetrics.legendTitle(for: point.code)))
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                .opacity(0.5)
            }

            // Ещё не загруженные участки рядом с видимой частью — серые; та, что грузится, — с подписью.
            ForEach(unloadedPortions, id: \.self) { index in
                RectangleMark(xStart: .value("Время", grid.first(ofPortion: index)),
                              xEnd: .value("Время", grid.first(ofPortion: index - 1)))
                    .foregroundStyle(Color.secondary.opacity(0.12))
                    .annotation(position: .overlay) {
                        if !isSeparate && archive.loadingPortion == index {
                            Text("Загрузка…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
            }

            // Разность колеблется около нуля — ноль отмечаем линией.
            if isSeparate {
                RuleMark(y: .value(unit, 0))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }

            // Выбранный час (день, месяц) — вертикальная линия; его значения — в шапке над графиком.
            if let selectedStart = selectedStart(metric) {
                RuleMark(x: .value("Время", selectedStart, unit: period.calendarUnit))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
        }
        .chartForegroundStyleScale(
            domain: codes.map { ArchiveMetrics.legendTitle(for: $0) },
            range: codes.enumerated().map { ArchiveColors.color(for: $0.element, index: $0.offset) }
        )
        // У отдельного графика легенда не нужна — название над ним.
        .chartLegend(isSeparate ? .hidden : .visible)
        .chartXScale(domain: grid.start...grid.end)
        // Шкала значений — по видимой части, иначе зимние значения «приплющат» летние.
        .chartYScale(domain: yDomain(codes: codes, includesZero: isSeparate))
        .chartXAxis { xAxis }
        // Подписи шкалы значений одной ширины — чтобы дни основного и отдельного графиков
        // стояли точно друг под другом.
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(number.formatted(.number.locale(russian)))
                            .frame(width: 40, alignment: .leading)
                    }
                }
            }
        }
        // Листание: на экране — сутки, 2 недели или год, остальное за краем.
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: period.visibleSeconds)
        .chartScrollPosition(x: $scrollStart)
        .chartScrollTargetBehavior(scrollSnapping)
        .chartGesture { chartProxy in
            // Касание выбирает час (день, месяц); повторное касание того же места снимает выбор.
            SpatialTapGesture().onEnded { tap in
                let touched: Date? = chartProxy.value(atX: tap.location.x)
                if let touched, let selectedDate,
                   calendar.isDate(touched, equalTo: selectedDate, toGranularity: period.calendarUnit) {
                    self.selectedDate = nil
                } else {
                    selectedDate = touched
                }
            }
        }
    }

    /// Незагруженные порции рядом с видимой частью графика (на экран в обе стороны) — для серых участков.
    /// Только рядом: серых прямоугольников на все 3 года назад графику рисовать незачем.
    private var unloadedPortions: [Int] {
        let from = scrollStart.addingTimeInterval(-period.visibleSeconds)
        let to = scrollStart.addingTimeInterval(2 * period.visibleSeconds)
        return grid.portions(from: from, to: to).filter { !archive.loadedPortions.contains($0) }
    }

    /// Шкала значений: по видимой части и по одной точке за краями экрана (линия к ним уходит
    /// из видимой части и не должна обрезаться). У разности — всегда вместе с нулём.
    private func yDomain(codes: [String], includesZero: Bool) -> ClosedRange<Double> {
        let before = period.adding(-1, to: scrollStart, calendar: calendar)
        let visibleEnd = scrollStart.addingTimeInterval(period.visibleSeconds)
        let after = period.adding(1, to: visibleEnd, calendar: calendar)
        var values: [Double] = []
        for record in records where record.date >= before && record.date < after {
            for code in codes {
                if let value = record.value(of: code) {
                    values.append(value.value)
                }
            }
        }
        if includesZero {
            values.append(0)
        }
        guard let low = values.min(), let high = values.max(), high > low else {
            let value = values.first ?? 0
            return (value - 1)...(value + 1)
        }
        let margin = (high - low) * 0.1
        return (low - margin)...(high + margin)
    }

    /// Подписи оси времени — только опорные, чтобы не слипались. Текст — по-русски, как везде в приложении.
    @AxisContentBuilder
    private var xAxis: some AxisContent {
        switch period {
        case .hours:
            AxisMarks(values: .stride(by: .hour, count: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).locale(russian)))
                    }
                }
            }
        case .days:
            AxisMarks(values: .stride(by: .day, count: 2)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.day().locale(russian)))
                    }
                }
            }
        case .months:
            AxisMarks(values: .stride(by: .month, count: 2)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.month(.abbreviated).locale(russian)))
                    }
                }
            }
        }
    }

    /// Листание «прилипает» к началу часа, суток или месяца, а большим рывком — к полуночи,
    /// понедельнику или январю.
    private var scrollSnapping: ValueAlignedChartScrollTargetBehavior {
        switch period {
        case .hours:
            return .valueAligned(matching: DateComponents(minute: 0), majorAlignment: .matching(DateComponents(hour: 0)))
        case .days:
            return .valueAligned(matching: DateComponents(hour: 0), majorAlignment: .matching(DateComponents(weekday: 2)))
        case .months:
            return .valueAligned(matching: DateComponents(day: 1), majorAlignment: .matching(DateComponents(month: 1)))
        }
    }

    /// Начало выбранного часа (дня, месяца) — если касание попало туда, где есть данные.
    private func selectedStart(_ metric: ArchiveMetric) -> Date? {
        guard let selectedDate,
              let interval = calendar.dateInterval(of: period.calendarUnit, for: selectedDate) else {
            return nil
        }
        let hasData = records.contains { record in
            interval.contains(record.date) && metric.codes.contains { record.value(of: $0) != nil }
        }
        return hasData ? interval.start : nil
    }

    // MARK: - Загрузка и пустые состояния

    /// Строка о загрузке или ошибке — только когда есть что сказать.
    @ViewBuilder
    private var statusSection: some View {
        let archive = self.archive
        if let progress = archive.progress {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(progress.isWaitingForNetwork ? "Нет сети, ждём подключения…" : "Загрузка данных…")
                        Text(TextFormatting.downloadProgress(progress))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if let errorMessage = archive.errorMessage {
            Section {
                Label("Не удалось загрузить: \(errorMessage)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Повторить") {
                    model.retry(period)
                }
            }
        }
    }

    /// Данных для графиков ещё нет: за последние две недели (сутки, год) пусто — прибор мог давно
    /// не выходить на связь. Тогда можно поискать раньше — по одной порции за нажатие.
    @ViewBuilder
    private var emptySection: some View {
        let archive = self.archive
        if !archive.loadedPortions.isEmpty && !archive.isLoading && archive.errorMessage == nil {
            Section {
                if records.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Данных нет")
                        if let oldest = archive.loadedPortions.max() {
                            Text("Проверено с \(dateTitle(grid.first(ofPortion: oldest)))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if (archive.loadedPortions.max() ?? 0) + 1 < period.maxPortions {
                        Button("Искать раньше") {
                            model.loadEarlierPortion(period)
                        }
                    }
                } else {
                    Text("Для параметров этой точки графики пока не показываются.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Таблица

    private func tableSection(_ metric: ArchiveMetric) -> some View {
        let visible = visibleRecords.reversed()
        let unit = unit(of: metric)
        let shownValues = visible.flatMap { record in metric.codes.compactMap { record.value(of: $0) } }
        return Section {
            if visible.isEmpty {
                Text("Нет данных за эти дни")
                    .foregroundStyle(.secondary)
            } else {
                // Заголовки столбцов. Столбцы значений одинаково гибкие — стоят ровно друг под другом.
                HStack(spacing: 8) {
                    Color.clear
                        .frame(width: dateColumnWidth, height: 0)
                    ForEach(metric.codes, id: \.self) { code in
                        Text(ArchiveMetrics.symbol(for: code))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

                ForEach(Array(visible), id: \.date) { record in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(shortDateTitle(record.date))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if record.isIncomplete {
                                Text("неполный")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: dateColumnWidth, alignment: .leading)
                        ForEach(metric.codes, id: \.self) { code in
                            Group {
                                if let value = record.value(of: code) {
                                    ReadingValueText(value: value, units: model.units)
                                } else {
                                    Text("—")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
        } header: {
            Text(unit.isEmpty ? "Таблица видимого периода" : "Таблица видимого периода, \(unit)")
        } footer: {
            ReadingsLegend(values: shownValues)
        }
    }

    /// Ширина столбца даты: «10.10 14:00», «Сб, 10.10», «окт. 2026 г.».
    private var dateColumnWidth: CGFloat {
        return 96
    }

    // MARK: - Даты

    /// Короткая дата для таблицы: «10.10 14:00», «Сб, 10.10», «окт. 2026 г.».
    private func shortDateTitle(_ date: Date) -> String {
        switch period {
        case .hours:
            return date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).hour().minute().locale(russian))
        case .days:
            return date.formatted(.dateTime.weekday(.short).day(.twoDigits).month(.twoDigits).locale(russian))
        case .months:
            return date.formatted(.dateTime.month(.abbreviated).year().locale(russian))
        }
    }

    /// Дата для шапки над графиком: «10 окт., 14:00», «Сб, 10 окт.», «октябрь 2026 г.».
    private func dateTitle(_ date: Date) -> String {
        switch period {
        case .hours:
            return date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(russian))
        case .days:
            return date.formatted(.dateTime.day().month(.abbreviated).weekday(.short).locale(russian))
        case .months:
            return date.formatted(.dateTime.month(.wide).year().locale(russian))
        }
    }
}

/// Цвета линий: подача — красная, обратка — синяя, разность — зелёная (зелёный везде означает
/// разность), улица — бирюзовая; остальные (тарифы электроэнергии…) — по порядку из палитры.
enum ArchiveColors {
    private static let palette: [Color] = [.orange, .purple, .indigo, .brown, .pink, .mint, .cyan, .yellow, .gray]

    static func color(for code: String, index: Int) -> Color {
        if code.hasSuffix("_in") {
            return .red
        }
        if code.hasSuffix("_out") {
            return .blue
        }
        if code.hasSuffix("_delta") {
            return .green
        }
        if code == "T_outdoor" || code.hasSuffix("_cw") {
            return .teal
        }
        return palette[index % palette.count]
    }
}

/// Переход к экрану графиков. Несёт с собой модель архива, которой владеет карточка точки:
/// так архив живёт, пока открыта карточка, и не загружается заново при каждом входе на экран графиков.
struct PointArchiveRoute: Hashable {
    let point: MeasurePoint
    let model: PointArchiveModel

    static func == (left: PointArchiveRoute, right: PointArchiveRoute) -> Bool {
        return left.point.id == right.point.id && left.model === right.model
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(point.id)
        hasher.combine(ObjectIdentifier(model))
    }
}
