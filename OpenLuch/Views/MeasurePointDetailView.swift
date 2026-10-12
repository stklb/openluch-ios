import SwiftUI

// Карточка точки учёта. В заголовке экрана — значок системы и название точки.
// Вверху — самое главное о точке (видно всегда, максимально коротко), под ним переключатель
// подвкладок (решение владельца 2026-10-03, карточка стала длинной):
//   • «Данные»  — последние данные и интеграторы (маленькие запросы при открытии карточки,
//                 см. PointReadingsModel), под ними — ссылка «Графики и архив» (PointArchiveView),
//                 ручной опрос и PDF-отчёты: «Сформировать отчёт» и сохранённые отчёты точки
//                 (см. PointReportsModel);
//   • «Датчики» — устройство опроса и датчики по магистралям. Запрос датчиков тяжёлый (~365 КБ),
//                 поэтому он делается, только когда пользователь открыл эту вкладку (см. PointSensorsModel);
//   • «Связь»   — канал связи точки и подключения её прибора опроса (из кэша, без запросов).
// Нештатные ситуации — не подвкладка: если точка в состоянии «Ошибка» или «Предупреждение», строка
// «Состояние» вверху становится ссылкой (со стрелкой ›) на экран НС (решение владельца 2026-10-04).
struct MeasurePointDetailView: View {
    @Environment(DataStore.self) private var dataStore
    @Environment(AppSession.self) private var session

    let point: MeasurePoint

    /// Подвкладки карточки.
    enum PointTab: Hashable {
        case data
        case sensors
        case connection
    }

    @State private var selectedTab: PointTab = .data

    /// Модель последних данных. Создаётся при первом показе карточки (нужна сессия из окружения).
    @State private var readingsModel: PointReadingsModel?
    /// Модель датчиков точки (тяжёлый запрос, хранится в кэше — см. PointSensorsModel).
    @State private var sensorsModel: PointSensorsModel?
    /// true — вкладку «Датчики» уже открывали: датчики можно загружать.
    /// Отдельный флаг, а не сама выбранная вкладка, — чтобы загрузка НЕ прерывалась,
    /// если пользователь переключился на другую вкладку, пока датчики грузятся.
    @State private var sensorsRequested = false
    /// Модель отчётов точки: список отчётов, формирование, сохранённые PDF.
    @State private var reportsModel: PointReportsModel?
    /// Открыто окно «Отчёт».
    @State private var isReportFormShown = false
    /// Ручной опрос прибора и задача, которая ждёт его результата (отменяется, когда уходим с карточки).
    @State private var pollModel: PointPollModel?
    @State private var pollTask: Task<Void, Never>?
    /// Архив потребления для экрана «Графики и архив». Живёт, пока открыта карточка: ушли с карточки —
    /// архив удаляется из памяти (на телефоне не сохраняется — прибор могут переопросить).
    /// Сам архив загружается, только когда пользователь открыл экран графиков.
    @State private var archiveModel: PointArchiveModel?

