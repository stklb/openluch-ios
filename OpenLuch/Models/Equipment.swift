import Foundation

// Оборудование (в API ЛЭРС — Equipment): вычислители, счётчики, датчики, модемы.
// Список приходит из GET /api/v1/Core/Equipment (весь справочник одним ответом, см. docs/api-notes.md).
//
// Ответ сервера тяжёлый: кроме самого оборудования в нём полные описания моделей приборов
// (у одной модели — до 100 КБ) и параметры опроса. Поэтому в кэш на телефоне сохраняем
// только то, что показываем: в списке — модель, заводской номер, даты поверки и объекты,
// где оборудование установлено; в карточке — подробности (EquipmentDetails).
// Всё это собирается из ответа один раз — при загрузке. Карточка новых запросов не делает.

/// Объект учёта, на котором установлено оборудование: номер и название.
/// Название храним здесь же — список объектов может быть ещё не загружен (по сотовой сети
/// загружается только открытая вкладка), а показать, где стоит прибор, нужно сразу.
nonisolated struct EquipmentPlace: Codable, Hashable, Sendable {
    let nodeId: Int
    let title: String
}

nonisolated struct Equipment: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    /// Название модели, например «СПТ943» или «ЛЭРС GSM Lite».
    let modelTitle: String
    /// Возможности модели строкой: "Gauge" (измерительный прибор), "CommunicationDevice" (модем),
    /// может быть несколько через запятую: "Gauge, CommunicationDevice". См. `symbolName`.
    let modelCapabilities: String?
    /// Заводской (серийный) номер.
    let serialNumber: String?
    /// Дата последней поверки — день в виде «2024-07-02» (сервер присылает её без часового пояса,
    /// это просто календарная дата). nil — не указана.
    let lastCalibrationDay: String?
    /// Дата следующей (планируемой) поверки — в том же виде.
    let nextCalibrationDay: String?
    /// Объекты учёта, где установлено оборудование. Обычно один; «общее» оборудование
    /// (например, модем на несколько объектов) — несколько. Пусто — не установлено.
    let places: [EquipmentPlace]
    /// Подробности для карточки. nil — кэш сохранён прошлой версией приложения (без подробностей);
    /// появятся после следующего обновления справочника.
    let details: EquipmentDetails?

    /// `details` по умолчанию nil — чтобы в тестах можно было создавать оборудование без подробностей.
    init(id: Int, modelTitle: String, modelCapabilities: String?, serialNumber: String?,
         lastCalibrationDay: String?, nextCalibrationDay: String?, places: [EquipmentPlace],
         details: EquipmentDetails? = nil) {
        self.id = id
        self.modelTitle = modelTitle
        self.modelCapabilities = modelCapabilities
        self.serialNumber = serialNumber
        self.lastCalibrationDay = lastCalibrationDay
        self.nextCalibrationDay = nextCalibrationDay
        self.places = places
        self.details = details
    }

    /// true — средство измерения (вычислитель, счётчик, датчик): у него бывают поверка и точка учёта.
    /// Модемы и сигнализация — не средства измерения.
    var isMeasuringInstrument: Bool {
        return (modelCapabilities ?? "").contains("Gauge")
    }

    /// Что это за оборудование, словами: «Прибор учёта», «Модем».
    var kindTitle: String {
        let capabilities = modelCapabilities ?? ""
        if capabilities.contains("Gauge") {
            return "Прибор учёта"
        }
        if capabilities.contains("CommunicationDevice") {
            return "Коммуникационное оборудование"
        }
        if capabilities.contains("Signaling") {
            return "Сигнализация"
        }
        return "Другое"
    }

    /// «СПТ943 № 13562» — для ссылок на оборудование из других карточек.
    var shortTitle: String {
        if let serialNumber, !serialNumber.isEmpty {
            return "\(modelTitle) № \(serialNumber)"
        }
        return modelTitle
    }

    /// Значок SF Symbols: прибор или модем.
    var symbolName: String {
        let capabilities = modelCapabilities ?? ""
        if capabilities.contains("Gauge") {
            return "gauge.with.needle"
        }
        if capabilities.contains("CommunicationDevice") {
            return "antenna.radiowaves.left.and.right"
        }
        return "shippingbox"
    }

    /// Названия объектов через запятую — или nil, если оборудование нигде не установлено.
    var placesTitle: String? {
        if places.isEmpty {
            return nil
        }
        return places.map { $0.title }.joined(separator: ", ")
    }

    /// Истёк ли срок поверки: дата следующей поверки уже наступила.
    /// `today` — сегодняшний день в виде «2026-10-03» (см. `Equipment.calendarDay(of:)`).
    /// Даты в виде «гггг-мм-дд» можно сравнивать просто как строки.
    func isCalibrationOverdue(today: String) -> Bool {
        guard let nextCalibrationDay else {
            return false
        }
        return nextCalibrationDay <= today
    }

    // MARK: - Сборка списка из ответа сервера

    /// Превращает ответ сервера в список оборудования, отсортированный по модели и номеру.
    static func makeList(from response: EquipmentListResponse) -> [Equipment] {
        // Модели: номер модели → модель.
        var modelsById: [Int: EquipmentModelResponse] = [:]
        for model in response.modelList ?? [] {
            modelsById[model.id] = model
        }

        // Названия объектов: номер объекта → название.
        var nodeTitlesById: [Int: String] = [:]
        for node in response.nodes ?? [] {
            if let title = node.title, !title.isEmpty {
                nodeTitlesById[node.id] = title
            }
        }

        // Где установлено: номер оборудования → объекты.
        var placesByEquipmentId: [Int: [EquipmentPlace]] = [:]
        for link in response.nodeEquipment ?? [] {
            let title = nodeTitlesById[link.nodeId] ?? "Объект № \(link.nodeId)"
            let place = EquipmentPlace(nodeId: link.nodeId, title: title)
            placesByEquipmentId[link.equipmentId, default: []].append(place)
        }

        var result: [Equipment] = []
        for item in response.list ?? [] {
            var model: EquipmentModelResponse? = nil
            if let modelId = item.equipmentModelId {
                model = modelsById[modelId]
            }
            var modelTitle = model?.title ?? ""
            if modelTitle.isEmpty {
                modelTitle = "Модель не указана"
            }
            let places = (placesByEquipmentId[item.id] ?? []).sorted { first, second in
                first.title.localizedStandardCompare(second.title) == .orderedAscending
            }
            let equipment = Equipment(
                id: item.id,
                modelTitle: modelTitle,
                modelCapabilities: model?.capabilities,
                serialNumber: item.serialNumber,
                lastCalibrationDay: calendarDay(fromServerText: item.lastCalibrationDate),
                nextCalibrationDay: calendarDay(fromServerText: item.scheduledCalibrationDate),
                places: places,
                details: makeDetails(item: item, model: model)
            )
            result.append(equipment)
        }

        // По названию модели, внутри одной модели — по номеру («2» раньше «10»).
        result.sort { first, second in
            let byModel = first.modelTitle.localizedStandardCompare(second.modelTitle)
            if byModel != .orderedSame {
                return byModel == .orderedAscending
            }
            return (first.serialNumber ?? "").localizedStandardCompare(second.serialNumber ?? "") == .orderedAscending
        }
        return result
    }

    /// Подробности для карточки из записи ответа сервера. Пустые строки превращаем в nil,
    /// чтобы карточка не показывала пустые строчки.
    private static func makeDetails(item: EquipmentItemResponse, model: EquipmentModelResponse?) -> EquipmentDetails {
        var connections: [EquipmentConnection] = []
        for connection in item.pollSettings?.connections ?? [] {
            var modemTitle: String? = nil
            if let modem = connection.commDevice {
                var title = modem.model?.title ?? "Модем"
                if let serialNumber = nonEmpty(modem.serialNumber) {
                    title += " № \(serialNumber)"
                }
                modemTitle = title
            }
            connections.append(EquipmentConnection(commLinkType: connection.commLinkType,
                                                   modemEquipmentId: connection.commDeviceEquipmentId,
                                                   modemTitle: modemTitle,
                                                   internetHost: nonEmpty(connection.internetHost),
                                                   internetPort: connection.internetPort))
        }

        // Межповерочный интервал 0 — «не задан».
        var calibrationIntervalYears: Int? = nil
        if let interval = model?.calibrationInterval, interval > 0 {
            calibrationIntervalYears = interval
        }

        return EquipmentDetails(
            modelLongTitle: nonEmpty(model?.longTitle),
            calibrationIntervalYears: calibrationIntervalYears,
            sealNumber: nonEmpty(item.sealNumber),
            calibrationOrganization: nonEmpty(item.calibrationOrganization),
            calibrationResult: item.calibrationResult,
            calibrationRegisterNumber: nonEmpty(item.calibrationStateRegisterNumber),
            calibrationSyncDay: calendarDay(fromServerText: item.calibrationSyncDate),
            calibrationResultId: nonEmpty(item.calibrationResultId),
            networkAddress: nonEmpty(item.networkAddress),
            firmwareVersion: nonEmpty(item.lastReadParameters?.firmwareVersion),
            hardwareVersion: nonEmpty(item.lastReadParameters?.hardwareVersion),
            batteryVolts: item.lastReadParameters?.batteryLevel,
            isBatteryLow: item.lastReadParameters?.batteryLow ?? false,
            comment: nonEmpty(item.comment),
            connections: connections
        )
    }

    /// Строка без пробелов по краям — или nil, если она пустая.
    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// «2024-07-02T00:00:00» → «2024-07-02». Берём только день: время в датах поверки всегда
    /// 00:00, а часового пояса сервер не присылает. nil — если строки нет или она не похожа на дату.
    static func calendarDay(fromServerText text: String?) -> String? {
        guard let text, text.count >= 10 else {
            return nil
        }
        let day = String(text.prefix(10))
        // Проверяем вид «гггг-мм-дд»: цифры и дефисы на своих местах.
        let characters = Array(day)
        for (index, character) in characters.enumerated() {
            if index == 4 || index == 7 {
                if character != "-" {
                    return nil
                }
            } else if !character.isNumber {
                return nil
            }
        }
        return day
    }

    /// День `date` по часам телефона в виде «2026-10-03» — чтобы сравнивать с датами поверки.
    static func calendarDay(of date: Date) -> String {
        return calendarDayFormatter().string(from: date)
    }

    /// «2026-10-03» → дата (полночь этого дня). Для выбора даты в фильтре «Нужно поверить до…».
    static func date(fromCalendarDay day: String) -> Date? {
        return calendarDayFormatter().date(from: day)
    }

    private static func calendarDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

