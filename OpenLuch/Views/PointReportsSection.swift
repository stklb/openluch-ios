import SwiftUI

// Раздел «Отчёты» во вкладке «Данные» карточки точки (после последних данных):
// кнопка «Сформировать отчёт» и сохранённые на телефоне отчёты этой точки (новые сверху).
// Нажатие на отчёт — просмотр PDF (без интернета), свайп влево — удалить.
struct PointReportsSection: View {
    let model: PointReportsModel
    /// false — у учётной записи нет права формировать отчёты: кнопки нет, остаются сохранённые.
    let canCreateReport: Bool
    /// Открыть окно «Отчёт» (его показывает карточка точки).
    let onCreateReport: () -> Void

    var body: some View {
        Section {
            if canCreateReport {
                Button {
                    onCreateReport()
                } label: {
                    Label("Сформировать отчёт", systemImage: "doc.text")
                }
            }

            ForEach(model.savedReports) { report in
                NavigationLink(value: report) {
                    SavedReportRow(report: report)
                }
            }
            .onDelete { offsets in
                let reportsToDelete = offsets.map { model.savedReports[$0] }
                Task {
                    for report in reportsToDelete {
                        await model.delete(report)
                    }
                }
            }
        } header: {
            Text("Отчёты")
        } footer: {
            if !model.savedReports.isEmpty {
                Text("Сохранённые отчёты открываются без интернета. Они есть и в приложении «Файлы»: «На iPhone» → «OpenLuch» → «Отчёты».")
            }
        }
    }
}

/// Строка сохранённого отчёта: название, тип данных и период, когда сформирован и размер.
struct SavedReportRow: View {
    let report: SavedReport

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(report.reportTitle)
                .lineLimit(2)
            Text("\(report.dataTypeTitle) · \(report.periodText)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Сформирован \(TextFormatting.updatedAt(report.createdAt)) · \(TextFormatting.bytes(Int64(report.sizeBytes)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
