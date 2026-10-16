import XCTest
@testable import OpenLuch

// Справочник оборудования: разбор ответа сервера, даты поверки, сохранение в кэш.
final class EquipmentTests: XCTestCase {

    /// Пример — настоящий ответ my.lers.ru, сокращённый до 6 единиц оборудования
    /// (из параметров опроса оставлены только каналы связи и модемы, описания интерфейсов моделей вырезаны).
    private func loadSample() throws -> (response: EquipmentListResponse, data: Data) {
        let data = try SampleFiles.data(named: "equipment")
        let response = try JSONDecoder().decode(EquipmentListResponse.self, from: data)
        return (response, data)
    }

    func testEquipmentListIsBuiltFromServerResponse() throws {
        let equipment = Equipment.makeList(from: try loadSample().response)
        XCTAssertEqual(equipment.count, 6)

        // Отсортировано по модели, внутри модели — по номеру.
        XCTAssertEqual(equipment.map { $0.shortTitle },
                       ["КМ-5-4 № 018395", "ЛЭРС GSM Lite № 10084", "ЛЭРС GSM Lite № 19860",
                        "ЛЭРС GSM Mini № 00005", "СЕ 303 № 009233029000075", "СПТ943 № 9032"])

        // Вычислитель с датами поверки, установлен на одном объекте.
        let meter = try XCTUnwrap(equipment.first { $0.id == 56 })
        XCTAssertEqual(meter.modelTitle, "КМ-5-4")
        XCTAssertEqual(meter.serialNumber, "018395")
        XCTAssertEqual(meter.lastCalibrationDay, "2024-07-02")
        XCTAssertEqual(meter.nextCalibrationDay, "2027-07-01")
        XCTAssertEqual(meter.placesTitle, "ТСЖ \"Семь ветров\"")
        XCTAssertEqual(meter.symbolName, "gauge.with.needle")

        // Общий модем — на двух объектах; это не измерительный прибор.
        let modem = try XCTUnwrap(equipment.first { $0.id == 11628 })
        XCTAssertEqual(modem.places.count, 2)
        XCTAssertEqual(modem.symbolName, "antenna.radiowaves.left.and.right")
        XCTAssertNil(modem.lastCalibrationDay)
    }

    func testDetailsForCardAreTakenFromTheSameResponse() throws {
        let equipment = Equipment.makeList(from: try loadSample().response)

        // Вычислитель КМ-5-4: версия ПО, межповерочный интервал модели, два канала связи, второй — через модем.
        let meter = try XCTUnwrap(equipment.first { $0.id == 56 })
        let details = try XCTUnwrap(meter.details)
        XCTAssertEqual(meter.kindTitle, "Прибор учёта")
        XCTAssertEqual(details.firmwareVersion, "02.26")
        XCTAssertEqual(details.networkAddress, "018395")
        XCTAssertEqual(details.calibrationIntervalYears, 4)
        XCTAssertEqual(details.calibrationSyncDay, "2024-12-03")
        // Пустые строки с сервера («sealNumber": "") не превращаются в пустые строчки карточки.
        XCTAssertNil(details.sealNumber)
        XCTAssertNil(details.comment)
        XCTAssertEqual(details.connections.map { $0.commLinkType }, ["Gsm", "Gprs"])
        XCTAssertEqual(details.connections[1].modemEquipmentId, 8919)
        XCTAssertEqual(details.connections[1].modemTitle, "ЛЭРС GSM Lite № 10084")
        // IP-адрес показывается только у канала Ethernet / IP.
        XCTAssertNil(details.connections[1].ipAddressText)
        let ethernet = try XCTUnwrap(equipment.first { $0.id == 905 }?.details?.connections.first)
        XCTAssertEqual(ethernet.ipAddressText, "192.168.1.222:4001")
        XCTAssertEqual(ethernet.ipAddressLabel, "IP-адрес")

        // У модема интервала поверки нет (0 у модели) и опрашивать его не через что.
        let modem = try XCTUnwrap(equipment.first { $0.id == 8919 })
        XCTAssertEqual(modem.kindTitle, "Коммуникационное оборудование")
        XCTAssertNil(modem.details?.calibrationIntervalYears)
        XCTAssertEqual(modem.details?.connections.count, 0)
    }

    /// Адрес Ethernet-подключения бывает IP-адресом или доменом; порт приходит отдельно.
    func testEthernetAddressText() {
        func connection(_ host: String, _ port: Int?) -> EquipmentConnection {
            return EquipmentConnection(commLinkType: "Ip", modemEquipmentId: nil, modemTitle: nil,
                                       internetHost: host, internetPort: port)
        }
        XCTAssertEqual(connection("teplo.example.ru", 4001).ipAddressText, "teplo.example.ru:4001")
        XCTAssertEqual(connection("teplo.example.ru", 4001).ipAddressLabel, "Адрес")
        XCTAssertEqual(connection("teplo.example.ru", nil).ipAddressText, "teplo.example.ru")
        XCTAssertEqual(connection("10.0.0.5", 23).ipAddressLabel, "IP-адрес")
        // Домен из цифр и точек, но не IP.
        XCTAssertEqual(connection("1.2.3.example", 23).ipAddressLabel, "Адрес")
        XCTAssertEqual(connection("fe80::1", 4001).ipAddressText, "[fe80::1]:4001")
        XCTAssertEqual(connection("fe80::1", 4001).ipAddressLabel, "IP-адрес")
    }