// MARK: - Подробности для карточки

/// Подробности об оборудовании для карточки. Все поля могут отсутствовать —
/// сервер заполняет их по-разному для разных приборов.
nonisolated struct EquipmentDetails: Codable, Hashable, Sendable {
    /// Полное название модели (у большинства моделей не заполнено).
    let modelLongTitle: String?
    /// Межповерочный интервал модели, в годах.
    let calibrationIntervalYears: Int?
    /// Номер пломбы госповерителя.
    let sealNumber: String?
    /// Организация-поверитель.
    let calibrationOrganization: String?
    /// Результат последней поверки: 1 — пригоден, 0 — непригоден, nil — неизвестно.
    let calibrationResult: Int?
    /// Номер в реестре средств измерений (из ФГИС «АРШИН»).
    let calibrationRegisterNumber: String?
    /// Когда сведения о поверке последний раз сверялись с ФГИС «АРШИН» — день «гггг-мм-дд».
    let calibrationSyncDay: String?
    /// Номер записи о поверке во ФГИС «АРШИН», например «1-355640981». Сервер ЛЭРС заполняет его,
    /// только если сведения о поверке были синхронизированы с «АРШИН». nil — нет (или кэш прошлой версии).
    var calibrationResultId: String? = nil
    /// Сетевой адрес прибора (для опроса).
    let networkAddress: String?
    /// Версия программы (прошивки) — по данным последнего опроса.
    let firmwareVersion: String?
    /// Версия аппаратного исполнения — по данным последнего опроса.
    let hardwareVersion: String?
    /// Напряжение батареи, вольт — по данным последнего опроса.
    let batteryVolts: Double?
    /// Батарея разряжена (по данным последнего опроса).
    let isBatteryLow: Bool
    let comment: String?
    /// Как прибор опрашивается: каналы связи и модемы.
    let connections: [EquipmentConnection]

    /// Страница записи о поверке на сайте ФГИС «АРШИН» — или nil, если номера записи нет.
    /// Адрес собирается из номера записи (calibrationResultId) так же, как его открывает сам «АРШИН»:
    /// https://fgis.gost.ru/fundmetrology/cm/results/1-355640981
    var arshinURL: URL? {
        guard let calibrationResultId else {
            return nil
        }
        // Номер — только цифры и дефис; на всякий случай кодируем, чтобы адрес не сломался.
        guard let encoded = calibrationResultId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://fgis.gost.ru/fundmetrology/cm/results/" + encoded)
    }

    /// Результат поверки словами — или nil, если неизвестен.
    var calibrationResultTitle: String? {
        switch calibrationResult {
        case 1:
            return "Пригоден"
        case 0:
            return "Непригоден"
        default:
            return nil
        }
    }
}

