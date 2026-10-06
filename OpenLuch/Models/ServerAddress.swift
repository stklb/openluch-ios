import Foundation

// Адрес сервера ЛЭРС: имя сервера или IP-адрес, порт и протокол (http или https).
//
// На экране входа адрес вводится тремя частями (HTTPS/HTTP, имя, порт — с 2026-10-04), но разбор
// строки остался: им проверяется введённое имя и раскладывается адрес, вставленный целиком из браузера:
//   «http://192.168.1.10»       → http,  порт 10000 (порт ЛЭРС по умолчанию, а не 80!);
//   «http://192.168.1.10:8080»  → http,  порт 8080;
//   «https://my.lers.ru»        → https, порт 443;
//   «my.lers.ru»                → протокол не указан — считаем https (безопаснее), порт 443.
// Разбор строки — `init(parsing:)`, обратно в строку для поля ввода — `displayText`.
nonisolated struct ServerAddress: Codable, Equatable, Sendable {
    /// Имя сервера или IP-адрес, без «http://» и без порта: «192.168.1.10», «my.lers.ru».
    var host: String
    var port: Int
    var useHTTPS: Bool

    /// Порт ЛЭРС по умолчанию для http (так сервер настроен после установки).
    static let defaultHTTPPort = 10000
    /// Обычный порт https.
    static let defaultHTTPSPort = 443

    init(host: String, port: Int, useHTTPS: Bool) {
        self.host = host
        self.port = port
        self.useHTTPS = useHTTPS
    }

    // MARK: - Разбор строки, введённой пользователем

    /// Что не так с введённым адресом. Текст показывается под полем «Сервер».
    enum ParseError: Error, Equatable {
        case empty
        case unsupportedScheme
        case invalidPort
        case hasPath
        case invalid

        var message: String {
            switch self {
            case .empty:
                return "Укажите адрес сервера."
            case .unsupportedScheme:
                return "Адрес должен начинаться с http:// или https://."
            case .invalidPort:
                return "Порт — число от 1 до 65535, например: http://192.168.1.10:10000."
            case .hasPath:
                return "Укажите только адрес сервера, без пути после «/»."
            case .invalid:
                return "Адрес сервера введён неправильно. Пример: https://my.lers.ru или http://192.168.1.10."
            }
        }
    }

    /// Разбирает адрес из строки вида «[http(s)://]сервер[:порт][/]».
    /// Если что-то не так — выбрасывает `ParseError` с понятным текстом.
    init(parsing text: String) throws(ParseError) {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanText.isEmpty {
            throw .empty
        }
        if cleanText.contains(" ") {
            throw .invalid
        }

        // Протокол не указан — дописываем https://, чтобы дальше разбирать стандартным способом.
        let textWithScheme = cleanText.contains("://") ? cleanText : "https://" + cleanText

        // URLComponents — стандартный разборщик адресов: делит строку на протокол, сервер, порт, путь.
        // Порт он читает только если там цифры; если там буквы или пусто после «:» — вернёт nil.
        guard let components = URLComponents(string: textWithScheme) else {
            // Чаще всего сюда попадаем из-за порта с буквами: «my.lers.ru:443a».
            throw Self.looksLikeBadPort(textWithScheme) ? .invalidPort : .invalid
        }

        let useHTTPS: Bool
        switch components.scheme?.lowercased() {
        case "https":
            useHTTPS = true
        case "http":
            useHTTPS = false
        default:
            throw .unsupportedScheme
        }

        guard let host = components.host, Self.isValidHost(host) else {
            throw .invalid
        }
        // Логин/пароль в адресе («user@host»), «?…» и «#…» для адреса сервера не нужны.
        if components.user != nil || components.password != nil
            || components.query != nil || components.fragment != nil {
            throw .invalid
        }
        // Косую черту в конце («https://my.lers.ru/») разрешаем — так копируют из браузера.
        if !components.path.isEmpty && components.path != "/" {
            throw .hasPath
        }

        let port: Int
        if let enteredPort = components.port {
            guard enteredPort >= 1 && enteredPort <= 65535 else {
                throw .invalidPort
            }
            port = enteredPort
        } else if Self.looksLikeBadPort(textWithScheme) {
            // Двоеточие есть, а порта нет («my.lers.ru:») — это ошибка, а не «порт по умолчанию».
            throw .invalidPort
        } else {
            port = useHTTPS ? Self.defaultHTTPSPort : Self.defaultHTTPPort
        }

        self.init(host: host, port: port, useHTTPS: useHTTPS)
    }

    /// Похоже ли на адрес сервера: IP-адрес (IPv4 — четыре числа от 0 до 255 через точку)
    /// или доменное имя (части через точку из букв, цифр и «-»; последняя часть — не число).
    /// Примеры: «192.168.1.10», «my.lers.ru», «lers.local». Не подходят: «1», «my», «1.2.3», «300.1.1.1».
    /// Имена из одного слова («lersserver») не принимаем — нужен домен или IP (решение владельца 2026-10-04).
    static func isValidHost(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)

        // Только цифры и точки — значит, это IP-адрес: ровно четыре числа от 0 до 255.
        let isDigitsOnly = parts.allSatisfy { part in part.allSatisfy { $0.isASCII && $0.isNumber } }
        if isDigitsOnly {
            guard parts.count == 4 else {
                return false
            }
            return parts.allSatisfy { part in
                guard (1...3).contains(part.count), let number = Int(part) else {
                    return false
                }
                return number <= 255
            }
        }

        // Доменное имя: хотя бы две части («my.lers.ru», «lers.local»), не длиннее 253 символов.
        guard parts.count >= 2, text.count <= 253 else {
            return false
        }
        for part in parts {
            // Каждая часть — от 1 до 63 символов: буквы (в том числе русские), цифры и «-» не по краям.
            guard (1...63).contains(part.count),
                  part.first != "-", part.last != "-",
                  part.allSatisfy({ $0.isLetter || ($0.isASCII && $0.isNumber) || $0 == "-" }) else {
                return false
            }
        }
        // Последняя часть (зона: «ru», «local», «рф») — не одни цифры и не короче двух символов.
        guard let zone = parts.last, zone.count >= 2, !zone.allSatisfy({ $0.isNumber }) else {
            return false
        }
        return true
    }

    /// true — после имени сервера стоит «:» (значит, пытались указать порт).
    private static func looksLikeBadPort(_ textWithScheme: String) -> Bool {
        guard let schemeEnd = textWithScheme.range(of: "://") else {
            return false
        }
        let afterScheme = textWithScheme[schemeEnd.upperBound...]
        let hostAndPort = afterScheme.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return hostAndPort.contains(":")
    }

    // MARK: - Адрес в виде строки

    /// Адрес для поля ввода: протокол и сервер, порт — только если он не «по умолчанию».
    /// Например: «https://my.lers.ru», «http://192.168.1.10», «http://192.168.1.10:8080».
    /// Если разобрать эту строку через `init(parsing:)`, получится тот же адрес.
    var displayText: String {
        let scheme = useHTTPS ? "https" : "http"
        let defaultPort = useHTTPS ? Self.defaultHTTPSPort : Self.defaultHTTPPort
        if port == defaultPort {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port)"
    }

    /// Готовый адрес для запросов, например «http://192.168.1.10:10000» или «https://my.lers.ru».
    /// nil — если адрес неправильный (пустой, с лишними символами, неверный порт).
    var baseURL: URL? {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleanHost.isEmpty {
            return nil
        }
        // «/», «:» и пробелы в имени сервера означают, что вместе с ним попало что-то лишнее
        // (протокол, порт или путь) — такой адрес не принимаем.
        if cleanHost.contains("/") || cleanHost.contains(":") || cleanHost.contains(" ") {
            return nil
        }
        if port < 1 || port > 65535 {
            return nil
        }

        var components = URLComponents()
        components.scheme = useHTTPS ? "https" : "http"
        components.host = cleanHost
        // Стандартный порт протокола (443 для https, 80 для http) в адресе не пишем.
        let isStandardPort = (useHTTPS && port == 443) || (!useHTTPS && port == 80)
        if !isStandardPort {
            components.port = port
        }
        return components.url
    }
}
