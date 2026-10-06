import Foundation

// Сведения о сервере ЛЭРС для экрана «Настройки» → «О сервере»: версия, часовой пояс, лицензия.
//
// Откуда (оба ответа маленькие, замер на my.lers.ru — docs/api-notes.md):
//   • GET /api/v1/ServerInfo        — версия сервера (~0,3 КБ, без авторизации);
//   • GET /api/v1/ServerInfo/Extra  — лицензия, часовой пояс (~3 КБ; оформление сайта из того же ответа не показываем).
// Сохраняются на устройстве (Cache/server-details.json): экран открывается сразу, без сети.

/// Сохранённые сведения о сервере.
nonisolated struct ServerDetails: Codable, Sendable {
    /// Когда получены с сервера.
    let savedAt: Date
    /// «3.67.2».
    let version: String?
    /// «3.67.2.36711».
    let fullVersion: String?
    let license: ServerLicense?
    /// Часовой пояс сервера: смещение от UTC в часах (10 — «UTC+10»).
    let timeZoneOffsetHours: Int?
    /// Территория по умолчанию, например «Хабаровск».
    let defaultTerritory: String?
    /// «UTC+10», «UTC−3», «UTC» — или nil, если неизвестно.
    var timeZoneTitle: String? {
        guard let timeZoneOffsetHours else {
            return nil
        }
        if timeZoneOffsetHours == 0 {
            return "UTC"
        }
        let sign = timeZoneOffsetHours > 0 ? "+" : "−"
        return "UTC\(sign)\(abs(timeZoneOffsetHours))"
    }
}

/// Лицензия сервера ЛЭРС.
nonisolated struct ServerLicense: Codable, Sendable {
    /// "Corporate", "Commercial", "Cloud", "Personal" — см. `typeTitle`.
    let type: String?
    let number: String?
    /// Владелец лицензии, например «ООО "ЛЭРС"».
    let owner: String?
    /// Сколько объектов учёта разрешено и сколько уже занято.
    let nodeLimit: Int?
    let nodesUsed: Int?
    /// Окончание лицензии — день «гггг-мм-дд». nil — бессрочная (сервер присылает «0001-01-01»).
    let expireDay: String?
    /// Окончание подписки на обновления — день «гггг-мм-дд».
    let subscriptionExpireDay: String?
    /// Дата активации — день «гггг-мм-дд».
    let activationDay: String?

    var typeTitle: String? {
        switch type {
        case "Corporate":
            return "Корпоративная"
        case "Commercial":
            return "Коммерческая"
        case "Cloud":
            return "Облачная"
        case "Personal":
            return "Персональная"
        default:
            return nil
        }
    }

    /// «556 из 600».
    var nodesUsageText: String? {
        guard let nodeLimit, nodeLimit > 0 else {
            return nil
        }
        return "\(nodesUsed ?? 0) из \(nodeLimit)"
    }
}

// MARK: - Ответ сервера GET /api/v1/ServerInfo/Extra (LoginExtraInfo)

nonisolated struct ServerExtraInfoResponse: Decodable, Sendable {
    let license: LicenseResponse?
    let localTimeZoneOffset: Int?
    let defaultTerritory: TerritoryResponse?

    nonisolated struct LicenseResponse: Decodable, Sendable {
        let licenseType: String?
        let licenseNumber: String?
        let nodeLicenseCount: Int?
        let nodeUsed: Int?
        let expireDate: String?
        let subscriptionExpireDate: String?
        let activationDate: String?
        let owner: String?
    }

    nonisolated struct TerritoryResponse: Decodable, Sendable {
        let name: String?
    }

    /// Сведения для приложения (вместе с версией из ServerInfo). Пустые строки — nil.
    func makeDetails(serverInfo: ServerInfo, savedAt: Date) -> ServerDetails {
        var license: ServerLicense? = nil
        if let item = self.license {
            license = ServerLicense(
                type: item.licenseType,
                number: ServerExtraInfoResponse.nonEmpty(item.licenseNumber),
                owner: ServerExtraInfoResponse.nonEmpty(item.owner),
                nodeLimit: item.nodeLicenseCount,
                nodesUsed: item.nodeUsed,
                expireDay: ServerExtraInfoResponse.realDay(item.expireDate),
                subscriptionExpireDay: ServerExtraInfoResponse.realDay(item.subscriptionExpireDate),
                activationDay: ServerExtraInfoResponse.realDay(item.activationDate)
            )
        }
        return ServerDetails(
            savedAt: savedAt,
            version: serverInfo.version,
            fullVersion: serverInfo.fullVersion,
            license: license,
            timeZoneOffsetHours: localTimeZoneOffset,
            defaultTerritory: ServerExtraInfoResponse.nonEmpty(defaultTerritory?.name)
        )
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// «2028-08-01T00:00:00» → «2028-08-01». «0001-01-01…» — так сервер пишет «не задано» → nil.
    private static func realDay(_ text: String?) -> String? {
        guard let day = Equipment.calendarDay(fromServerText: text), !day.hasPrefix("0001-") else {
            return nil
        }
        return day
    }
}