    var body: some View {
        List {
            headerSection

            Section {
                Picker("Раздел", selection: $selectedTab) {
                    Text("Данные").tag(PointTab.data)
                    Text("Датчики").tag(PointTab.sensors)
                    Text("Связь").tag(PointTab.connection)
                }
                .pickerStyle(.segmented)
                // Переключатель — без белой подложки строки списка, на всю ширину.
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            switch selectedTab {
            case .data:
                if let readingsModel {
                    PointReadingsSections(model: readingsModel, selectedParameterIds: point.selectedParamsList)
                }
                // Графики — сразу под последними данными: «посмотрел текущие — захотел историю».
                if let archiveModel {
                    Section {
                        NavigationLink(value: PointArchiveRoute(point: point, model: archiveModel)) {
                            Label("Графики и архив", systemImage: "chart.xyaxis.line")
                        }
                    }
                }
                // Опрос — только у точек, привязанных к прибору (у расчётных точек опрашивать нечего),
                // и только если у учётной записи есть право на ручной опрос.
                if point.deviceId != nil, session.isAllowed(.manualPoll), let pollModel {
                    PointPollSection(model: pollModel, onStart: startPoll, onStop: stopPoll)
                }
                // Без права формировать отчёты кнопки нет, но сохранённые раньше отчёты видны.
                if let reportsModel, session.isAllowed(.printReport) || !reportsModel.savedReports.isEmpty {
                    PointReportsSection(model: reportsModel, canCreateReport: session.isAllowed(.printReport)) {
                        isReportFormShown = true
                    }
                }
            case .sensors:
                sensorsTab
            case .connection:
                connectionTab
            }
        }
        // Небольшие отступы между разделами — верхний блок и переключатель занимают меньше места.
        .listSectionSpacing(.compact)
        .navigationTitle(point.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Заголовок экрана: значок системы + название (до двух строк — длинные названия точек
            // бывают вроде «Электроснабжение, жилье (ввод 1), (электрощитовая)»).
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    SystemIcon(point: point)
                    // Шрифт чуть мельче обычного заголовка — чтобы в панель помещались две строки.
                    Text(point.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Кнопка «Обновить» — только для показаний (вкладка «Данные»).
            if selectedTab == .data {
                ToolbarItem(placement: .topBarTrailing) {
                    // Индикатор загрузки — в строке над данными; здесь кнопка просто недоступна, пока идёт загрузка.
                    Button {
                        Task {
                            await readingsModel?.refresh()
                        }
                    } label: {
                        Label("Обновить данные", systemImage: "arrow.clockwise")
                    }
                    .disabled(readingsModel == nil || readingsModel?.isLoading == true)
                }
            }
        }
        .sheet(isPresented: $isReportFormShown) {
            if let reportsModel {
                ReportFormView(point: point, model: reportsModel)
            }
        }
        // Окно отчёта закрыли — список сохранённых отчётов мог измениться.
        .onChange(of: isReportFormShown) {
            if !isReportFormShown {
                Task {
                    await reportsModel?.reloadSavedReports()
                }
            }
        }
        // Ушли с карточки — перестаём ждать результат опроса (сам опрос на сервере продолжится).
        .onDisappear {
            stopPoll()
        }
        .onChange(of: selectedTab) {
            if selectedTab == .sensors {
                sensorsRequested = true
            }
        }
        // При открытии: показать сохранённые данные и загрузить свежие показания.
        // Если пользователь уйдёт с карточки, .task отменится — и загрузка тоже.
        .task {
            if readingsModel == nil {
                readingsModel = PointReadingsModel(pointId: point.id, session: session)
            }
            if sensorsModel == nil {
                sensorsModel = PointSensorsModel(pointId: point.id, session: session)
            }
            if pollModel == nil {
                pollModel = PointPollModel(pointId: point.id, session: session)
            }
            if archiveModel == nil {
                archiveModel = PointArchiveModel(pointId: point.id, session: session)
            }
            if reportsModel == nil {
                // Датчики приходят и вместе со списком отчётов — модель отчётов отдаст их модели датчиков.
                reportsModel = PointReportsModel(pointId: point.id, session: session, sensorsModel: sensorsModel)
            }
            // Сохранённые датчики читаем сразу (без сети) — вкладка «Датчики» откроется мгновенно.
            await sensorsModel?.loadCache()
            // Сохранённые отчёты точки — тоже без сети (сам список отчётов сервера качается только в окне «Отчёт»).
            await reportsModel?.loadCache()
            await readingsModel?.start()
        }
        // Датчики — только после того, как пользователь открыл их вкладку.
        .task(id: sensorsRequested) {
            if sensorsRequested {
                await sensorsModel?.refreshIfNeeded()
            }
        }
    }

    // MARK: - Нештатные ситуации

    /// «Состояние» — ссылка на нештатные ситуации только при ошибке или предупреждении
    /// и если у учётной записи есть право их просматривать.
    private var hasIncidentsLink: Bool {
        return (point.itemState == .error || point.itemState == .warning) && session.isAllowed(.viewIncident)
    }

    // MARK: - Опрос прибора

    private func startPoll() {
        guard let pollModel, let readingsModel else {
            return
        }
        pollTask = Task {
            await pollModel.poll(readings: readingsModel)
        }
    }

    private func stopPoll() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Главное о точке (видно всегда)

    /// Только самое нужное (решение владельца: блок максимально компактный). Название и система —
    /// в заголовке экрана; ресурс не показываем.
    private var headerSection: some View {
        let node = point.nodeId.flatMap { dataStore.node(withId: $0) }

        return Section {
            // Ошибка или предупреждение — строка становится стандартной ссылкой (стрелка › справа)
            // на экран нештатных ситуаций точки. В норме — просто строка.
            // Ссылка — «по значению», как и все остальные переходы: если смешать в одном стеке
            // NavigationLink { экран } и NavigationLink(value:), то при нажатии на НС экран
            // подробностей открывался и тут же закрывался (глюк SwiftUI, найден 2026-10-04).
            if hasIncidentsLink {
                NavigationLink(value: PointIncidentsRoute(pointId: point.id)) {
                    LabeledContent("Состояние") {
                        StateLabel(state: point.itemState)
                    }
                }
            } else {
                LabeledContent("Состояние") {
                    StateLabel(state: point.itemState)
                }
            }
            if let node {
                NavigationLink(value: node) {
                    LabeledContent("Объект", value: node.title)
                }
            } else if let parentTitle = point.parentTitle, !parentTitle.isEmpty {
                // Объекта нет в кэше (например, список объектов ещё не загружен).
                LabeledContent("Объект", value: parentTitle)
            }
            if let comment = point.comment, !comment.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Комментарий")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(comment)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Вкладка «Датчики»

    @ViewBuilder
    private var sensorsTab: some View {
        // Прибор, через который опрашивается точка, — из кэша справочника оборудования.
        if let device = pollDevice {
            Section("Устройство опроса") {
                NavigationLink(value: device) {
                    CaptionedEquipmentLink(equipment: device)
                }
            }
        }
        if let sensorsModel {
            PointSensorsSections(model: sensorsModel)
        }
    }

    // MARK: - Вкладка «Связь»

    /// Связь точки одним блоком без заголовка (вкладка и так называется «Связь»; решение владельца
    /// 2026-10-06 — короче и без повторов). Сверху — канал связи точки, ниже — подключения её
    /// прибора опроса (из справочника оборудования): модем или «Ethernet / IP — адрес:порт».
    /// Канал точки не повторяем, если такой же канал уже есть среди подключений прибора.
    @ViewBuilder
    private var connectionTab: some View {
        let connections = pollDevice?.details?.connections ?? []
        let isPointLinkShownByDevice = connections.contains { $0.commLinkType == point.commLinkType }

        Section {
            if let commLinkTitle = point.commLinkTitle, !isPointLinkShownByDevice {
                LabeledContent("Канал связи", value: commLinkTitle)
            }
            ForEach(Array(connections.enumerated()), id: \.offset) { _, connection in
                EquipmentConnectionRow(connection: connection)
            }
            if point.commLinkTitle == nil && connections.isEmpty {
                Text("Сведений о связи нет")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Прибор, через который опрашивается точка (устройство опроса), — из кэша справочника.
    private var pollDevice: Equipment? {
        guard let deviceId = point.deviceId else {
            return nil
        }
        return dataStore.equipment(withId: deviceId)
    }
}

extension View {
    /// Переходы к карточкам объекта и точки — одинаковые во всех вкладках.
    /// NavigationLink(value: объект или точка) откроет нужную карточку.
    func appNavigationDestinations() -> some View {
        self
            .navigationDestination(for: Node.self) { node in
                NodeDetailView(node: node)
            }
            .navigationDestination(for: MeasurePoint.self) { point in
                MeasurePointDetailView(point: point)
            }
            .navigationDestination(for: Equipment.self) { equipment in
                EquipmentDetailView(equipment: equipment)
            }
            .navigationDestination(for: SavedReport.self) { report in
                ReportViewerView(report: report)
            }
            .navigationDestination(for: PointIncidentsRoute.self) { route in
                PointIncidentsView(pointId: route.pointId)
            }
            .navigationDestination(for: PointArchiveRoute.self) { route in
                PointArchiveView(point: route.point, model: route.model)
            }
            .navigationDestination(for: Incident.self) { incident in
                IncidentDetailView(incident: incident)
            }
    }
}
