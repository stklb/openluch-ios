import SwiftUI

// Карточка оборудования: сведения о приборе, поверка, на каком объекте установлен, как опрашивается.
//
// Всё берётся из кэша — новых запросов к серверу карточка не делает (главная цель — работа
// без интернета, см. PLAN.md). Подробности сохраняются вместе со справочником оборудования
// (Equipment.details).
//
// Точку учёта здесь сознательно не показываем (решение владельца, 2026-10-03): связь
// «датчик → точка» есть только в тяжёлом запросе точки. Из карточки можно перейти к объекту
// и выбрать точку там; датчики точки видны в её карточке (PointSensorsSections).
struct EquipmentDetailView: View {
    @Environment(DataStore.self) private var dataStore

    let equipment: Equipment

    var body: some View {
        // Сегодняшний день — для пометки «срок поверки истёк».
        let today = Equipment.calendarDay(of: Date())

        List {
            mainSection
            if let details = equipment.details {
                calibrationSection(details: details, today: today)
                placesSection
                connectionSection(details: details)
                if let comment = details.comment {
                    Section("Комментарий") {
                        Text(comment)
                            .textSelection(.enabled)
                    }
                }
            } else {
                // Справочник сохранён прошлой версией приложения — подробностей в кэше нет.
                calibrationSection(details: nil, today: today)
                placesSection
                Section {
                    Text("Подробности появятся после обновления справочника оборудования: автоматически по Wi-Fi или кнопкой «Обновить» в «Настройках».")
                        .foregroundStyle(.secondary)
                }
            }
            sourceSection
        }
        .navigationTitle(equipment.modelTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Главное

    private var mainSection: some View {
        Section {
            Label {
                Text(equipment.modelTitle)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: equipment.symbolName)
            }
            LabeledContent("Тип", value: equipment.kindTitle)
            if let longTitle = equipment.details?.modelLongTitle {
                LabeledContent("Модель полностью", value: longTitle)
            }
            if let serialNumber = equipment.serialNumber, !serialNumber.isEmpty {
                LabeledContent("Заводской номер") {
                    Text(serialNumber)
                        .textSelection(.enabled)
                }
            }
            if let details = equipment.details {
                if let networkAddress = details.networkAddress {
                    LabeledContent("Сетевой адрес", value: networkAddress)
                }
                if let firmwareVersion = details.firmwareVersion {
                    LabeledContent("Версия ПО", value: firmwareVersion)
                }
                if let hardwareVersion = details.hardwareVersion {
                    LabeledContent("Версия оборудования", value: hardwareVersion)
                }
                if let volts = details.batteryVolts {
                    LabeledContent("Батарея") {
                        if details.isBatteryLow {
                            Text("\(TextFormatting.reading(volts)) В — разряжена")
                                .foregroundStyle(.orange)
                        } else {
                            Text("\(TextFormatting.reading(volts)) В")
                        }
                    }
                } else if details.isBatteryLow {
                    LabeledContent("Батарея") {
                        Text("разряжена")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: - Поверка

    /// Раздел «Поверка» — для средств измерения всегда, для модемов — только если сервер что-то
    /// о поверке прислал (обычно у модемов её нет).
    @ViewBuilder
    private func calibrationSection(details: EquipmentDetails?, today: String) -> some View {
        let hasDates = equipment.lastCalibrationDay != nil || equipment.nextCalibrationDay != nil
        if equipment.isMeasuringInstrument || hasDates {
            calibrationRows(details: details, today: today)
        }
    }

    private func calibrationRows(details: EquipmentDetails?, today: String) -> some View {
        Section("Поверка") {
            if let lastDay = equipment.lastCalibrationDay {
                LabeledContent("Последняя", value: TextFormatting.calendarDay(lastDay))
            }
            if let nextDay = equipment.nextCalibrationDay {
                LabeledContent("Следующая") {
                    if equipment.isCalibrationOverdue(today: today) {
                        Label("\(TextFormatting.calendarDay(nextDay)) — срок истёк",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text(TextFormatting.calendarDay(nextDay))
                    }
                }
            }
            if equipment.lastCalibrationDay == nil && equipment.nextCalibrationDay == nil {
                Text("Даты поверки не указаны")
                    .foregroundStyle(.secondary)
            }
            if let details {
                if let years = details.calibrationIntervalYears {
                    LabeledContent("Межповерочный интервал", value: TextFormatting.years(years))
                }
                if let result = details.calibrationResultTitle {
                    LabeledContent("Результат") {
                        Text(result)
                            .foregroundStyle(details.calibrationResult == 0 ? .red : .primary)
                    }
                }
                if let organization = details.calibrationOrganization {
                    LabeledContent("Поверитель", value: organization)
                }
                if let registerNumber = details.calibrationRegisterNumber {
                    LabeledContent("Номер в реестре СИ", value: registerNumber)
                }
                if let sealNumber = details.sealNumber {
                    LabeledContent("Номер пломбы", value: sealNumber)
                }
                if let syncDay = details.calibrationSyncDay {
                    LabeledContent("Сверено с ФГИС «АРШИН»", value: TextFormatting.calendarDay(syncDay))
                }
                // Ссылка на запись о поверке — открывается в Safari (стандартный Link).
                if let arshinURL = details.arshinURL {
                    Link(destination: arshinURL) {
                        Label("Запись о поверке в ФГИС «АРШИН»", systemImage: "arrow.up.forward.square")
                    }
                }
            }
        }
    }

    // MARK: - Где установлено

    private var placesSection: some View {
        Section("Где установлено") {
            ForEach(equipment.places, id: \.nodeId) { place in
                // Объект из кэша — со ссылкой на его карточку; если списка объектов ещё нет — просто название.
                if let node = dataStore.node(withId: place.nodeId) {
                    NavigationLink(value: node) {
                        NodeRow(node: node)
                    }
                } else {
                    Label(place.title, systemImage: "building.2")
                }
            }
            if equipment.places.isEmpty {
                Text("Не установлено на объекте")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Связь

    @ViewBuilder
    private func connectionSection(details: EquipmentDetails) -> some View {
        // Приборы, которые опрашиваются через это оборудование (если это модем).
        let polledDevices = dataStore.equipment(usingModem: equipment.id)

        if !details.connections.isEmpty || !polledDevices.isEmpty {
            Section("Связь") {
                ForEach(Array(details.connections.enumerated()), id: \.offset) { _, connection in
                    EquipmentConnectionRow(connection: connection)
                }
                if !polledDevices.isEmpty {
                    ForEach(polledDevices) { device in
                        NavigationLink(value: device) {
                            CaptionedEquipmentLink(equipment: device, caption: "Опрашивается через этот модем")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Откуда сведения

    @ViewBuilder
    private var sourceSection: some View {
        if let updatedAt = dataStore.updatedAt(for: .equipment) {
            Section {
            } footer: {
                Text("Сведения из справочника оборудования, сохранённого на устройстве. Обновлено \(TextFormatting.updatedAt(updatedAt)).")
            }
        }
    }
}

/// Одно подключение прибора: «GPRS — ЛЭРС GSM Lite № 10084» (со ссылкой на модем, если он есть
/// в справочнике). Используется в карточке оборудования и на вкладке «Связь» карточки точки.
/// Ниже — дополнительные строки (решение владельца 2026-10-16): телефон SIM с кнопками «Позвонить»
/// и «SMS» (SMS открывается пустым — текст вызова модема не подставляем), способ вызова модема и
/// для Ethernet / IP — ссылка на страницу настройки прибора в браузере.
struct EquipmentConnectionRow: View {
    @Environment(DataStore.self) private var dataStore

    let connection: EquipmentConnection

    var body: some View {
        mainRow
        if let dialNumber = connection.dialNumber {
            PhoneNumberRow(number: dialNumber)
        }
        if let callTypeTitle = connection.callTypeTitle {
            LabeledContent("Вызов модема", value: callTypeTitle)
        }
        if let setupPageURL = connection.setupPageURL {
            // Адрес обычно внутренний (192.168.…) — откроется, только если телефон в той же сети или в VPN.
            Link(destination: setupPageURL) {
                Label("Открыть страницу настройки", systemImage: "safari")
            }
        }
    }

    @ViewBuilder
    private var mainRow: some View {
        let linkTitle = MeasurePoint.commLinkTitle(for: connection.commLinkType) ?? "Канал связи не указан"

        if let modemId = connection.modemEquipmentId, let modem = dataStore.equipment(withId: modemId) {
            NavigationLink(value: modem) {
                CaptionedEquipmentLink(equipment: modem, caption: linkTitle,
                                       captionSymbol: MeasurePoint.commLinkSymbolName(for: connection.commLinkType))
            }
            // Модем и при этом адрес Ethernet / IP — адрес отдельной строкой.
            if let ipAddressText = connection.ipAddressText {
                LabeledContent(connection.ipAddressLabel, value: ipAddressText)
                    .textSelection(.enabled)
            }
        } else if let modemTitle = connection.modemTitle {
            LabeledContent {
                Text(modemTitle)
            } label: {
                CommLinkLabel(commLinkType: connection.commLinkType, title: linkTitle)
            }
        } else if let ipAddressText = connection.ipAddressText {
            // Ethernet / IP без модема — одной строкой «Ethernet / IP   192.168.1.254:4002»
            // (раньше было две: голое «Ethernet / IP» и под ним «IP-адрес»). Адрес можно скопировать.
            LabeledContent {
                Text(ipAddressText)
                    .textSelection(.enabled)
            } label: {
                CommLinkLabel(commLinkType: connection.commLinkType, title: linkTitle)
            }
        } else {
            CommLinkLabel(commLinkType: connection.commLinkType, title: linkTitle)
        }
    }
}

/// Телефон SIM: номер (можно скопировать) и справа кнопки «Позвонить» и «SMS» — открывают «Телефон»
/// и «Сообщения» (позвонить и отправить пользователь решает сам). Где звонить нельзя (Mac, iPad без
/// iPhone рядом) — только номер: iOS сама сообщает, может ли открыть такие ссылки (canOpenURL; схемы tel и sms
/// перечислены в Info.plist — без этого iOS всегда отвечает «нет»).
private struct PhoneNumberRow: View {
    let number: String

    /// Могут ли «Телефон» и «Сообщения» открыться на этом устройстве (проверяем один раз).
    private static let canCall = phoneURL(scheme: "tel", number: "0").map { UIApplication.shared.canOpenURL($0) } ?? false
    private static let canSendSMS = phoneURL(scheme: "sms", number: "0").map { UIApplication.shared.canOpenURL($0) } ?? false

    var body: some View {
        HStack(spacing: 8) {
            LabeledContent("Телефон") {
                Text(number)
                    .textSelection(.enabled)
            }
            if PhoneNumberRow.canCall, let url = PhoneNumberRow.phoneURL(scheme: "tel", number: number) {
                actionLink(url: url, symbol: "phone.fill", label: "Позвонить")
            }
            if PhoneNumberRow.canSendSMS, let url = PhoneNumberRow.phoneURL(scheme: "sms", number: number) {
                actionLink(url: url, symbol: "message.fill", label: "Отправить SMS")
            }
        }
    }

    /// Кнопка-значок: зона нажатия 44×44 (минимум по правилам Apple), нажатие не уходит на всю строку.
    private func actionLink(url: URL, symbol: String, label: String) -> some View {
        Link(destination: url) {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    /// «tel:+79144216556» — в ссылке только цифры и «+» (пробелы, скобки и дефисы из номера убираем).
    static func phoneURL(scheme: String, number: String) -> URL? {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        if digits.isEmpty {
            return nil
        }
        return URL(string: "\(scheme):\(digits)")
    }
}

/// Тип связи со значком — везде одинаково: в карточках и в фильтре списка точек
/// (значки — MeasurePoint.commLinkSymbolName, аналоги значков программы ЛЭРС для ПК).
struct CommLinkLabel: View {
    let commLinkType: String?
    let title: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: MeasurePoint.commLinkSymbolName(for: commLinkType))
                .foregroundStyle(Color.accentColor)
        }
    }
}

/// Ссылка на оборудование в карточках: «СПТ943 № 13562» и мелкая подпись под ним.
struct CaptionedEquipmentLink: View {
    let equipment: Equipment
    /// Подпись под названием; по умолчанию — тип оборудования («Прибор учёта»).
    var caption: String? = nil
    /// Значок перед подписью (тип связи у модема); nil — без значка.
    var captionSymbol: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: equipment.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(equipment.shortTitle)
                if let captionSymbol {
                    CaptionLabel(title: caption ?? equipment.kindTitle, systemImage: captionSymbol)
                } else {
                    Text(caption ?? equipment.kindTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