/// Одно подключение для опроса прибора: канал связи, модем (если опрос идёт через модем)
/// и IP-адрес с портом (для канала Ethernet / IP). Телефонные номера сознательно не сохраняем.
nonisolated struct EquipmentConnection: Codable, Hashable, Sendable {
    /// Канал связи строкой: "Gprs", "Gsm", "Ip"… См. MeasurePoint.commLinkTitle(for:).
    let commLinkType: String?
    /// Номер модема в справочнике оборудования — для перехода к его карточке.
    let modemEquipmentId: Int?
    /// «ЛЭРС GSM Lite № 10084».
    let modemTitle: String?
    /// Адрес прибора для канала Ethernet / IP: IP-адрес («192.168.1.222») или доменное имя
    /// («teplo.example.ru»). Порт сервер всегда присылает отдельно — в internetPort.
    /// `var … = nil` — чтобы кэш прошлой версии (без этого поля) читался без ошибок.
    var internetHost: String? = nil
    /// TCP-порт для канала Ethernet / IP, например 4001.
    var internetPort: Int? = nil

    /// Адрес с портом для показа: «192.168.1.222:4001», «teplo.example.ru:4001».
    /// Только для канала Ethernet / IP; nil, если канал другой или адреса нет.
    var ipAddressText: String? {
        guard commLinkType == "Ip", let internetHost else {
            return nil
        }
        guard let internetPort else {
            return internetHost
        }
        // IPv6-адрес с портом по правилам пишется в квадратных скобках: [fe80::1]:4001.
        if internetHost.contains(":") {
            return "[\(internetHost)]:\(internetPort)"
        }
        return "\(internetHost):\(internetPort)"
    }

    /// Подпись строки адреса: «IP-адрес» для цифрового адреса, «Адрес» — для доменного имени.
    var ipAddressLabel: String {
        guard let internetHost, EquipmentConnection.isIPAddress(internetHost) else {
            return "Адрес"
        }
        return "IP-адрес"
    }

    /// Похоже ли на IP-адрес: IPv4 — четыре числа 0…255 через точку; IPv6 — есть двоеточия
    /// (в доменном имени их не бывает).
    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") {
            return true
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return false
        }
        for part in parts {
            guard let number = Int(part), number >= 0, number <= 255, part.allSatisfy(\.isNumber) else {
                return false
            }
        }
        return true
    }
}

