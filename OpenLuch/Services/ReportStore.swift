import Foundation

// Сформированные PDF-отчёты на телефоне.
//
// Зачем хранить: главная цель приложения — работа при плохом интернете (PLAN.md). Отчёт, однажды
// полученный, открывается потом без сети: из карточки точки или из приложения «Файлы».
//
// Где лежат:
//   • сами PDF — в папке «Документы/Отчёты» приложения. Благодаря настройкам в Info.plist
//     (UIFileSharingEnabled и LSSupportsOpeningDocumentsInPlace) эта папка видна в приложении
//     «Файлы»: «На iPhone» → «OpenLuch» → «Отчёты». Оттуда отчёт можно переслать, переместить, удалить;
//   • список «какой файл к какой точке относится» — отдельный маленький файл reports-index.json
//     в служебной папке (Application Support), чтобы в «Файлах» были видны только сами PDF.
//
// Отчёты — это документы пользователя, а не кэш: «Очистить кэш» и выход их НЕ удаляют
// (удалить можно в «Настройках» → «Отчёты» или свайпом в карточке точки). Папка «Документы»
// входит в резервную копию iCloud — отчёты не пропадут при переносе на новый телефон.
//
// Все функции выполняются в фоновом потоке (@concurrent): запись PDF не подвешивает интерфейс.

/// Сохранённый отчёт: файл и сведения о нём.
nonisolated struct SavedReport: Codable, Hashable, Identifiable, Sendable {
    /// Имя файла в папке «Отчёты» — оно же идентификатор (в одной папке имена не повторяются).
    let fileName: String
    /// Точка учёта, для которой сформирован отчёт.
    let pointId: Int
    /// Сервер, с которого получен отчёт (displayText адреса): у разных серверов номера точек
    /// могут совпадать, а показывать в карточке точки чужие отчёты нельзя.
    let server: String
    /// Название отчёта в ЛЭРС: «Посуточная ведомость учета параметров теплопотребления».
    let reportTitle: String
    /// Тип данных — "Hour", "Day", "Month" (см. ReportDataType).
    let dataType: String
    /// Период для показа пользователю: «01.09.2026 — 30.09.2026 (30 дней)».
    let periodText: String
    /// Когда сформирован.
    let createdAt: Date
    /// Размер файла в байтах.
    let sizeBytes: Int

    var id: String {
        return fileName
    }

    /// «Суточные» и т.п. — или сам код, если он незнакомый.
    var dataTypeTitle: String {
        return ReportDataType(rawValue: dataType)?.title ?? dataType
    }
}

nonisolated final class ReportStore: Sendable {

    /// Папка с PDF по умолчанию: «Документы/Отчёты».
    static var defaultDirectory: URL {
        return URL.documentsDirectory.appending(path: "Отчёты", directoryHint: .isDirectory)
    }

    /// Список отчётов по умолчанию: Application Support/reports-index.json.
    static var defaultIndexFile: URL {
        return URL.applicationSupportDirectory.appending(path: "reports-index.json")
    }

    let directory: URL
    let indexFile: URL

    /// Папки можно подменить — например, на временные в тестах.
    init(directory: URL = ReportStore.defaultDirectory, indexFile: URL = ReportStore.defaultIndexFile) {
        self.directory = directory
        self.indexFile = indexFile
    }

    /// Где лежит файл отчёта.
    func fileURL(for report: SavedReport) -> URL {
        return directory.appending(path: report.fileName)
    }

    // MARK: - Сохранение

    /// Сохраняет PDF и добавляет запись в список. Если файл с таким именем уже есть (тот же отчёт
    /// за тот же период сформирован заново), он заменяется — так не копятся одинаковые отчёты.
    @concurrent
    func save(pdf: Data, suggestedFileName: String, pointId: Int, server: String, reportTitle: String,
              dataType: ReportDataType, periodText: String, createdAt: Date = Date()) async throws -> SavedReport {
        let fileName = ReportStore.safeFileName(suggestedFileName)
        try createFolderIfNeeded(directory)
        // .atomic: сначала во временный файл, потом подмена — недописанный файл не появится.
        try pdf.write(to: directory.appending(path: fileName), options: .atomic)

        let report = SavedReport(fileName: fileName, pointId: pointId, server: server, reportTitle: reportTitle,
                                 dataType: dataType.rawValue, periodText: periodText, createdAt: createdAt,
                                 sizeBytes: pdf.count)
        var index = readIndex().filter { $0.fileName != fileName }
        index.append(report)
        try writeIndex(index)
        return report
    }

    // MARK: - Чтение

    /// Все сохранённые отчёты, новые сверху. Файлы, удалённые пользователем через «Файлы»,
    /// в список не попадают (и убираются из него).
    @concurrent
    func loadAll() async -> [SavedReport] {
        let index = readIndex()
        let existing = index.filter { report in
            FileManager.default.fileExists(atPath: fileURL(for: report).path(percentEncoded: false))
        }
        if existing.count != index.count {
            try? writeIndex(existing)
        }
        return existing.sorted { $0.createdAt > $1.createdAt }
    }

    /// Отчёты одной точки с текущего сервера, новые сверху.
    @concurrent
    func load(pointId: Int, server: String) async -> [SavedReport] {
        return await loadAll().filter { $0.pointId == pointId && $0.server == server }
    }

    // MARK: - Удаление

    @concurrent
    func delete(_ report: SavedReport) async throws {
        let file = fileURL(for: report)
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: file)
        }
        try writeIndex(readIndex().filter { $0.fileName != report.fileName })
    }

    /// Удаляет все сохранённые отчёты («Настройки» → «Отчёты» → «Удалить все отчёты»).
    @concurrent
    func deleteAll() async throws {
        for report in readIndex() {
            let file = fileURL(for: report)
            if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: file)
            }
        }
        try writeIndex([])
    }

    // MARK: - Имя файла

    /// Имя файла, которое можно сохранить: без «/» и «:» (их нельзя в именах файлов),
    /// не пустое, не слишком длинное, с окончанием «.pdf».
    static func safeFileName(_ suggested: String) -> String {
        var name = suggested.trimmingCharacters(in: .whitespacesAndNewlines)
        for forbidden in ["/", "\\", ":", "\n", "\r", "\t"] {
            name = name.replacingOccurrences(of: forbidden, with: "-")
        }
        if name.lowercased().hasSuffix(".pdf") {
            name = String(name.dropLast(4))
        }
        // Имена файлов на iPhone — до 255 байт; русская буква занимает 2 байта.
        // Режем середину, а не конец: в конце имени период и тип данных («c 01.09.2026 по 30.09.2026
        // (Суточные)») — без них отчёты за разные периоды получили бы одно имя и затёрли друг друга.
        if name.count > 120 {
            name = String(name.prefix(80)) + "…" + String(name.suffix(39))
        }
        // Имя не может начинаться с точки (такой файл будет скрытым).
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        if name.isEmpty {
            name = "Отчёт"
        }
        return name + ".pdf"
    }

    // MARK: - Вспомогательное

    private func readIndex() -> [SavedReport] {
        guard let data = try? Data(contentsOf: indexFile) else {
            return []
        }
        return (try? JSONDecoder().decode([SavedReport].self, from: data)) ?? []
    }

    private func writeIndex(_ index: [SavedReport]) throws {
        try createFolderIfNeeded(indexFile.deletingLastPathComponent())
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexFile, options: .atomic)
    }

    private func createFolderIfNeeded(_ folder: URL) throws {
        if !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}
