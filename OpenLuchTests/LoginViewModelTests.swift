import XCTest
@testable import OpenLuch

// Проверка сервера на экране входа — без интернета: стучимся на свой же компьютер (127.0.0.1)
// в порт, где никто не слушает, и система сразу отвечает «соединение отклонено».
final class LoginViewModelTests: XCTestCase {

    private func makeModel() throws -> LoginViewModel {
        let id = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LoginViewModelTests-\(id)"))
        let session = AppSession(tokenStore: KeychainTokenStore(service: "ru.stklb.openluch.tests.\(id)"),
                                 settingsStore: SettingsStore(defaults: defaults),
                                 cacheStore: CacheStore(directory: FileManager.default.temporaryDirectory.appending(path: "LoginVM-\(id)")))
        return LoginViewModel(session: session)
    }

    /// Ждём, пока проверка сервера закончится (не дольше 10 секунд).
    private func waitForServerCheck(_ model: LoginViewModel) async throws {
        for _ in 0..<100 {
            if case .checking = model.serverCheck {
                try await Task.sleep(for: .milliseconds(100))
            } else {
                return
            }
        }
        XCTFail("Проверка сервера не закончилась за 10 секунд")
    }

    func testUnreachableServerIsReported() async throws {
        let model = try makeModel()
        model.useHTTPS = false
        model.hostText = "127.0.0.1"
        model.portText = "1"
        model.serverFieldDidLoseFocus()
        XCTAssertEqual(model.serverCheck, .checking)

        try await waitForServerCheck(model)
        guard case .unavailable(let message) = model.serverCheck else {
            return XCTFail("Ожидали «сервер недоступен», а получили \(model.serverCheck)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testInvalidAddressIsNotChecked() throws {
        let model = try makeModel()
        model.hostText = "my.lers.ru"
        model.portText = "abc"
        model.serverFieldDidLoseFocus()
        XCTAssertEqual(model.serverCheck, .notChecked)
    }

    func testChangingAddressResetsCheck() throws {
        let model = try makeModel()
        model.useHTTPS = false
        model.hostText = "127.0.0.1"
        model.portText = "1"
        model.serverFieldDidLoseFocus()
        XCTAssertNotEqual(model.serverCheck, .notChecked)

        // Пробел после имени — тот же адрес: проверка продолжается.
        model.hostText = "127.0.0.1 "
        model.addressDidChange()
        XCTAssertNotEqual(model.serverCheck, .notChecked)

        // Другой порт — другой адрес: старый результат убран.
        model.portText = "2"
        model.addressDidChange()
        XCTAssertEqual(model.serverCheck, .notChecked)
    }

    func testNotADomainOrIPIsNotChecked() throws {
        // Раньше «1» в поле сервера сразу отправлялось на проверку.
        let model = try makeModel()
        model.hostText = "1"
        model.serverFieldDidLoseFocus()
        XCTAssertEqual(model.serverCheck, .notChecked)
        XCTAssertNil(model.enteredAddress)
        XCTAssertTrue(model.isAddressErrorVisible)
        XCTAssertNotNil(model.serverErrorMessage)

        // Снова редактируют — ошибка спрятана до конца ввода.
        model.hostText = "my.lers"
        model.hostTextDidChange()
        XCTAssertFalse(model.isAddressErrorVisible)
    }

    func testPortKeepsOnlyFiveDigits() throws {
        let model = try makeModel()
        model.portText = "1a00000"
        model.portTextDidChange()
        XCTAssertEqual(model.portText, "10000")
    }

    func testProtocolSwitchChangesDefaultPortOnly() throws {
        let model = try makeModel()
        XCTAssertTrue(model.useHTTPS)
        XCTAssertEqual(model.portText, "443")

        // Стандартный порт меняется вместе с протоколом.
        model.useHTTPS = false
        model.protocolDidChange()
        XCTAssertEqual(model.portText, "10000")
        model.useHTTPS = true
        model.protocolDidChange()
        XCTAssertEqual(model.portText, "443")

        // Свой порт остаётся.
        model.portText = "8443"
        model.useHTTPS = false
        model.protocolDidChange()
        XCTAssertEqual(model.portText, "8443")
    }

    func testPastedFullAddressIsSplit() throws {
        let model = try makeModel()
        model.hostText = "http://192.168.1.10:8080/"
        model.hostTextDidChange()
        XCTAssertFalse(model.useHTTPS)
        XCTAssertEqual(model.hostText, "192.168.1.10")
        XCTAssertEqual(model.portText, "8080")
        XCTAssertEqual(model.enteredAddress, ServerAddress(host: "192.168.1.10", port: 8080, useHTTPS: false))

        // Порт, дописанный в поле имени, — ошибка с подсказкой, а не «тихий» разбор.
        model.hostText = "my.lers.ru:443"
        model.hostTextDidChange()
        XCTAssertNil(model.enteredAddress)
        XCTAssertNotNil(model.serverErrorMessage)
    }

    func testLogInToUnreachableServerFailsInsteadOfWaiting() async throws {
        // Раньше вход на неотвечающий сервер «ждал сеть» до 20 минут, хотя сеть есть.
        // Теперь — ошибка «сервер недоступен» примерно через 15 секунд.
        let model = try makeModel()
        model.useHTTPS = false
        model.hostText = "127.0.0.1"
        model.portText = "1"
        model.login = "demo"
        model.password = "demo"
        model.logIn()
        XCTAssertTrue(model.isLoggingIn)

        for _ in 0..<300 where model.isLoggingIn {
            // Пока ждём — на экране не должно быть «Нет сети»: сеть у компьютера есть.
            XCTAssertFalse(model.isWaitingForNetwork)
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(model.isLoggingIn, "Вход не закончился за 30 секунд")
        XCTAssertEqual(model.errorMessage, APIError.serverUnreachable.errorDescription)
    }
}
