import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// Просмотр сохранённого PDF-отчёта. Работает без интернета: файл уже на телефоне (ReportStore).
//
// Кнопки вверху:
//   • «Сохранить в Файлы» — стандартное окно выбора папки (iCloud Drive, «На iPhone», флешка…),
//     туда кладётся копия отчёта;
//   • «Поделиться» — стандартное меню iOS: отправить по почте, в мессенджер, AirDrop, напечатать,
//     а также «Сохранить в Файлы».
// Сам отчёт и так лежит в приложении «Файлы»: «На iPhone» → «OpenLuch» → «Отчёты».
struct ReportViewerView: View {
    @Environment(AppSession.self) private var session

    let report: SavedReport
    /// Кнопка «Готово» — закрыть окно отчёта целиком (когда просмотр открыт из окна формирования).
    /// nil — кнопки нет (просмотр открыт из карточки точки, назад — стрелкой).
    var onDone: (() -> Void)? = nil

    /// Копия файла для окна «Сохранить в Файлы» (читается при нажатии кнопки).
    @State private var exportDocument: PDFFileDocument?
    @State private var isExporterShown = false
    @State private var exportErrorMessage: String?

    var body: some View {
        let fileURL = session.reportStore.fileURL(for: report)
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))

        Group {
            if fileExists {
                PDFKitView(url: fileURL)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView("Файл отчёта не найден",
                                       systemImage: "doc.questionmark",
                                       description: Text("Возможно, его удалили в приложении «Файлы». Сформируйте отчёт заново."))
            }
        }
        // Короткий заголовок: справа три кнопки, длинное название отчёта не поместится
        // (оно и так крупно напечатано в самом отчёте).
        .navigationTitle("Отчёт")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if fileExists {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        prepareExport(fileURL: fileURL)
                    } label: {
                        Label("Сохранить в Файлы", systemImage: "folder")
                    }
                    // Для файла система сама покажет в меню его имя и уменьшенную первую страницу.
                    ShareLink(item: fileURL) {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                    }
                }
            }
            if let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        onDone()
                    }
                }
            }
        }
        .fileExporter(isPresented: $isExporterShown,
                      document: exportDocument,
                      contentType: .pdf,
                      defaultFilename: fileNameWithoutExtension) { result in
            if case .failure(let error) = result {
                exportErrorMessage = error.localizedDescription
            }
        }
        .alert("Не удалось сохранить",
               isPresented: Binding(get: { exportErrorMessage != nil }, set: { if !$0 { exportErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    /// Окно «Сохранить в Файлы» само добавит «.pdf».
    private var fileNameWithoutExtension: String {
        if report.fileName.lowercased().hasSuffix(".pdf") {
            return String(report.fileName.dropLast(4))
        }
        return report.fileName
    }

    private func prepareExport(fileURL: URL) {
        do {
            exportDocument = PDFFileDocument(data: try Data(contentsOf: fileURL))
            isExporterShown = true
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }
}

/// Стандартный просмотр PDF из PDFKit (системная библиотека Apple — тот же просмотр, что в «Файлах»):
/// листание, увеличение двумя пальцами, выделение и поиск текста.
/// Готового элемента для PDF в SwiftUI нет, поэтому оборачиваем PDFView из UIKit (UIViewRepresentable —
/// «переходник», через который SwiftUI показывает элемент UIKit).
struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        // Страница — по ширине экрана; листаем сверху вниз, как в «Файлах».
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}

/// PDF-файл для окна «Сохранить в Файлы» (.fileExporter ждёт «документ» — вот он).
nonisolated struct PDFFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: data)
    }
}
