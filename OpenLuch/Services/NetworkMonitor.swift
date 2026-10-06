import Foundation
import Network

// Наблюдатель за сетью телефона: есть ли сейчас выход в сеть и какой (Wi-Fi или сотовая).
// Использует стандартный NWPathMonitor — система сама сообщает, когда сеть появляется и пропадает.
//
// Зачем это нужно:
//   1. Правило обновления кэша: у Wi-Fi и сотовой сети свои сроки годности (CacheFreshness),
//      поэтому нужно знать тип подключения (ConnectionKind).
//   2. URLSession с waitsForConnectivity (см. APIClient) одинаково «ждёт сеть» и когда интернета
//      нет, и когда интернет есть, но сервер не отвечает (неверный порт, выключен, ошибка в имени).
//      Отличить эти случаи можно только спросив систему, есть ли сеть. Если есть — виноват сервер.
//
// Один наблюдатель на всё приложение (NetworkMonitor.shared). Запускается при старте
// приложения (OpenLuchApp), чтобы к первому запросу система уже успела сообщить состояние сети.

/// Тип подключения — для сроков автообновления (у Wi-Fi и сотовой сети они свои).
nonisolated enum ConnectionKind: Equatable, Sendable {
    /// Сети нет (или система ещё не сообщила).
    case noNetwork
    /// Сотовая сеть — или Wi-Fi, который нельзя считать безлимитным: «дорогое» подключение
    /// (например, раздача интернета с другого телефона) или включена «Экономия данных».
    /// Автоматически по такому подключению ничего не загружаем.
    case cellular
    /// Обычный Wi-Fi (или проводная сеть): не сотовая, не «дорогая», без «Экономии данных».
    case wifi

    /// Подпись для пользователя.
    var title: String {
        switch self {
        case .noNetwork:
            return "Нет сети"
        case .cellular:
            return "Сотовая сеть"
        case .wifi:
            return "Wi-Fi"
        }
    }
}

nonisolated final class NetworkMonitor: @unchecked Sendable {
    // @unchecked Sendable: состояние меняется в фоновой очереди, а читается из любых потоков,
    // поэтому доступ защищён замком (NSLock) — одновременно с полями работает только один поток.

    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    /// С какого момента сеть есть без перерыва. nil — сети нет или система ещё не сообщила.
    private var connectedSince: Date?
    private var kind: ConnectionKind = .noNetwork
    /// true — система уже сообщила о сети хотя бы раз (до этого kind — просто «нет сети» по умолчанию).
    private var isKnown = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(isConnected: path.status == .satisfied, kind: NetworkMonitor.connectionKind(of: path))
        }
        monitor.start(queue: DispatchQueue(label: "ru.stklb.openluch.network-monitor"))
    }

    /// Определяет тип подключения по сведениям системы о текущем «пути» в сеть.
    private static func connectionKind(of path: NWPath) -> ConnectionKind {
        if path.status != .satisfied {
            return .noNetwork
        }
        // isExpensive — «дорогое» подключение: сотовая сеть или Wi-Fi через раздачу с телефона.
        // isConstrained — пользователь включил «Экономию данных» (Low Data Mode).
        if path.usesInterfaceType(.cellular) || path.isExpensive || path.isConstrained {
            return .cellular
        }
        return .wifi
    }

    private func update(isConnected: Bool, kind: ConnectionKind) {
        lock.lock()
        self.kind = kind
        isKnown = true
        if isConnected {
            // Запоминаем момент появления сети (если сеть и так была — момент не меняем).
            if connectedSince == nil {
                connectedSince = Date()
            }
        } else {
            connectedSince = nil
        }
        lock.unlock()
    }

    /// Момент, с которого сеть есть без перерыва, — или nil, если сети нет (или пока неизвестно).
    var networkAvailableSince: Date? {
        lock.lock()
        defer { lock.unlock() }
        return connectedSince
    }

    /// Тип подключения, дождавшись первого сообщения системы (не дольше 3 секунд).
    /// Нужно в фоне: iOS запускает приложение и сразу даёт задачу обновления — а система
    /// сообщает о сети чуть позже, и без ожидания мы бы решили, что сети нет.
    func connectionKindWhenKnown() async -> ConnectionKind {
        for _ in 0..<30 {
            if hasFirstUpdate {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return connectionKind
    }

    private var hasFirstUpdate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isKnown
    }

    /// Текущий тип подключения.
    var connectionKind: ConnectionKind {
        lock.lock()
        defer { lock.unlock() }
        return kind
    }

    /// Есть ли сейчас сеть. Пока система не сообщила — считаем, что нет (осторожный вариант:
    /// так запрос продолжит ждать сеть, а не прервётся с ошибкой «сервер недоступен»).
    var isNetworkAvailable: Bool {
        return networkAvailableSince != nil
    }
}
