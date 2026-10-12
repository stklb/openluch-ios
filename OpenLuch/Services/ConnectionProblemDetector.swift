import Foundation
import Observation
import UIKit

// Определение, почему сервер ЛЭРС не отвечает: нет интернета, «белые списки» мобильного интернета
// или интернет есть, а не отвечает сам сервер. Результат — оранжевая строка на экранах
// (ConnectionProblemNotice) вместо непонятного «Сервер не найден».
//
// Белые списки: в некоторых регионах оператор иногда включает режим, при котором по сотовой сети
// открываются только сайты из утверждённого перечня (Госуслуги, ВКонтакте, Яндекс…).
// Сервер ЛЭРС в перечень не входит, поэтому приложение не может получить данные.
//
// Как определяем. Если сервер молчит 2 секунды (или запрос к нему не удался из-за связи),
// одновременно отправляем три крошечных запроса (около 1 КБ на всё):
//   • к сайту, который точно есть в перечне, — Госуслуги (запасной — api.vk.ru);
//   • к двум сайтам, которых в перечне точно нет, — проверка интернета Apple (её использует
//     сама iOS для Wi-Fi) и такая же проверка Google.
// Вывод пересматриваем при каждом ответе:
//   • Apple или Google ответили → интернет есть («сервер не отвечает» показываем, только когда
//     запрос к серверу уже завершился ошибкой: иначе сервер, возможно, просто долго думает,
//     например формирует отчёт);
//   • сотовая сеть, Госуслуги ответили, а Apple и Google молчат уже 2 секунды → белые списки
//     (по Wi-Fi белых списков не бывает: там ответ Госуслуг значит «интернет есть»);
//   • никто не ответил за 5 секунд → нет интернета. Если сети у телефона нет совсем
//     (так говорит NetworkMonitor), «нет интернета» — сразу, без запросов.
// Решение владельца (2026-10-13): лучше быстро показать и потом убрать, чем заставлять ждать.
// Поэтому ответов ждём до 20 секунд и вывод меняем, когда они приходят (на EDGE пинг больше секунды,
// Госуслуги отвечают за 3–4 с).
//
// Строка убирается, когда сервер ответил или сменилась сеть (например, подключились к Wi-Fi).
// «Интернет есть» перепроверяем не чаще раза в 15 минут в одной сети, остальное — не чаще раза в минуту.
// Пока приложение свёрнуто (обновление в фоне), не проверяем: показывать строку некому.
//
// Запросы — по простому HTTP, а не HTTPS: установка защищённого соединения стоила бы 3–6 КБ на сайт.
// Обращаемся по именам сайтов, а не по IP: адреса у Apple и Google меняются даже между двумя
// запросами, а без имени сайта сервер отвечает «404». Замеры — docs/api-notes.md.

/// Что не так со связью — для оранжевой строки на экранах.
enum ConnectionProblem: Equatable {
    /// Ни один сайт не отвечает (или у телефона нет сети).
    case noInternet
    /// Мобильный интернет работает по белым спискам.
    case whitelist
    /// Интернет есть, а сервер ЛЭРС не отвечает.
    case serverUnreachable

    /// Текст строки.
    var message: String {
        switch self {
        case .noInternet:
            return "Нет интернета."
        case .whitelist:
            return "Обнаружены белые списки. Подключитесь к Wi-Fi."
        case .serverUnreachable:
            return "Интернет есть, сервер ЛЭРС не отвечает."
        }
    }

    /// Значок строки.
    var systemImage: String {
        switch self {
        case .noInternet:
            return "network.slash"
        case .whitelist:
            // Перечёркнутая антенна: дело в мобильной сети.
            return "antenna.radiowaves.left.and.right.slash"
        case .serverUnreachable:
            return "server.rack"
        }
    }
}

@Observable
final class ConnectionProblemDetector {

    /// Один на всё приложение: его читают экраны и вызывает APIClient.
    static let shared = ConnectionProblemDetector()

    /// Через сколько секунд молчания сервера начинать проверку (используется в APIClient).
    nonisolated static let serverSilenceDelay: TimeInterval = 2
    /// Сколько Apple и Google должны промолчать, прежде чем решить «белые списки».
    static let blockedSilenceDelay: Duration = .seconds(2)
    /// Сколько должны промолчать все сайты, прежде чем решить «нет интернета».
    static let noInternetDelay: Duration = .seconds(5)
    /// Сколько всего ждём ответа проб (на медленной связи ответ может прийти поздно).
    static let probeTimeout: Duration = .seconds(20)
    /// Как часто перепроверять в одной сети, если в прошлый раз интернет был.
    static let internetWorksRecheckInterval: TimeInterval = 15 * 60
    /// Как часто перепроверять в остальных случаях.
    static let recheckInterval: TimeInterval = 60

    /// Что показывать на экранах. nil — ничего.
    private(set) var problem: ConnectionProblem?

    // MARK: - Внутреннее состояние

    /// Что показали пробы в текущей сети.
    private enum ProbeResult {
        case noInternet
        case whitelist
        case internetWorks
    }