    /// Номер SIM и способ вызова модема берём (решение владельца 2026-10-16); для Ethernet — страница настройки.
    func testConnectionPhoneAndSetupPage() throws {
        let equipment = Equipment.makeList(from: try loadSample().response)
        let device = try XCTUnwrap(equipment.first { $0.id == 56 }?.details)
        let csd = try XCTUnwrap(device.connections.first { $0.commLinkType == "Gsm" })
        let gprs = try XCTUnwrap(device.connections.first { $0.commLinkType == "Gprs" })
        XCTAssertEqual(csd.dialNumber, "+70000000000")
        XCTAssertNil(csd.callTypeTitle, "None — способ вызова не задан")
        XCTAssertEqual(gprs.callTypeTitle, "SMS")
        XCTAssertNil(gprs.setupPageURL)

        let ethernet = EquipmentConnection(commLinkType: "Ip", modemEquipmentId: nil, modemTitle: nil,
                                           internetHost: "192.168.1.156", internetPort: 4001)
        XCTAssertEqual(ethernet.setupPageURL?.absoluteString, "http://192.168.1.156")
        let ipv6 = EquipmentConnection(commLinkType: "Ip", modemEquipmentId: nil, modemTitle: nil,
                                       internetHost: "fe80::1", internetPort: 4001)
        XCTAssertEqual(ipv6.setupPageURL?.absoluteString, "http://[fe80::1]")
    }

    func testArshinLink() throws {
        let equipment = Equipment.makeList(from: try loadSample().response)

        // Поверка синхронизирована с «АРШИН» — есть номер записи и ссылка на неё.
        let synced = try XCTUnwrap(equipment.first { $0.id == 905 }?.details)
        XCTAssertEqual(synced.calibrationResultId, "1-355640981")
        XCTAssertEqual(synced.arshinURL?.absoluteString, "https://fgis.gost.ru/fundmetrology/cm/results/1-355640981")

        // Нет номера записи — нет и ссылки.
        let notSynced = try XCTUnwrap(equipment.first { $0.id == 56 }?.details)
        XCTAssertNil(notSynced.arshinURL)
    }

    func testMissingModelAndNodeDoNotBreakTheList() {
        // Модели и объекта в ответе нет — список всё равно собирается, с понятными подписями.
        let json = #"{"list":[{"id":1,"equipmentModelId":999,"serialNumber":"7"}],"modelList":[],"nodes":null,"nodeEquipment":[{"nodeId":5,"equipmentId":1}]}"#
        let response = try? JSONDecoder().decode(EquipmentListResponse.self, from: Data(json.utf8))
        let equipment = Equipment.makeList(from: try! XCTUnwrap(response))
        XCTAssertEqual(equipment.first?.modelTitle, "Модель не указана")
        XCTAssertEqual(equipment.first?.placesTitle, "Объект № 5")
    }

    func testCalibrationDates() {
        XCTAssertEqual(Equipment.calendarDay(fromServerText: "2024-07-02T00:00:00"), "2024-07-02")
        XCTAssertEqual(Equipment.calendarDay(fromServerText: "2024-07-02T00:00:00.0000000Z"), "2024-07-02")
        XCTAssertNil(Equipment.calendarDay(fromServerText: nil))
        XCTAssertNil(Equipment.calendarDay(fromServerText: "не дата"))
        XCTAssertEqual(TextFormatting.calendarDay("2024-07-02"), "02.07.2024")
        XCTAssertEqual(TextFormatting.shortCalendarDay("2024-07-02"), "02.07.24")
        XCTAssertEqual(TextFormatting.shortCalendarDay("не дата"), "не дата")

        let item = Equipment(id: 1, modelTitle: "СПТ943", modelCapabilities: nil, serialNumber: nil,
                             lastCalibrationDay: "2022-07-01", nextCalibrationDay: "2026-07-01", places: [])
        XCTAssertTrue(item.isCalibrationOverdue(today: "2026-10-03"))
        XCTAssertTrue(item.isCalibrationOverdue(today: "2026-07-01"))
        XCTAssertFalse(item.isCalibrationOverdue(today: "2026-06-30"))
    }

    func testEquipmentIsCachedAndMuchSmallerThanServerResponse() async throws {
        let sample = try loadSample()
        let equipment = Equipment.makeList(from: sample.response)
        let directory = FileManager.default.temporaryDirectory.appending(path: "EquipmentTests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = CacheStore(directory: directory)

        try await store.saveEquipment(equipment, responseBytes: sample.data.count)
        let loaded = await store.loadEquipment()
        let cached = try XCTUnwrap(loaded)
        XCTAssertEqual(cached.equipment, equipment)
        XCTAssertEqual(cached.responseBytes, sample.data.count)

        // В кэше только то, что показываем, — в разы меньше ответа (даже сокращённого).
        let cacheSize = await store.totalSizeInBytes()
        XCTAssertLessThan(cacheSize, Int64(sample.data.count) / 5)
    }
}
