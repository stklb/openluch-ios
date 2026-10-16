import Foundation

// Кэш на телефоне: последние загруженные списки объектов, точек учёта и оборудования.
//
// Зачем: главная цель приложения — показывать данные при плохом интернете и без него
// (см. «⚠️ ВАЖНО» в PLAN.md). Списки сохраняются в файлы и при запуске показываются сразу,
// без обращения к серверу.
//
// Как устроено: JSON-файлы в папке Application Support/Cache:
//   nodes.json          — объекты учёта и время сохранения;
//   measurepoints.json  — точки учёта и время сохранения;
//   equipment.json      — справочник оборудования и время сохранения;
//   readings/{id}.json  — последние данные отдельных точек (из карточки точки);
//   sensors/{id}.json   — датчики отдельных точек (из карточки точки);
//   report-lists/{id}.json — какие отчёты назначены точке (для окна «Сформировать отчёт»);
//   server-details.json — версия и лицензия сервера (экран «О сервере»);
//   incidents/{id}.json — активные нештатные ситуации точки, incidents/log-{id}.json — журнал одной НС.
// (Сами PDF-отчёты — не кэш, а документы пользователя: они в ReportStore.)
// Сохраняются только нужные приложению поля (модели Node, MeasurePoint, Equipment), поэтому
// файлы во много раз меньше ответов сервера.
//
// Почему Application Support, а не системная папка Caches: из Caches iOS может сама
// удалить файлы, когда на телефоне мало места, — и пользователь без интернета
// останется без данных. Резервное копирование в iCloud для этой папки отключаем:
// данные всегда можно скачать с сервера заново.
//
// Все функции async и выполняются в фоновом потоке (@concurrent), чтобы чтение
// и разбор большого файла не подвешивали интерфейс.

/// Сохранённый список объектов учёта и время, когда он был получен с сервера.
nonisolated struct CachedNodes: Codable, Sendable {
    let savedAt: Date
    let nodes: [Node]
    /// Размер ответа сервера в байтах при последней загрузке — чтобы перед следующим
    /// обновлением показать, сколько примерно придётся скачать. nil — неизвестен
    /// (например, кэш сохранён старой версией приложения).
    let responseBytes: Int?
    /// Группы объектов (приходят отдельным маленьким запросом вместе со списком объектов).
    /// nil — кэш сохранён прошлой версией приложения или группы не удалось получить.
    var groups: [NodeGroup]? = nil
    /// Потребители объектов (для фильтра «Потребитель»). nil — кэш сохранён прошлой версией приложения.
    var customers: [Customer]? = nil
    /// Незавершённые работы на объектах (отдельный маленький запрос вместе со списком объектов).
    /// nil — кэш сохранён прошлой версией приложения.
    var jobs: [NodeJob]? = nil
}

/// Сохранённый список точек учёта и время, когда он был получен с сервера.
nonisolated struct CachedMeasurePoints: Codable, Sendable {
    let savedAt: Date
    let measurePoints: [MeasurePoint]
    /// Размер ответа сервера в байтах при последней загрузке (см. CachedNodes.responseBytes).
    let responseBytes: Int?
    /// Потребители, указанные у точек (см. CachedNodes.customers).
    var customers: [Customer]? = nil
}

/// Сохранённый справочник оборудования и время, когда он был получен с сервера.
nonisolated struct CachedEquipment: Codable, Sendable {
    let savedAt: Date
    let equipment: [Equipment]
    /// Размер ответа сервера в байтах при последней загрузке (см. CachedNodes.responseBytes).
    let responseBytes: Int?
}