    /// Последний вывод по пробам в этой сети. nil — вывода нет.
    private var probeResult: ProbeResult?
    /// true — последний запрос к серверу завершился ошибкой связи (и сервер с тех пор не отвечал).
    private var serverFailed = false
    /// Идёт ли сейчас проверка.
    private var isChecking = false
    /// Когда начиналась последняя проверка. nil — в этой сети ещё не проверяли.
    private var lastCheckAt: Date?
    /// «Номер» текущей сети: увеличивается при каждой её смене. Если сеть сменилась во время
    /// проверки, её результат уже ничего не значит.
    private var networkGeneration = 0
    /// Когда сервер последний раз ответил. Если он ответил во время проверки — её результат не нужен.
    private var serverRespondedAt: Date?

    /// Состояние текущей проверки: кто уже ответил и сколько времени прошло.
    private var allowedProbeAnswered = false
    private var blockedProbeAnswered = false
    private var isBlockedSilenceOver = false
    private var isNoInternetDelayOver = false
    private var checkStartedAt = Date.distantPast
    private var checkGeneration = 0
    private var checkIsCellular = false

    // Явно говорим: при удалении объекта ничего не нужно делать в главном потоке (см. CLAUDE.md).
    nonisolated deinit {}

    private init() {}

    // MARK: - Сообщения от APIClient и NetworkMonitor

    /// Сервер молчит, или запрос к нему не удался по непонятной причине. Если нужно — запускает проверку.
    func serverIsSilent() {
        startCheckIfNeeded()
    }

    /// Запрос к серверу завершился ошибкой связи («не найден», «не ответил вовремя», «нет соединения»).
    func serverRequestFailed() {
        serverFailed = true
        updateProblem()
        startCheckIfNeeded()
    }

    /// Сервер ответил (любым кодом) — значит, связь с ним есть и строка больше не нужна.
    func serverDidRespond() {
        serverRespondedAt = Date()
        serverFailed = false
        // «Интернет есть» по-прежнему верно, а «нет интернета» и «белые списки» — уже нет.
        if probeResult != .internetWorks {
            probeResult = nil
        }
        updateProblem()
    }

    /// Сеть сменилась (например, подключились к Wi-Fi или вернулась сотовая сеть):
    /// прежние выводы больше не верны, в новой сети можно проверить заново.
    func networkDidChange() {
        networkGeneration += 1
        lastCheckAt = nil
        probeResult = nil
        serverFailed = false
        updateProblem()
    }

    // MARK: - Проверка

    private func startCheckIfNeeded() {
        guard !isChecking else {
            return
        }
        // Приложение свёрнуто (iOS обновляет списки в фоне) — показывать строку некому.
        guard UIApplication.shared.applicationState == .active else {
            return
        }
        // Сети у телефона нет совсем — спрашивать сайты бессмысленно.
        if !NetworkMonitor.shared.isNetworkAvailable {
            probeResult = .noInternet
            updateProblem()
            return
        }
        // Недавно уже проверяли — результат ещё действует.
        if let lastCheckAt {
            let interval = probeResult == .internetWorks
                ? ConnectionProblemDetector.internetWorksRecheckInterval
                : ConnectionProblemDetector.recheckInterval
            if Date().timeIntervalSince(lastCheckAt) < interval {
                return
            }
        }
        Task {
            await runCheck()
        }
    }

    private func runCheck() async {
        isChecking = true
        allowedProbeAnswered = false
        blockedProbeAnswered = false
        isBlockedSilenceOver = false
        isNoInternetDelayOver = false
        checkStartedAt = Date()
        checkGeneration = networkGeneration
        checkIsCellular = NetworkMonitor.shared.connectionKind == .cellular
        lastCheckAt = checkStartedAt

        // Все пробы — одновременно. Каждая, ответив, пересматривает вывод.
        let allowedProbe = Task {
            if await InternetProbe.anyAnswers(InternetProbe.allowed, within: ConnectionProblemDetector.probeTimeout) {
                allowedProbeAnswered = true
                updateProbeResult()
            }
        }
        let blockedProbe = Task {
            if await InternetProbe.anyAnswers(InternetProbe.blocked, within: ConnectionProblemDetector.probeTimeout) {
                blockedProbeAnswered = true
                updateProbeResult()
            }
        }

        // Через 2 секунды молчания Apple и Google — можно решать «белые списки».
        try? await Task.sleep(for: ConnectionProblemDetector.blockedSilenceDelay)
        isBlockedSilenceOver = true
        updateProbeResult()

        // Через 5 секунд общего молчания — «нет интернета».
        try? await Task.sleep(for: ConnectionProblemDetector.noInternetDelay - ConnectionProblemDetector.blockedSilenceDelay)
        isNoInternetDelayOver = true
        updateProbeResult()

        await allowedProbe.value
        await blockedProbe.value
        isChecking = false
    }

