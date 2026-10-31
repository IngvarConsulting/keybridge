// SPDX-License-Identifier: MIT
import Foundation

public struct PreparationSnapshot: Decodable {
    public let id: String
    public let state: String
    public let phase: String
    public let startedAt: Double
    public let phaseStartedAt: Double
    public let updatedAt: Double
    public let lastOutputAt: Double?
    public let finishedAt: Double?
    public let recoveryReason: String?

    public static let stages = ["Установщики", "Образ Linux", "Первый запуск", "Компоненты", "Проверка служб", "Сохранение"]
    public var stageIndex: Int {
        switch phase {
        case "linux", "import": return 1
        case "boot": return 2
        case "verify_imports", "dependencies", "driver", "firmware_guard", "manager_install": return 3
        case "manager_configure", "manager_ready", "alpine": return 4
        case "finalize": return 5
        default: return 0
        }
    }
    public var isRunning: Bool { state == "running" }
    public var heading: String {
        switch state {
        case "succeeded": return "Среда готова"
        case "failed": return "Подготовка не завершена"
        case "cancelled": return "Подготовка отменена"
        default: return "Готовим среду для ключа"
        }
    }
    public var action: String {
        switch phase {
        case "verify": return "Проверяем установщики"
        case "linux": return "Готовим образ Linux"
        case "import": return "Копируем компоненты в новую среду"
        case "boot": return "Запускаем Linux впервые"
        case "verify_imports": return "Проверяем установщики в Alpine"
        case "dependencies": return "Устанавливаем библиотеки Linux"
        case "driver": return "Устанавливаем драйвер HASP"
        case "firmware_guard": return "Проверяем настройки драйвера"
        case "manager_install": return "Устанавливаем менеджер лицензий 1С"
        case "manager_configure": return "Настраиваем менеджер лицензий"
        case "manager_ready": return "Проверяем готовность служб"
        case "alpine": return "Собираем Alpine для 128 МиБ RAM"
        case "finalize": return "Сохраняем подготовленную среду"
        default: return "Подготавливаем среду"
        }
    }
    public var detail: String {
        if recoveryReason == "agent_restarted" {
            return "Фоновый агент перезапустился до завершения подготовки. Вывод прерванной попытки сохранён в консоли; подготовку можно повторить."
        }
        if recoveryReason == "commit_recovered" {
            return "Среда была сохранена до перезапуска агента. Можно запустить раздачу и проверить получение лицензии в 1С."
        }
        switch state {
        case "succeeded": return "Можно запустить раздачу и проверить получение лицензии в 1С."
        case "failed": return "Подробности остались в консоли. Устраните указанную ошибку и повторите подготовку."
        case "cancelled": return "Можно выбрать установщики и начать подготовку заново."
        default: break
        }
        switch phase {
        case "verify": return "Проверяем состав файлов и вычисляем суммы для контроля передачи. Большой установщик нужно прочитать целиком."
        case "linux": return "Используем проверенный образ из кэша или загружаем его. Скорость загрузки зависит от соединения."
        case "import": return "Создаём диск и переносим ваши установщики. Исходные файлы остаются на месте."
        case "boot": return "Готовый Alpine загружается и получает отдельные SSH-ключи этой VM."
        case "verify_imports": return "Alpine уже загрузился. Проверяем состав выбранных файлов и целостность их передачи."
        case "dependencies": return "Linux загружает необходимые пакеты. Их названия и ход установки видны в консоли."
        case "driver": return "Добавляем драйвер в Linux. Физический ключ к этой среде пока не подключён."
        case "firmware_guard": return "Проверяем запрет автоматического обновления прошивки до подключения ключа."
        case "manager_install": return "Установщик 1С может долго работать без новых строк. Отсутствие вывода само по себе не означает ошибку."
        case "manager_configure", "manager_ready": return "Ждём подтверждения готовности служб. Это ещё не проверка выдачи лицензии клиенту 1С."
        case "alpine": return "Переносим компоненты в Alpine с glibc и проверяем запуск новой VM. Предыдущая среда сохраняется."
        case "finalize": return "Останавливаем новую VM и сохраняем результат подготовки."
        default: return "Подробности выполнения доступны в консоли."
        }
    }
    public func elapsed(at now: Date) -> String { Self.duration((finishedAt ?? now.timeIntervalSince1970) - startedAt) }
    public func phaseElapsed(at now: Date) -> String { Self.duration((finishedAt ?? now.timeIntervalSince1970) - phaseStartedAt) }
    public func activity(at now: Date) -> String {
        guard isRunning else { return "Журнал последней подготовки сохранён на этом Mac" }
        if now.timeIntervalSince1970 - updatedAt > 15 { return "Ожидаем обновления статуса от фонового агента" }
        guard let lastOutputAt, lastOutputAt > 0 else { return "Агент отвечает · ожидаем первый вывод команды" }
        return "Агент отвечает · последний вывод \(Self.duration(now.timeIntervalSince1970 - lastOutputAt)) назад"
    }
    public static func duration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}

public enum PreparationConsole {
    /// A bounded tail, including incomplete final lines; never loads an entire installer log.
    public static func tail(at url: URL, maximumBytes: Int = 128 * 1024) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        let limit = UInt64(max(1, maximumBytes))
        let start = size > limit ? size - limit : 0
        try file.seek(toOffset: start)
        var data = try file.read(upToCount: Int(limit)) ?? Data()
        if start > 0, let newline = data.firstIndex(of: 10) { data = data.suffix(from: data.index(after: newline)) }
        var text = String(decoding: data, as: UTF8.self)
        // Terminal escapes must not become visible garbage in a plain-text view.
        text = text.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = String(text.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" })
        return (start > 0 ? "[Показан конец журнала; полный файл доступен по кнопке выше]\n" : "") + text
    }
}
