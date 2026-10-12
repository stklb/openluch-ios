import XCTest
@testable import OpenLuch

// Пробные запросы для определения проблем со связью (ConnectionProblemDetector).
//
// Первый тест работает без интернета. Остальные ходят к настоящим сайтам (Госуслуги, Apple, Google),
// поэтому, как и DemoServerTests, по умолчанию ПРОПУСКАЮТСЯ — включаются переменной LERS_DEMO_TESTS=1.
final class InternetProbeTests: XCTestCase {

    private func requireInternetTests() throws {
        guard ProcessInfo.processInfo.environment["LERS_DEMO_TESTS"] == "1" else {
            throw XCTSkip("Тесты с интернетом выключены (нужна переменная LERS_DEMO_TESTS=1)")
        }
    }

    /// Сайт молчит — по истечении времени ответ «нет», а не бесконечное ожидание.
    func testSilentSiteGivesNoAfterTimeout() async {
        // 10.255.255.1 — внутренний адрес, который никому не принадлежит: соединение просто не устанавливается.
        let silent = InternetProbe(url: URL(string: "http://10.255.255.1/")!, method: "HEAD",
                                    isExpectedAnswer: { _, _ in true })
        let startedAt = Date()
        let answered = await InternetProbe.anyAnswers([silent], within: .seconds(1))
        XCTAssertFalse(answered)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }

    /// При обычном интернете отвечают и «разрешённые», и «запрещённые» сайты.
    func testRealProbesAnswer() async throws {
        try requireInternetTests()
        for probe in InternetProbe.allowed + InternetProbe.blocked {
            let answered = await probe.answers()
            XCTAssertTrue(answered, "Не ответил \(probe.url)")
        }
    }

    /// Весь путь: запрос к серверу не удался → пробы отвечают (интернет есть) → «сервер не отвечает»;
    /// сервер ответил → строка исчезла.
    @MainActor
    func testServerFailureWithWorkingInternetShowsServerUnreachable() async throws {
        try requireInternetTests()
        // Дождаться, пока система сообщит о сети (иначе детектор решит «сети нет»).
        _ = await NetworkMonitor.shared.connectionKindWhenKnown()
        let detector = ConnectionProblemDetector.shared
        detector.networkDidChange()  // сбросить выводы прошлых тестов

        detector.serverRequestFailed()
        for _ in 0..<50 where detector.problem != .serverUnreachable {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(detector.problem, .serverUnreachable)

        detector.serverDidRespond()
        XCTAssertNil(detector.problem)
    }

    /// Перенаправления не выполняются: Госуслуги отвечают 307 (переход на https), и именно его мы и видим.
    func testRedirectIsNotFollowed() async throws {
        try requireInternetTests()
        let probe = InternetProbe(url: URL(string: "http://gosuslugi.ru/")!, method: "HEAD",
                                   isExpectedAnswer: { response, _ in (300..<400).contains(response.statusCode) })
        let answered = await probe.answers()
        XCTAssertTrue(answered)
    }
}
