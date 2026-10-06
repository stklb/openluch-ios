import XCTest
@testable import OpenLuch

final class ServerAddressTests: XCTestCase {

    func testBaseURL() {
        XCTAssertEqual(ServerAddress(host: "192.168.1.10", port: 10000, useHTTPS: false).baseURL?.absoluteString,
                       "http://192.168.1.10:10000")
        // Стандартный порт HTTPS в адрес не пишем, нестандартный — пишем.
        XCTAssertEqual(ServerAddress(host: "my.lers.ru", port: 443, useHTTPS: true).baseURL?.absoluteString,
                       "https://my.lers.ru")
        XCTAssertEqual(ServerAddress(host: "lers.example.ru", port: 8443, useHTTPS: true).baseURL?.absoluteString,
                       "https://lers.example.ru:8443")
        // Пробелы вокруг имени сервера не мешают.
        XCTAssertEqual(ServerAddress(host: "  my.lers.ru \n", port: 443, useHTTPS: true).baseURL?.absoluteString,
                       "https://my.lers.ru")
    }

    func testInvalidAddresses() {
        XCTAssertNil(ServerAddress(host: "", port: 10000, useHTTPS: false).baseURL)
        XCTAssertNil(ServerAddress(host: "https://my.lers.ru", port: 443, useHTTPS: true).baseURL)
        XCTAssertNil(ServerAddress(host: "my.lers.ru:10000", port: 10000, useHTTPS: false).baseURL)
        XCTAssertNil(ServerAddress(host: "my lers", port: 10000, useHTTPS: false).baseURL)
        XCTAssertNil(ServerAddress(host: "my.lers.ru", port: 0, useHTTPS: false).baseURL)
        XCTAssertNil(ServerAddress(host: "my.lers.ru", port: 70000, useHTTPS: false).baseURL)
    }

    // MARK: - Разбор адреса, введённого одной строкой

    func testParseHTTPWithoutPortUsesLersDefaultPort() throws {
        // Для http без порта — 10000 (порт ЛЭРС по умолчанию), а не 80.
        let address = try ServerAddress(parsing: "http://192.168.1.10")
        XCTAssertEqual(address, ServerAddress(host: "192.168.1.10", port: 10000, useHTTPS: false))
        XCTAssertEqual(address.baseURL?.absoluteString, "http://192.168.1.10:10000")
    }

    func testParseHTTPSWithoutPortUses443() throws {
        let address = try ServerAddress(parsing: "https://my.lers.ru")
        XCTAssertEqual(address, ServerAddress(host: "my.lers.ru", port: 443, useHTTPS: true))
    }

    func testParseWithoutSchemeMeansHTTPS() throws {
        XCTAssertEqual(try ServerAddress(parsing: "my.lers.ru"),
                       ServerAddress(host: "my.lers.ru", port: 443, useHTTPS: true))
        XCTAssertEqual(try ServerAddress(parsing: "my.lers.ru:8443"),
                       ServerAddress(host: "my.lers.ru", port: 8443, useHTTPS: true))
    }

    func testParseExplicitPort() throws {
        XCTAssertEqual(try ServerAddress(parsing: "http://lers.local:8080"),
                       ServerAddress(host: "lers.local", port: 8080, useHTTPS: false))
        // Явно указанный 80 — это 80, а не 10000.
        XCTAssertEqual(try ServerAddress(parsing: "http://lers.local:80"),
                       ServerAddress(host: "lers.local", port: 80, useHTTPS: false))
    }

    func testParseTolerantInput() throws {
        // Пробелы по краям, заглавные буквы в протоколе, «/» в конце (так копируют из браузера).
        XCTAssertEqual(try ServerAddress(parsing: "  HTTPS://my.lers.ru/ \n"),
                       ServerAddress(host: "my.lers.ru", port: 443, useHTTPS: true))
    }

    func testParseErrors() {
        XCTAssertThrowsError(try ServerAddress(parsing: "   ")) { error in
            XCTAssertEqual(error as? ServerAddress.ParseError, .empty)
        }
        XCTAssertThrowsError(try ServerAddress(parsing: "ftp://my.lers.ru")) { error in
            XCTAssertEqual(error as? ServerAddress.ParseError, .unsupportedScheme)
        }
        XCTAssertThrowsError(try ServerAddress(parsing: "https://my.lers.ru/api/v1")) { error in
            XCTAssertEqual(error as? ServerAddress.ParseError, .hasPath)
        }
        for badPort in ["http://my.lers.ru:", "http://my.lers.ru:abc", "http://my.lers.ru:0", "http://my.lers.ru:70000"] {
            XCTAssertThrowsError(try ServerAddress(parsing: badPort), badPort) { error in
                XCTAssertEqual(error as? ServerAddress.ParseError, .invalidPort, badPort)
            }
        }
        for invalid in ["my lers.ru", "https://", "https://user@my.lers.ru", "https://my.lers.ru?x=1"] {
            XCTAssertThrowsError(try ServerAddress(parsing: invalid), invalid)
        }
    }

    func testHostMustBeDomainOrIP() {
        for good in ["my.lers.ru", "lers.local", "192.168.1.10", "0.0.0.0", "сервер.рф", "xn--e1afmkfd.xn--p1ai", "a-b.example.com"] {
            XCTAssertTrue(ServerAddress.isValidHost(good), good)
        }
        for bad in ["1", "12", "my", "lersserver", "1.2.3", "1.2.3.4.5", "300.1.1.1", "192.168.1.", ".ru",
                    "my..ru", "-my.ru", "my-.ru", "my.r", "my.123", "my_server.ru", "my lers.ru"] {
            XCTAssertFalse(ServerAddress.isValidHost(bad), bad)
        }
        // Адрес одной строкой тоже проверяется.
        XCTAssertThrowsError(try ServerAddress(parsing: "http://1"))
    }

    func testDisplayTextRoundTrip() throws {
        // Строка для поля ввода: порт по умолчанию не пишем; разбор этой строки даёт тот же адрес.
        let examples = [
            (ServerAddress(host: "my.lers.ru", port: 443, useHTTPS: true), "https://my.lers.ru"),
            (ServerAddress(host: "192.168.1.10", port: 10000, useHTTPS: false), "http://192.168.1.10"),
            (ServerAddress(host: "192.168.1.10", port: 80, useHTTPS: false), "http://192.168.1.10:80"),
            (ServerAddress(host: "my.lers.ru", port: 8443, useHTTPS: true), "https://my.lers.ru:8443"),
        ]
        for (address, text) in examples {
            XCTAssertEqual(address.displayText, text)
            XCTAssertEqual(try ServerAddress(parsing: text), address)
        }
    }
}
