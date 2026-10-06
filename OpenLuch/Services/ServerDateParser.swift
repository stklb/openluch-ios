import Foundation

// Разбор дат из ответов сервера ЛЭРС.
//
// Сервер пишет даты так: "2027-10-09T21:38:19.3510055Z" — с 7 знаками долей секунды.
// Стандартная настройка JSONDecoder (.iso8601) на старых версиях iOS доли секунды
// не понимает, поэтому разбираем сами: сначала с долями секунды, потом без них.
//
// Важно: некоторые даты ЛЭРС присылает БЕЗ часового пояса ("2026-10-02T14:45:11.5239277").
// Такие здесь не разбираются (вернётся nil) — в моделях первой версии их нет (см. docs/api-notes.md).
nonisolated enum ServerDateParser {

    static func date(from text: String) -> Date? {
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? withFraction.parse(text) {
            return date
        }
        let withoutFraction = Date.ISO8601FormatStyle()
        if let date = try? withoutFraction.parse(text) {
            return date
        }
        return nil
    }

    /// JSONDecoder для ответов сервера: умеет разбирать даты ЛЭРС.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = ServerDateParser.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Не удалось разобрать дату: \(text)"
            )
        }
        return decoder
    }
}
