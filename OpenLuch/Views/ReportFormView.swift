import SwiftUI

// Окно «Отчёт» (открывается кнопкой «Сформировать отчёт» в карточке точки, вкладка «Данные»):
// выбор отчёта, типа данных и периода → «Сформировать» → готовый PDF открывается здесь же.
// Данные и загрузка — PointReportsModel; правила периода — ReportPeriod.
//
// Последние выбранные отчёт, тип данных и вариант периода запоминаются (@AppStorage — маленькие
// настройки приложения в UserDefaults): обычно человек раз за разом формирует один и тот же отчёт.
struct ReportFormView: View {
    @Environment(\.dismiss) private var dismiss

    let point: MeasurePoint
    let model: PointReportsModel

    @AppStorage("report.lastReportId") private var lastReportId = 0
    @AppStorage("report.dataType") private var dataType: ReportDataType = .day
    @AppStorage("report.periodPreset") private var preset: ReportPeriod.Preset = .lastMonth

    @State private var selectedReportId: Int?
    @State private var period = ReportPeriod.make(.lastMonth, today: Date(), calendar: ReportPeriod.calendar)
        ?? ReportPeriod(firstDay: Date(), lastDay: Date())
    /// Идущее формирование отчёта — чтобы его можно было отменить.
    @State private var generationTask: Task<Void, Never>?
    /// Готовый отчёт, который показываем (переход на экран просмотра PDF).
    @State private var openedReport: SavedReport?

    private let calendar = ReportPeriod.calendar