    /// Вывод по тому, кто из сайтов уже ответил и сколько прошло времени.
    private func updateProbeResult() {
        // Сеть сменилась или сервер ответил после начала проверки — её результат уже не нужен.
        let serverRespondedDuringCheck = serverRespondedAt.map { $0 >= checkStartedAt } ?? false
        guard checkGeneration == networkGeneration, !serverRespondedDuringCheck else {
            return
        }
        if blockedProbeAnswered || (allowedProbeAnswered && !checkIsCellular) {
            // Apple или Google ответили (или Госуслуги — по Wi-Fi) — интернет обычный.
            probeResult = .internetWorks
        } else if allowedProbeAnswered && isBlockedSilenceOver {
            // Сотовая сеть: Госуслуги ответили, а Apple и Google молчат уже 2 секунды.
            probeResult = .whitelist
        } else if !allowedProbeAnswered && isNoInternetDelayOver {
            // Никто не ответил за 5 секунд.
            probeResult = .noInternet
        }
        updateProblem()
    }

    /// Что показать на экранах — по выводу проб и по тому, не завершился ли запрос к серверу ошибкой.
    private func updateProblem() {
        switch probeResult {
        case .noInternet:
            problem = .noInternet
        case .whitelist:
            problem = .whitelist
        case .internetWorks:
            problem = serverFailed ? .serverUnreachable : nil
        case nil:
            problem = nil
        }
    }
}

// MARK: - Пробные запросы

/// Один пробный запрос к сайту и правило, по которому считаем, что сайт ответил.
nonisolated struct InternetProbe: Sendable {
    let url: URL
    /// HEAD — просим только заголовки, без тела (меньше трафика).
    let method: String
    /// Ответ «настоящий»: например, у Google строго код 204. Если вместо сайта ответила
    /// заглушка оператора («доступ ограничен»), этот ответ не засчитывается.
    let isExpectedAnswer: @Sendable (HTTPURLResponse, Data) -> Bool

    /// Сайты, которые точно есть в белых списках (сверено с общественным перечнем, docs/api-notes.md).
    /// Подойдёт любой ответ: даже заглушка оператора значит, что интернет есть.
    static let allowed: [InternetProbe] = [
        // Ответ — перенаправление на https, 89 байт.
        InternetProbe(url: URL(string: "http://gosuslugi.ru/")!, method: "HEAD",
                       isExpectedAnswer: { _, _ in true }),
        // Запасной. Именно поддомен: голых vk.com и vk.ru в перечне нет. Ответ ~300 байт.
        InternetProbe(url: URL(string: "http://api.vk.ru/")!, method: "HEAD",
                       isExpectedAnswer: { _, _ in true }),
    ]

    /// Сайты, которых в белых списках точно нет, но которые почти всегда работают.
    static let blocked: [InternetProbe] = [
        // Проверка интернета Apple (её использует сама iOS): код 200 и слово «Success», ~460 байт.
        InternetProbe(url: URL(string: "http://captive.apple.com/hotspot-detect.html")!, method: "GET",
                       isExpectedAnswer: { response, body in
                           response.statusCode == 200 && String(decoding: body, as: UTF8.self).contains("Success")
                       }),
        // Такая же проверка Google (её использует Android): строго код 204 без тела, 127 байт.
        InternetProbe(url: URL(string: "http://www.gstatic.com/generate_204")!, method: "GET",
                       isExpectedAnswer: { response, _ in response.statusCode == 204 }),
    ]

    /// Отдельное «соединение» для проб: без кэша, без cookie, без ожидания сети
    /// и без перехода по перенаправлениям (нам хватает самого первого ответа).
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirectsDelegate(), delegateQueue: nil)
    }()

    /// Ответил ли сайт как ожидается. Любая ошибка (нет ответа, обрыв) — false.
    @concurrent
    func answers() async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = method
        do {
            let (data, response) = try await InternetProbe.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return isExpectedAnswer(httpResponse, data)
        } catch {
            return false
        }
    }

    /// Ответил ли хотя бы один из сайтов за отведённое время. Запросы идут одновременно;
    /// как только один ответил — остальные отменяем.
    @concurrent
    static func anyAnswers(_ probes: [InternetProbe], within timeout: Duration) async -> Bool {
        return await withTaskGroup(of: Bool?.self) { group in
            for probe in probes {
                group.addTask {
                    await probe.answers()
                }
            }
            // Будильник: nil — «время вышло».
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }

            var failedCount = 0
            for await result in group {
                switch result {
                case .some(true):
                    group.cancelAll()
                    return true
                case .none:
                    group.cancelAll()
                    return false
                case .some(false):
                    failedCount += 1
                    if failedCount == probes.count {
                        group.cancelAll()
                        return false
                    }
                }
            }
            return false
        }
    }
}

/// Не переходить по перенаправлениям: ответ «перейдите на https://…» уже доказывает, что сайт доступен,
/// а переход стоил бы ещё одного (защищённого, тяжёлого) соединения.
private nonisolated final class NoRedirectsDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Вариант с completionHandler, а не async: на async-версии этого метода
        // компилятор Swift 6.4 падает (проверено 2026-10-13).
        completionHandler(nil)
    }
}
