import XCTest
@testable import OpenLuch

// Проверяем, что ответы сервера с ошибками и сетевые сбои превращаются
// в правильные ошибки с понятным текстом.
final class APIErrorTests: XCTestCase {

    func testSuccessCodesAreNotErrors() {
        XCTAssertNil(APIError.fromHTTPStatus(200, body: Data()))
        XCTAssertNil(APIError.fromHTTPStatus(204, body: Data()))
    }

    func testWrongPasswordGivesServerMessage() throws {
        // Настоящий ответ сервера на неверный пароль: 401 + JSON с текстом.
        let body = try SampleFiles.data(named: "login-wrong-password-401")
        let error = APIError.fromHTTPStatus(401, body: body)

        XCTAssertEqual(error, .unauthorized(serverMessage: "Имя входа или пароль указаны неверно"))
        XCTAssertEqual(error?.errorDescription, "Имя входа или пароль указаны неверно")
    }

    func testExpiredTokenGivesSessionExpired() {
        // Истёкший или неверный токен: 401 с пустым телом.
        let error = APIError.fromHTTPStatus(401, body: Data())

        XCTAssertEqual(error, .unauthorized(serverMessage: nil))
        XCTAssertEqual(error?.errorDescription, "Сессия истекла. Войдите заново.")
    }

    func testForbidden() {
        XCTAssertEqual(APIError.fromHTTPStatus(403, body: Data()), .accessDenied)
    }

    func testBusinessLogicErrorWithMessage() {
        let body = Data(#"{"errorMessage":"Точка учёта не найдена","errorCode":5,"data":null}"#.utf8)
        XCTAssertEqual(APIError.fromHTTPStatus(422, body: body), .serverError(message: "Точка учёта не найдена"))
    }

    func testUnexpectedStatusWithoutMessage() {
        // Например, страница ошибки IIS в HTML — это не JSON, текста от ЛЭРС нет.
        let body = Data("<html>Server Error</html>".utf8)
        XCTAssertEqual(APIError.fromHTTPStatus(500, body: body), .unexpectedStatus(code: 500))
    }

    func testNetworkErrorsAreTranslated() {
        XCTAssertEqual(APIError.from(URLError(.notConnectedToInternet)), .noConnection)
        XCTAssertEqual(APIError.from(URLError(.networkConnectionLost)), .connectionLost)
        XCTAssertEqual(APIError.from(URLError(.timedOut)), .timedOut)
        XCTAssertEqual(APIError.from(URLError(.cannotFindHost)), .serverUnreachable)
        XCTAssertEqual(APIError.from(URLError(.cannotConnectToHost)), .serverUnreachable)
        XCTAssertEqual(APIError.from(URLError(.serverCertificateUntrusted)), .secureConnectionFailed)
        XCTAssertEqual(APIError.from(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(APIError.from(CancellationError()), .cancelled)
    }
}