    var body: some View {
        NavigationStack {
            Form {
                reportSection
                dataTypeSection
                periodSection
                generateSection
            }
            .navigationTitle("Отчёт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Заголовок: «Отчёт» и название точки под ним.
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Отчёт")
                            .font(.headline)
                        Text(point.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") {
                        dismiss()
                    }
                }
            }
            .navigationDestination(item: $openedReport) { report in
                ReportViewerView(report: report, onDone: {
                    dismiss()
                })
            }
        }
        .onAppear {
            // «Свои даты» не запоминаем — в следующий раз начинаем с прошлого месяца.
            if preset == .custom {
                preset = .lastMonth
            }
            applyPreset(preset)
            chooseDefaultReport()
        }
        .onChange(of: model.cachedList?.reports) {
            chooseDefaultReport()
        }
        // Список отчётов: при первом открытии — загрузка (закрыли окно — загрузка отменится).
        .task {
            await model.refreshListIfNeeded()
        }
        // Отчёт сформирован и скачан — вибрация «успех»: на медленной связи это может занять
        // минуту, и человек, отвлёкшийся от экрана, узнает, что можно смотреть.
        .sensoryFeedback(.success, trigger: openedReport) { _, newReport in
            newReport != nil
        }
        // Окно закрыли посреди формирования — прерываем его.
        .onDisappear {
            generationTask?.cancel()
        }
    }

    // MARK: - Какой отчёт

    @ViewBuilder
    private var reportSection: some View {
        Section {
            if let reports = model.cachedList?.reports {
                if reports.isEmpty {
                    Text("Точке не назначено ни одной ведомости параметров.")
                        .foregroundStyle(.secondary)
                } else {
                    // Названия отчётов длинные — список с галочкой читается лучше выпадающего меню.
                    Picker("Отчёт", selection: $selectedReportId) {
                        ForEach(reports) { report in
                            Text(report.title)
                                .tag(Optional(report.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(model.isGenerating)
                }
                listRefreshRow
            } else if let progress = model.listProgress {
                // Первая загрузка: сохранённого списка нет.
                DownloadProgressView(progress: progress)
            } else if let errorMessage = model.listErrorMessage {
                Label("Не удалось загрузить список отчётов: \(errorMessage)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Повторить") {
                    Task {
                        await model.refreshList()
                    }
                }
            } else {
                // Сохранённый список читается (доли секунды) или загрузка вот-вот начнётся.
                ProgressView()
            }
        } header: {
            Text("Отчёт")
        } footer: {
            if let reportFooter {
                Text(reportFooter)
            }
        }
    }

    /// Обновление уже сохранённого списка: ход загрузки, ошибка или кнопка «Обновить».
    @ViewBuilder
    private var listRefreshRow: some View {
        if let progress = model.listProgress {
            DownloadProgressView(progress: progress)
        } else {
            if let errorMessage = model.listErrorMessage {
                Label("Не удалось обновить список: \(errorMessage)", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button {
                Task {
                    await model.refreshList()
                }
            } label: {
                LabeledContent {
                    if let bytes = model.cachedList?.responseBytes {
                        Text("≈ " + TextFormatting.bytes(Int64(bytes)))
                    }
                } label: {
                    Text("Обновить список отчётов")
                        .foregroundStyle(.tint)
                }
            }
            .disabled(model.isGenerating)
        }
    }

    /// Подпись под списком отчётов. Когда отчёты есть — без подписи (решение владельца 2026-10-07):
    /// пояснять нужно только долгую первую загрузку и пустой список.
    private var reportFooter: String? {
        guard let cached = model.cachedList else {
            return "Список отчётов загружается один раз и сохраняется на устройстве. Ответ сервера большой — на медленной связи это может занять пару минут."
        }
        if cached.reports.isEmpty {
            let updated = "Список сохранён на устройстве, обновлён \(TextFormatting.updatedAt(cached.savedAt))."
            return "Назначить отчёты точке может администратор в ЛЭРС УЧЁТ. Здесь формируются только ведомости параметров (акты — нет). " + updated
        }
        return nil
    }

    // MARK: - Тип данных

    private var dataTypeSection: some View {
        Section {
            Picker("Данные", selection: $dataType) {
                ForEach(ReportDataType.allCases, id: \.self) { type in
                    Text(type.title)
                        .tag(type)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isGenerating)
        } header: {
            Text("Данные")
        } footer: {
            // Часовой отчёт за долгий период — десятки страниц: на медленной связи это минуты загрузки.
            if dataType == .hour && period.dayCount(calendar: calendar) > 31 {
                Text("Часовой отчёт больше чем за месяц получится очень большим. Возможно, лучше выбрать суточные данные.")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Период

    private var periodSection: some View {
        Section {
            Picker("Период", selection: presetBinding) {
                ForEach(ReportPeriod.Preset.allCases, id: \.self) { preset in
                    Text(preset.title)
                        .tag(preset)
                }
            }
            DatePicker("С", selection: firstDayBinding, in: ...Date(), displayedComponents: .date)
            DatePicker("По", selection: lastDayBinding, in: ...Date(), displayedComponents: .date)
        } header: {
            Text("Период")
        } footer: {
            if period.isValid(calendar: calendar) {
                Text(periodFooter)
            } else {
                Text("Дата начала позже даты окончания.")
                    .foregroundStyle(.orange)
            }
        }
        .disabled(model.isGenerating)
    }

    private var periodFooter: String {
        let summary = period.summary(for: dataType, calendar: calendar)
        if dataType == .month {
            return "Месяцы: \(summary). Время — по часам точки учёта."
        }
        return "\(summary). Время — по часам точки учёта."
    }

    /// Выбор готового варианта сразу подставляет даты.
    private var presetBinding: Binding<ReportPeriod.Preset> {
        Binding {
            preset
        } set: { newPreset in
            preset = newPreset
            applyPreset(newPreset)
        }
    }

    /// Дату поменяли вручную — вариант периода становится «Свои даты».
    private var firstDayBinding: Binding<Date> {
        Binding {
            period.firstDay
        } set: { newDate in
            period.firstDay = newDate
            preset = .custom
        }
    }

    private var lastDayBinding: Binding<Date> {
        Binding {
            period.lastDay
        } set: { newDate in
            period.lastDay = newDate
            preset = .custom
        }
    }

    private func applyPreset(_ preset: ReportPeriod.Preset) {
        if let newPeriod = ReportPeriod.make(preset, today: Date(), calendar: calendar) {
            period = newPeriod
        }
    }

    // MARK: - Сформировать

    @ViewBuilder
    private var generateSection: some View {
        Section {
            if let stage = model.generationStage {
                switch stage {
                case .preparing(let isWaitingForNetwork):
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(isWaitingForNetwork ? "Нет сети, ждём подключения…" : "Сервер формирует отчёт…")
                            .foregroundStyle(.secondary)
                    }
                case .downloading(let progress):
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Загрузка отчёта")
                        DownloadProgressView(progress: progress)
                    }
                }
                Button("Отмена", role: .cancel) {
                    generationTask?.cancel()
                }
            } else {
                Button {
                    startGeneration()
                } label: {
                    Label("Сформировать", systemImage: "doc.text")
                }
                .disabled(!canGenerate)
                if let errorMessage = model.generationErrorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        } footer: {
            Text("Отчёт в формате PDF формирует сервер. Готовый отчёт сохраняется на устройстве.")
        }
    }

    private var selectedReport: PointReport? {
        return model.cachedList?.reports.first { $0.id == selectedReportId }
    }

    private var canGenerate: Bool {
        return selectedReport != nil && period.isValid(calendar: calendar)
    }

    private func startGeneration() {
        guard let report = selectedReport else {
            return
        }
        lastReportId = report.id
        let dataType = self.dataType
        let period = self.period
        generationTask = Task {
            if let saved = await model.generate(report: report, dataType: dataType, period: period) {
                openedReport = saved
            }
        }
    }

    /// Какой отчёт выбрать сразу: прошлый выбранный (если он есть у этой точки), иначе первый.
    private func chooseDefaultReport() {
        guard let reports = model.cachedList?.reports, !reports.isEmpty else {
            return
        }
        if let selectedReportId, reports.contains(where: { $0.id == selectedReportId }) {
            return
        }
        if reports.contains(where: { $0.id == lastReportId }) {
            selectedReportId = lastReportId
        } else {
            selectedReportId = reports.first?.id
        }
    }
}