// MARK: - Ответ сервера GET /api/v1/Core/Equipment

/// Ответ GET /api/v1/Core/Equipment. Берём из него только нужные поля — остальное
/// (параметры опроса, описания интерфейсов моделей и т.п.) JSONDecoder пропускает.
nonisolated struct EquipmentListResponse: Decodable, Sendable {
    /// Само оборудование.
    let list: [EquipmentItemResponse]?
    /// Модели оборудования (по одной на каждую встречающуюся модель).
    let modelList: [EquipmentModelResponse]?
    /// Объекты учёта, на которых установлено оборудование.
    let nodes: [EquipmentNodeResponse]?
    /// Связи «оборудование — объект учёта».
    let nodeEquipment: [NodeEquipmentLink]?
}

nonisolated struct EquipmentItemResponse: Decodable, Sendable {
    let id: Int
    let equipmentModelId: Int?
    let serialNumber: String?
    /// Даты приходят без часового пояса («2024-07-02T00:00:00»), поэтому разбираем их
    /// как строки, а не как Date (см. docs/api-notes.md, «Даты»).
    let lastCalibrationDate: String?
    let scheduledCalibrationDate: String?
    let calibrationSyncDate: String?
    let sealNumber: String?
    let calibrationOrganization: String?
    let calibrationResult: Int?
    let calibrationStateRegisterNumber: String?
    /// Номер записи о поверке во ФГИС «АРШИН» (есть, если была синхронизация с «АРШИН»).
    let calibrationResultId: String?
    let networkAddress: String?
    let comment: String?
    let lastReadParameters: EquipmentReadParametersResponse?
    let pollSettings: EquipmentPollSettingsResponse?
}

/// Сведения, считанные с прибора при последнем опросе.
nonisolated struct EquipmentReadParametersResponse: Decodable, Sendable {
    let firmwareVersion: String?
    let hardwareVersion: String?
    /// Напряжение батареи, вольт.
    let batteryLevel: Double?
    let batteryLow: Bool?
}

nonisolated struct EquipmentPollSettingsResponse: Decodable, Sendable {
    let connections: [PollConnectionResponse]?
}

nonisolated struct PollConnectionResponse: Decodable, Sendable {
    let commLinkType: String?
    let commDeviceEquipmentId: Int?
    let commDevice: CommunicationDeviceResponse?
    /// IP-адрес и TCP-порт прибора для канала Ethernet / IP.
    let internetHost: String?
    let internetPort: Int?
}

/// Модем, через который опрашивается прибор.
nonisolated struct CommunicationDeviceResponse: Decodable, Sendable {
    let serialNumber: String?
    let model: CommunicationDeviceModelResponse?
}

nonisolated struct CommunicationDeviceModelResponse: Decodable, Sendable {
    let title: String?
}

nonisolated struct EquipmentModelResponse: Decodable, Sendable {
    let id: Int
    let title: String?
    let longTitle: String?
    let capabilities: String?
    /// Межповерочный интервал, лет (0 — не задан).
    let calibrationInterval: Int?
}

/// Объект учёта в ответе об оборудовании — нужны только номер и название.
nonisolated struct EquipmentNodeResponse: Decodable, Sendable {
    let id: Int
    let title: String?
}

nonisolated struct NodeEquipmentLink: Decodable, Sendable {
    let nodeId: Int
    let equipmentId: Int
}
