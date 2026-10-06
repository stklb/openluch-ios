import Foundation

// Нештатные ситуации (НС) точки учёта — для подвкладки «НС» карточки точки (только просмотр,
// решение владельца 2026-10-03: закрывать НС — в веб-интерфейсе ЛЭРС).
//
// Откуда (docs/api-notes.md, «Нештатные ситуации»):
//   • GET /api/v1/Incidents/Active/MeasurePoint/{id} — активные (открытые) НС точки, маленький ответ;
//   • GET /api/v1/Incidents/{id} — одна НС и её журнал (для экрана подробностей).
// ⚠️ Общего списка НС в REST API нет, поэтому общего списка в приложении тоже нет (решение владельца).
//
// Даты возникновения и окончания сервер даёт по часам прибора без часового пояса («2026-10-03T14:00:00»),
// поэтому храним их строками и показываем как есть (TextFormatting.deviceDateTime).

/// Одна нештатная ситуация.
nonisolated struct Incident: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    /// Код типа: "TempGreaterThanMax", "WaterLeak"… (в ЛЭРС их больше сотни). Для людей — `title`.
    let incidentType: String?
    /// Начало — по часам прибора, без часового пояса.
    let startDate: String?
    /// Окончание — по часам прибора; у продолжающейся НС сервер может прислать пустую дату («0001-01-01»).
    let endDate: String?
    /// Важность: "Information", "Warning", "Critical".
    let importance: String?
    let isClosed: Bool?
    /// Полное описание от сервера (на русском).
    let description: String?
    /// Краткое описание («Температура выше максимума»).
    let shortDesc: String?
    /// Название точки или объекта.
    let entityTitle: String?

    /// Заголовок для списка: краткое описание, иначе полное, иначе код типа.
    var title: String {
        for text in [shortDesc, description] {
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return incidentType ?? "Нештатная ситуация"
    }

    /// Важность для людей.
    var importanceTitle: String {
        switch importance {
        case "Critical":
            return "Критическая"
        case "Warning":
            return "Предупреждение"
        case "Information":
            return "Информация"
        default:
            return "Не указана"
        }
    }

    /// Значок SF Symbols по важности (цвет — в IncidentRow).
    var importanceSymbolName: String {
        switch importance {
        case "Critical":
            return "exclamationmark.octagon.fill"
        case "Warning":
            return "exclamationmark.triangle.fill"
        default:
            return "info.circle.fill"
        }
    }

    /// Окончание, если оно настоящее (не «0001-01-01» и не раньше начала).
    var realEndDate: String? {
        guard let endDate, !endDate.hasPrefix("0001-") else {
            return nil
        }
        if let startDate, endDate < startDate {
            return nil
        }
        return endDate
    }
}

/// Запись журнала НС: когда и что произошло.
nonisolated struct IncidentLogEntry: Codable, Hashable, Identifiable, Sendable {
    let id: Int64
    /// Время записи (как прислал сервер).
    let date: String?
    let message: String?
    let shortMessage: String?

    var text: String {
        for value in [message, shortMessage] {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return "—"
    }
}

/// Сохранённые активные НС точки.
nonisolated struct CachedIncidents: Codable, Sendable {
    let savedAt: Date
    let incidents: [Incident]
}

/// Сохранённые подробности одной НС (сама НС и журнал).
nonisolated struct CachedIncidentDetails: Codable, Sendable {
    let savedAt: Date
    let incident: Incident?
    let log: [IncidentLogEntry]
}

/// Ответ GET /api/v1/Incidents/{id} (IncidentGetResponseParameters).
nonisolated struct IncidentDetailsResponse: Decodable, Sendable {
    let incident: Incident?
    let log: [IncidentLogEntry]?
}
