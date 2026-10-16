import Foundation

// Работы на объектах учёта (в ЛЭРС: «Работы» — заявки обслуживающим: проверка, демонтаж, ремонт…).
// Показываем в карточке объекта, только просмотр.
//
// Откуда: GET /api/v1/Core/NodeJobs?incomplete=true — незавершённые работы СРАЗУ ПО ВСЕМ объектам
// (фильтра по объекту в API нет, см. docs/api-notes.md). Ответ маленький (~1 КБ на работу),
// поэтому запрашиваем его вместе со списком объектов и храним в том же файле кэша — срок годности
// у работ тот же, что у списка объектов (решение владельца 2026-10-16).
//
// Даты сервер присылает без часового пояса («2024-02-15T00:00:00»), поэтому храним их строками
// и показываем только день (TextFormatting.calendarDay).

/// Одна работа на объекте — только то, что показываем.
nonisolated struct NodeJob: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let nodeId: Int
    /// Точка учёта, к которой относится работа (бывает не указана).
    let measurePointId: Int?
    /// Название работы, например «проверка».
    let title: String?
    /// Тип работы, например «Демонтаж».
    let typeTitle: String?
    /// Номер наряда.
    let workOrderNumber: String?
    /// Начало и плановое окончание — день «гггг-мм-дд».
    let startDay: String?
    let scheduledEndDay: String?
    /// Исполнитель (отображаемое имя учётной записи).
    let performerName: String?
    let description: String?
    /// Состояние: "Assigned" (назначена), "Overdue" (просрочена), "Completed" (завершена — с нашим
    /// фильтром не приходит).
    let state: String?

    /// Просрочена ли работа (сервер сам считает по плановому окончанию).
    var isOverdue: Bool {
        return state == "Overdue"
    }

    /// Сроки: «15.02.2024 – 20.03.2024» (начало – плановое окончание); nil — дат нет.
    var periodText: String? {
        let start = startDay.map { TextFormatting.calendarDay($0) }
        let end = scheduledEndDay.map { TextFormatting.calendarDay($0) }
        switch (start, end) {
        case let (start?, end?):
            return "\(start) – \(end)"
        case let (start?, nil):
            return "с \(start)"
        case let (nil, end?):
            return "до \(end)"
        default:
            return nil
        }
    }

    /// Заголовок строки: название, а если его нет — тип работы.
    var displayTitle: String {
        let text = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return text
        }
        let type = (typeTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return type.isEmpty ? "Работа № \(id)" : type
    }
}

/// Работа в ответе сервера — лишние поля (учётные записи, НС, результат) JSONDecoder пропускает.
nonisolated struct NodeJobResponse: Decodable, Sendable {
    let id: Int
    let nodeId: Int
    let measurePointId: Int?
    let title: String?
    let type: JobType?
    let workOrderNumber: String?
    let startDate: String?
    let scheduledEndDate: String?
    let performerName: String?
    let description: String?
    let state: String?

    nonisolated struct JobType: Decodable, Sendable {
        let title: String?
    }

    /// Работа для приложения: из дат оставляем только день, у описания — убираем пустые строки по краям
    /// (в ЛЭРС его часто заканчивают несколькими переводами строки).
    func makeJob() -> NodeJob {
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NodeJob(id: id, nodeId: nodeId, measurePointId: measurePointId, title: title,
                       typeTitle: type?.title, workOrderNumber: workOrderNumber,
                       startDay: startDate.map { String($0.prefix(10)) },
                       scheduledEndDay: scheduledEndDate.map { String($0.prefix(10)) },
                       performerName: performerName,
                       description: (trimmedDescription?.isEmpty ?? true) ? nil : trimmedDescription,
                       state: state)
    }
}