nonisolated final class CacheStore: Sendable {

    /// Папка кэша по умолчанию: Application Support/Cache внутри приложения.
    static var defaultDirectory: URL {
        return URL.applicationSupportDirectory.appending(path: "Cache", directoryHint: .isDirectory)
    }

    let directory: URL

    /// `directory` можно подменить — например, на временную папку в тестах.
    init(directory: URL = CacheStore.defaultDirectory) {
        self.directory = directory
    }

    private var nodesFile: URL {
        return directory.appending(path: "nodes.json")
    }

    private var measurePointsFile: URL {
        return directory.appending(path: "measurepoints.json")
    }

    private var equipmentFile: URL {
        return directory.appending(path: "equipment.json")
    }

    /// Когда последний раз сохранялись списки (объекты, точки, оборудование); nil — списка нет.
    /// Берём дату изменения файла, а не читаем сам файл: список точек весит мегабайты, а эта дата
    /// нужна мгновенно, когда приложение уходит в фон (BackgroundRefresh.schedule).
    func listFilesModifiedAt() -> [Date?] {
        return [nodesFile, measurePointsFile, equipmentFile].map { file in
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            return values?.contentModificationDate
        }
    }

    // MARK: - Объекты учёта

    @concurrent
    func saveNodes(_ nodes: [Node], savedAt: Date = Date(), responseBytes: Int? = nil,
                   groups: [NodeGroup]? = nil, customers: [Customer]? = nil,
                   jobs: [NodeJob]? = nil) async throws {
        let cached = CachedNodes(savedAt: savedAt, nodes: nodes, responseBytes: responseBytes, groups: groups,
                                 customers: customers, jobs: jobs)
        let data = try JSONEncoder().encode(cached)
        try writeFile(data, to: nodesFile)
    }

    /// Возвращает сохранённые объекты или nil, если кэша нет или файл повреждён.
    @concurrent
    func loadNodes() async -> CachedNodes? {
        guard let data = try? Data(contentsOf: nodesFile) else {
            return nil
        }
        return try? JSONDecoder().decode(CachedNodes.self, from: data)
    }

    // MARK: - Точки учёта

    @concurrent
    func saveMeasurePoints(_ measurePoints: [MeasurePoint], savedAt: Date = Date(),
                           responseBytes: Int? = nil, customers: [Customer]? = nil) async throws {
        let cached = CachedMeasurePoints(savedAt: savedAt, measurePoints: measurePoints,
                                         responseBytes: responseBytes, customers: customers)
        let data = try JSONEncoder().encode(cached)
        try writeFile(data, to: measurePointsFile)
    }

    /// Возвращает сохранённые точки или nil, если кэша нет или файл повреждён.
    @concurrent
    func loadMeasurePoints() async -> CachedMeasurePoints? {
        guard let data = try? Data(contentsOf: measurePointsFile) else {
            return nil
        }
        return try? JSONDecoder().decode(CachedMeasurePoints.self, from: data)
    }

    // MARK: - Оборудование

    @concurrent
    func saveEquipment(_ equipment: [Equipment], savedAt: Date = Date(), responseBytes: Int? = nil) async throws {
        let cached = CachedEquipment(savedAt: savedAt, equipment: equipment, responseBytes: responseBytes)
        let data = try JSONEncoder().encode(cached)
        try writeFile(data, to: equipmentFile)
    }

    /// Возвращает сохранённое оборудование или nil, если кэша нет или файл повреждён.
    @concurrent
    func loadEquipment() async -> CachedEquipment? {
        guard let data = try? Data(contentsOf: equipmentFile) else {
            return nil
        }
        return try? JSONDecoder().decode(CachedEquipment.self, from: data)
    }

    // MARK: - Последние данные точек (вместе с их единицами измерения)

    /// Последние данные точки хранятся в отдельном маленьком файле: Cache/readings/{id}.json.
    private func readingsFile(pointId: Int) -> URL {
        return directory.appending(path: "readings", directoryHint: .isDirectory).appending(path: "\(pointId).json")
    }

    @concurrent
    func saveReadings(_ readings: CachedReadings, pointId: Int) async throws {
        let data = try JSONEncoder().encode(readings)
        try writeFile(data, to: readingsFile(pointId: pointId))
    }

    /// Сохранённые последние данные точки или nil, если их нет.
    @concurrent
    func loadReadings(pointId: Int) async -> CachedReadings? {
        guard let data = try? Data(contentsOf: readingsFile(pointId: pointId)) else {
            return nil
        }
        return try? JSONDecoder().decode(CachedReadings.self, from: data)
    }

    // MARK: - Датчики точек

    /// Датчики точки — отдельный маленький файл: Cache/sensors/{id}.json.
    private func sensorsFile(pointId: Int) -> URL {
        return directory.appending(path: "sensors", directoryHint: .isDirectory).appending(path: "\(pointId).json")
    }

    @concurrent
    func saveSensors(_ sensors: CachedPointSensors, pointId: Int) async throws {
        let data = try JSONEncoder().encode(sensors)
        try writeFile(data, to: sensorsFile(pointId: pointId))
    }

    /// Сохранённые датчики точки или nil, если их ещё не загружали.
    @concurrent
    func loadSensors(pointId: Int) async -> CachedPointSensors? {
        guard let data = try? Data(contentsOf: sensorsFile(pointId: pointId)) else {
            return nil
        }
        return try? JSONDecoder().decode(CachedPointSensors.self, from: data)
    }

    // MARK: - Списки отчётов точек

    /// Отчёты, назначенные точке, — отдельный маленький файл: Cache/report-lists/{id}.json.
    private func reportListFile(pointId: Int) -> URL {
        return directory.appending(path: "report-lists", directoryHint: .isDirectory).appending(path: "\(pointId).json")
    }

    @concurrent
    func saveReportList(_ reports: CachedPointReports, pointId: Int) async throws {
        let data = try JSONEncoder().encode(reports)
        try writeFile(data, to: reportListFile(pointId: pointId))
    }

    /// Сохранённый список отчётов точки или nil, если его ещё не загружали.
    @concurrent
    func loadReportList(pointId: Int) async -> CachedPointReports? {
        guard let data = try? Data(contentsOf: reportListFile(pointId: pointId)) else {
            return nil
        }
        return try? JSONDecoder().decode(CachedPointReports.self, from: data)
    }

    // MARK: - Нештатные ситуации

    private func incidentsFile(pointId: Int) -> URL {
        return directory.appending(path: "incidents", directoryHint: .isDirectory).appending(path: "\(pointId).json")
    }

    private func incidentDetailsFile(incidentId: Int) -> URL {
        return directory.appending(path: "incidents", directoryHint: .isDirectory)
            .appending(path: "log-\(incidentId).json")
    }

    @concurrent
    func saveIncidents(_ incidents: CachedIncidents, pointId: Int) async throws {
        let data = try JSONEncoder().encode(incidents)
        try writeFile(data, to: incidentsFile(pointId: pointId))
    }

    @concurrent
    func loadIncidents(pointId: Int) async -> CachedIncidents? {
        guard let data = try? Data(contentsOf: incidentsFile(pointId: pointId)) else {
            return nil
        }
        return try? JSONDecoder().decode(CachedIncidents.self, from: data)
    }

    @concurrent
    func saveIncidentDetails(_ details: CachedIncidentDetails, incidentId: Int) async throws {
        let data = try JSONEncoder().encode(details)
        try writeFile(data, to: incidentDetailsFile(incidentId: incidentId))
    }

    @concurrent
    func loadIncidentDetails(incidentId: Int) async -> CachedIncidentDetails? {
        guard let data = try? Data(contentsOf: incidentDetailsFile(incidentId: incidentId)) else {
            return nil
        }
        return try? JSONDecoder().decode(CachedIncidentDetails.self, from: data)
    }

    // MARK: - Сведения о сервере

    private var serverDetailsFile: URL {
        return directory.appending(path: "server-details.json")
    }

    @concurrent
    func saveServerDetails(_ details: ServerDetails) async throws {
        let data = try JSONEncoder().encode(details)
        try writeFile(data, to: serverDetailsFile)
    }

    @concurrent
    func loadServerDetails() async -> ServerDetails? {
        guard let data = try? Data(contentsOf: serverDetailsFile) else {
            return nil
        }
        return try? JSONDecoder().decode(ServerDetails.self, from: data)
    }

    // MARK: - Весь кэш

    /// Сколько места занимает кэш, в байтах (для экрана «Настройки → Кэш»): все файлы в папке кэша.
    @concurrent
    func totalSizeInBytes() async -> Int64 {
        var total: Int64 = 0
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        while let file = files?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey])
            if let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Удаляет весь кэш (кнопка «Очистить кэш» и выход из учётной записи).
    @concurrent
    func clear() async throws {
        if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Вспомогательное

    private func writeFile(_ data: Data, to file: URL) throws {
        try createDirectoryIfNeeded()
        // Вложенная папка (например, readings/) — создаём, если её ещё нет.
        let folder = file.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // .atomic: сначала пишем во временный файл, потом подменяем. Если приложение
        // закроется посреди записи, старый кэш останется целым.
        try data.write(to: file, options: .atomic)
    }

    private func createDirectoryIfNeeded() throws {
        if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Не копировать кэш в резервную копию iCloud — его всегда можно скачать заново.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directoryURL = directory
        try directoryURL.setResourceValues(values)
    }
}
