import SwiftUI

// Экран «Нештатные ситуации» точки: открывается нажатием на строку «Состояние» в карточке точки,
// когда точка в состоянии «Ошибка» или «Предупреждение». Только просмотр.
// Нажатие на НС — экран подробностей с журналом. Данные — PointIncidentsModel.

/// «Адрес» экрана НС точки для NavigationLink(value:) — какой точки нештатные ситуации показать.
struct PointIncidentsRoute: Hashable {
    let pointId: Int
}

struct PointIncidentsView: View {
    @Environment(AppSession.self) private var session
    let pointId: Int
    /// Модель создаётся при первом показе экрана (нужна сессия из окружения).
    @State private var model: PointIncidentsModel?

    var body: some View {
        List {
            if let model {
                PointIncidentsSections(model: model)
            }
        }
        .navigationTitle("Нештатные ситуации")
        .navigationBarTitleDisplayMode(.inline)
        // Сохранённые — сразу, свежие — загрузка при каждом открытии экрана (запрос маленький).
        .task {
            if model == nil {
                model = PointIncidentsModel(pointId: pointId, session: session)
            }
            await model?.loadCache()
            await model?.refresh()
        }
    }
}

/// Разделы со списком активных НС (внутри List).
struct PointIncidentsSections: View {
    let model: PointIncidentsModel

    var body: some View {
        if let cached = model.cached {
            Section {
                if cached.incidents.isEmpty {
                    Text("Активных нештатных ситуаций нет")
                        .foregroundStyle(.secondary)
                }
                ForEach(cached.incidents) { incident in
                    NavigationLink(value: incident) {
                        IncidentRow(incident: incident)
                    }
                }
            } header: {
                // Заголовок экрана — «Нештатные ситуации», здесь только уточнение.
                Text("Активные")
            } footer: {
                statusFooter(savedAt: cached.savedAt)
            }
        } else if model.isLoading {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Загрузка…")
                        .foregroundStyle(.secondary)
                }
            }
        } else if let errorMessage = model.errorMessage {
            Section {
                Label("Не удалось загрузить: \(errorMessage)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                retryButton
            }
        }
    }

    @ViewBuilder
    private func statusFooter(savedAt: Date) -> some View {
        if model.isLoading {
            Text("Обновление…")
        } else if let errorMessage = model.errorMessage {
            VStack(alignment: .leading, spacing: 4) {
                Text("Не удалось обновить: \(errorMessage) Показано на \(TextFormatting.updatedAt(savedAt)).")
                retryButton
                    .font(.footnote)
            }
        } else {
            Text("Обновлено \(TextFormatting.updatedAt(savedAt)). Закрыть нештатную ситуацию можно в веб-интерфейсе ЛЭРС УЧЁТ.")
        }
    }

    private var retryButton: some View {
        Button("Повторить") {
            Task {
                await model.refresh()
            }
        }
    }
}

/// Строка НС: значок важности, краткое описание, с какого времени.
struct IncidentRow: View {
    let incident: Incident

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: incident.importanceSymbolName)
                .foregroundStyle(IncidentRow.color(for: incident))
                .accessibilityLabel(incident.importanceTitle)
            VStack(alignment: .leading, spacing: 3) {
                Text(incident.title)
                    .lineLimit(3)
                if let start = incident.startDate.flatMap({ TextFormatting.deviceDateTime($0) }) {
                    Text("С \(start)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Цвет важности: критическая — красный, предупреждение — оранжевый, остальное — синий.
    static func color(for incident: Incident) -> Color {
        switch incident.importance {
        case "Critical":
            return .red
        case "Warning":
            return .orange
        default:
            return .blue
        }
    }
}

/// Подробности НС: описание, важность, время, журнал. Только просмотр.
struct IncidentDetailView: View {
    @Environment(AppSession.self) private var session
    let incident: Incident
    @State private var model: IncidentDetailsModel?

    var body: some View {
        // Сервер мог прислать более свежие сведения о самой НС — берём их, иначе — из списка.
        let shown = model?.details?.incident ?? incident

        List {
            Section {
                Label {
                    Text(shown.importanceTitle)
                } icon: {
                    Image(systemName: shown.importanceSymbolName)
                        .foregroundStyle(IncidentRow.color(for: shown))
                }
                if let description = shown.description, !description.isEmpty {
                    Text(description)
                        .textSelection(.enabled)
                }
            }
            Section {
                if let start = shown.startDate.flatMap({ TextFormatting.deviceDateTime($0) }) {
                    LabeledContent("Начало", value: start)
                }
                if let end = shown.realEndDate.flatMap({ TextFormatting.deviceDateTime($0) }) {
                    LabeledContent("Окончание", value: end)
                } else if shown.isClosed != true {
                    LabeledContent("Окончание", value: "продолжается")
                }
                if shown.isClosed == true {
                    LabeledContent("Состояние", value: "закрыта")
                }
                if let entityTitle = shown.entityTitle, !entityTitle.isEmpty {
                    LabeledContent("Где", value: entityTitle)
                }
            } footer: {
                Text("Время — по часам прибора.")
            }
            logSection
        }
        .navigationTitle(shown.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                model = IncidentDetailsModel(incident: incident, session: session)
            }
            await model?.start()
        }
    }

    @ViewBuilder
    private var logSection: some View {
        if let model {
            Section {
                if let log = model.details?.log {
                    if log.isEmpty {
                        Text("Записей нет")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(log) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            if let date = entry.date.flatMap({ TextFormatting.deviceDateTime($0) }) {
                                Text(date)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.text)
                        }
                    }
                } else if model.isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Загрузка журнала…")
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage = model.errorMessage {
                    Label("Не удалось загрузить журнал: \(errorMessage)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Повторить") {
                        Task {
                            await model.refresh()
                        }
                    }
                }
            } header: {
                Text("Журнал")
            }
        }
    }
}
