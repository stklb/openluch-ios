import Foundation
import XCTest

// Загрузка примеров ответов сервера из папки Samples.
// Это настоящие ответы тестового сервера my.lers.ru (токен вырезан, персональные данные заменены).
// Xcode кладёт эти файлы внутрь тестового пакета, откуда мы их и читаем.
enum SampleFiles {

    static func data(named name: String) throws -> Data {
        let bundle = Bundle(for: SampleFilesBundleMarker.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw XCTSkip("Нет файла примера \(name).json в тестовом пакете")
        }
        return try Data(contentsOf: url)
    }
}

/// Пустой класс — нужен только чтобы найти «свой» пакет с файлами (Bundle(for:)).
private final class SampleFilesBundleMarker {}
