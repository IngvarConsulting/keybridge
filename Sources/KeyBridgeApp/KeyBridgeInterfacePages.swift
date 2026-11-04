// SPDX-License-Identifier: MIT
import Foundation
import KeyBridgeCore

struct InterfacePageCopy {
    var title: String
    var body: String
    var remedy = ""
    var scope = ""
    var knownCause = false
}

@MainActor
extension KeyBridgeInterfaceState {
    var pageCopy: InterfacePageCopy {
        let copy: InterfacePageCopy
        switch screen {
        case "agent-update": copy = .init(title: "Нужно завершить обновление KeyBridge", body: "Продолжает работать фоновая программа прежней версии.", remedy: "Нажмите «Выключить и выйти», затем откройте KeyBridge снова. Программы для ключа и настройки сохранятся.", knownCause: true)
        case "loading": copy = .init(title: "Проверяем состояние KeyBridge", body: "Получаем сведения о программах и подключении ключа.")
        case "unknown": copy = .init(title: "Не удалось проверить работу KeyBridge", body: "KeyBridge не получил ответ о работе с USB-ключом. Поэтому неизвестно, освобождён ли ключ; повторное включение заблокировано.", remedy: "Повторите проверку или попробуйте выключить KeyBridge. Если ответа снова нет, сохраните работу в других программах, перезагрузите Mac и откройте KeyBridge заново.", scope: "safety")
        case "data-error": copy = .init(title: "Нужно проверить данные KeyBridge", body: text("dataError").isEmpty ? "Не удалось прочитать сохранённые данные KeyBridge. Их пригодность пока не подтверждена." : text("dataError"), remedy: "После исправления нажмите «Проверить состояние».", knownCause: true)
        case "paused": copy = pauseCopy
        case "reconciling": copy = .init(title: "Проверяем состояние KeyBridge", body: text("resumeReason") == "restart" ? "KeyBridge перезапустился. Проверяем, продолжилась ли работа с ключом. Прежние показания пока не подтверждены." : text("resumeReason") == "login" ? "Проверяем подключение и условия автозапуска. Сохранённое выключение имеет приоритет." : "Проверяем подключение и сохранённый выбор перед продолжением работы. Прежняя проверка лицензии больше не подтверждает текущую работу.")
        case "rollback-error": copy = .init(title: "Предыдущая версия недоступна", body: "Не удалось прочитать файлы предыдущей установки. Переключение не выполнено; текущая установка сохранена.", remedy: "Восстановите файлы из резервной копии и повторите возврат. Можно также переустановить программы из своих файлов или включить текущую установку.")
        case "restore-error": copy = .init(title: "Не удалось вернуть настройки 1С", body: flag("backupAvailable") ? "Возврат настроек не завершён. Причину пока не удалось определить." : "Сохранённая копия прежних настроек не найдена. Текущие настройки 1С не изменены.", remedy: "Восстановите копию настроек KeyBridge из резервной копии Mac и повторите возврат. Если копии нет, вернитесь назад: работу с KeyBridge можно продолжить.")
        case "preparing": copy = .init(title: "Устанавливаем программы для ключа", body: replacing ? "Прежняя установка сохранится." : "Устанавливаем выбранные файлы. USB-ключ пока не используется.")
        case "starting": copy = .init(title: "Включаем KeyBridge", body: "Проверяем программы для ключа и его подключение.")
        case "stopping": copy = .init(title: "Выключаем KeyBridge", body: "Освобождаем USB-ключ. Дождитесь подтверждения.")
        case "recovering": copy = .init(title: "Восстанавливаем работу", body: "KeyBridge потерял связь с программой для выдачи лицензий. Причина пока неизвестна. Пробуем восстановить работу; вы можете выключить KeyBridge.", remedy: "Автоматические попытки ограничены. Если они закончатся без результата, появятся действия для исправления.")
        case "configuring": copy = .init(title: "Разрешите изменить поиск лицензии", body: "macOS запросит разрешение на изменение настроек поиска лицензии. Базы и конфигурации 1С не изменятся.")
        case "restoring": copy = .init(title: "Нужно разрешение macOS", body: "Разрешите вернуть настройки поиска лицензии в 1С. Базы и конфигурации не изменятся.")
        case "restoring-version": copy = .init(title: "Возвращаем предыдущую версию", body: "Возвращаем программы, которые использовались до обновления. После возврата можно включить KeyBridge.")
        case "install-error":
            if ["missing-license-manager", "ambiguous-license-manager"].contains(text("installerIssue")) {
                copy = .init(title: "Нужен другой установщик 1С", body: text("installerIssue") == "missing-license-manager" ? "Выбранный установщик 1С не содержит нужный менеджер лицензий." : "Установщик добавил несколько менеджеров лицензий. KeyBridge не может выбрать нужный.", remedy: "Выберите полную поставку платформы 1С 8.5.4 или новее для Linux x86-64 с менеджером лицензий rmlic.", knownCause: true)
            } else { copy = .init(title: "Установка прервалась", body: "Установщик завершился с ошибкой. По имеющимся данным её причину определить не удалось.", remedy: "Повторите установку. Если она снова прервётся, выберите другие установочные файлы.", scope: "install") }
        case "start-error": copy = .init(title: "KeyBridge не включился", body: "Программа для выдачи лицензий не ответила при запуске. Причина отсутствия ответа пока неизвестна.", remedy: "Повторите включение. Если ошибка повторится, переустановите программы для ключа.", scope: "install")
        case "client-missing": copy = .init(title: "1С на этом Mac не найдена", body: "KeyBridge не обнаружил клиентское приложение 1С для macOS. Установщик 1С для Linux, выбранный ранее, его не заменяет.", remedy: "Установите клиент 1С для macOS из своего дистрибутива, затем нажмите «Проверить наличие 1С».", scope: "client")
        case "review-settings": copy = .init(title: "Изменить поиск лицензии в 1С?", body: "KeyBridge запишет адрес менеджера на этом Mac в rclic.cfg и nethasp.ini. Широковещательный поиск менеджеров по сети будет отключён.", remedy: "Перед записью сохраним исходные файлы. Кнопка «Вернуть настройки» восстановит их прежнее содержимое, включая отсутствие файла.")
        case "access-error": copy = .init(title: "Не удалось настроить поиск лицензии", body: "Изменение настроек 1С не завершилось. Причина пока неизвестна.", remedy: "Устраните указанную причину и повторите настройку. Если macOS запросит разрешение, подтвердите изменение. Можно отменить настройку и вернуться назад.")
        case "client-unknown": copy = .init(title: "Не удалось проверить настройки 1С", body: "Приложение не подтвердило, как настроен поиск лицензии.", remedy: "Повторите проверку. Если ошибка повторится, откройте клиент 1С и убедитесь, что он установлен на этом Mac.", scope: "client")
        case "client-unconfigured": copy = .init(title: "Настройте поиск лицензии в 1С", body: result("config").isEmpty ? "Программы для ключа установлены. Осталось разрешить 1С искать лицензию через KeyBridge. Базы и конфигурации не изменятся." : result("config"), remedy: "Это нужно сделать один раз. macOS запросит разрешение. После настройки можно будет включить KeyBridge.")
        case "client-external": copy = .init(title: "Поиск лицензии требует настройки", body: "В общих rclic.cfg или nethasp.ini ещё не задан поиск через KeyBridge либо указаны другие настройки.", remedy: "Нажмите «Исправить настройки», чтобы посмотреть пути файлов и подтвердить изменение. Текущие файлы будут сохранены для возврата.")
        case "unsafe": copy = .init(title: "Ключ не подключён к KeyBridge", body: "Не удалось подтвердить запрет обновления прошивки ключа. Без этой проверки KeyBridge не подключает ключ. Причина сбоя проверки пока неизвестна.", remedy: "Переподключите USB-ключ к Mac и проверьте защиту снова. Если проверка снова не пройдёт, переустановите программы для ключа.", scope: "safety")
        case "multiple": copy = .init(title: "Подключено несколько ключей HASP", body: "KeyBridge не может определить, какой из них использовать, поэтому не подключает ни один.", remedy: "Оставьте подключённым один ключ HASP, затем нажмите «Проверить подключение».", scope: "safety")
        case "exhausted": copy = .init(title: "Не удалось восстановить работу", body: "Программа для выдачи лицензий не ответила после повторных запусков. Автоматические попытки закончились.", remedy: "Попробуйте включить KeyBridge вручную. Если ошибка повторится, переустановите программы для ключа.")
        case "waiting": copy = .init(title: "Подключите USB-ключ HASP", body: "KeyBridge не обнаружил подключённый ключ. Вставьте один ключ в USB-разъём этого Mac. Если он уже подключён, отсоедините и подключите его снова.")
        case "update-error": copy = .init(title: "После обновления KeyBridge не заработал", body: "Новая установка не прошла запуск или проверку лицензии. Точную причину по этим данным определить нельзя. KeyBridge сейчас выключен.", remedy: "Верните предыдущую версию или повторите включение. После возврата включите KeyBridge; проверка лицензии доступна в диагностике.")
        case "stop-unsaved": copy = .init(title: "KeyBridge выключен, но запрет запуска не сохранён", body: "Не удалось записать настройку «выключено». Причина ошибки записи пока неизвестна. При следующем запуске KeyBridge может снова включиться.", remedy: "Нажмите «Сохранить выключение». Если запись снова не удастся, проверьте свободное место на Mac и повторите сохранение. До сохранения запрета не запускайте KeyBridge заново.", scope: "stop")
        case "stopped": copy = .init(title: "KeyBridge выключен", body: !result("config").isEmpty ? result("config") : flag("hold") ? "KeyBridge больше не использует USB-ключ и не включится сам, пока вы снова не разрешите запуск." : "Всё установлено. Включите KeyBridge, чтобы 1С могла обратиться к USB-ключу.")
        case "ready": copy = .init(title: "KeyBridge работает", body: result("monitor").isEmpty ? "USB-ключ подключён." : result("monitor"))
        case "diagnosis": copy = .init(title: "Помощь с лицензией 1С", body: "Если 1С не получает лицензию, проверьте её подключение к KeyBridge. Работа с USB-ключом продолжается.")
        case "monitor-error": copy = .init(title: "Не удалось открыть монитор лицензий", body: "Приложение 1С не подтвердило запуск монитора. Причина пока неизвестна. Работа KeyBridge продолжается.", remedy: "Повторите открытие. Если монитор снова не откроется, проверьте лицензию в своей базе 1С.", scope: "monitor")
        case "client-help": copy = .init(title: "Установите клиент 1С для macOS", body: "Используйте дистрибутив клиента 1С для macOS, полученный в вашей организации или на портале обновлений 1С. После установки вернитесь и нажмите «Проверить наличие 1С». Файл .run для Linux предназначен для другой части KeyBridge.")
        case "storage": copy = .init(title: "Освободите место на Mac", body: "Откройте настройки macOS → «Основные» → «Хранилище». Перенесите ненужные файлы на другой диск или удалите их самостоятельно. Вернитесь в KeyBridge и повторите проверку места или сохранение настройки. KeyBridge сам ничего не удаляет.")
        case "permission": copy = .init(title: "Разрешите запуск при входе", body: "В настройках macOS откройте «Основные» → «Объекты входа» и разрешите запуск KeyBridge. Название раздела может отличаться в вашей версии macOS.")
        case "resources": copy = .init(title: "Технические сведения", body: "")
        case "additional": copy = .init(title: "Дополнительные действия", body: "")
        default: copy = .init(title: "KeyBridge", body: "")
        }
        guard !copy.knownCause, !copy.remedy.isEmpty else { return copy }
        var resultCopy = copy
        if !result(copy.scope).isEmpty { resultCopy.body = result(copy.scope) }
        else if page.isEmpty, !visibleError.isEmpty { resultCopy.body = visibleError }
        return resultCopy
    }
    private var observedSleep: Bool { text("sessionAvailability") == "sleeping" && text("sessionReason") == "system-sleep" }
    private var pauseCopy: InterfacePageCopy {
        if observedSleep {
            return .init(title: "Работа приостановлена", body: "Mac перешёл в сон. После пробуждения KeyBridge проверит подключение и учтёт сохранённое выключение. Прежняя проверка лицензии больше не подтверждает текущую работу.")
        }
        let body: String
        switch text("sessionAvailability") == "unavailable" ? text("sessionReason") : "" {
        case "session-off-console": body = "Ваша учётная запись macOS сейчас не активна на этом Mac."
        case "login-incomplete": body = "Вход в вашу учётную запись macOS ещё не завершён."
        default: body = "KeyBridge пока не подтвердил, что ваш вход в macOS активен."
        }
        return .init(title: "Работа приостановлена", body: body,
                     remedy: "Войдите в свою учётную запись или разблокируйте Mac. Если вы уже вошли, дождитесь автоматической проверки. Сохранённое выключение останется в силе.", knownCause: true)
    }
    var footerActions: [InterfaceAction] {
        func a(_ id: String, _ title: String, _ primary: Bool = false, _ disabled: Bool = false) -> InterfaceAction { .init(id: id, title: title, primary: primary, disabled: disabled || pendingAction(id) || (ApplicationCommandFlow.diagnostics.contains(id) && !canRequestDiagnostic(id))) }
        switch screen {
        case "setup":
            if text("fault") == "space" { return [a("storage-help", "Как освободить место"), a("check-space", "Проверить место", true)] }
            let cancel = replacing && setupStep != "installer" ? [a("cancel-replace", "Отмена")] : []
            if setupStep == "review" { return cancel + [a("edit-installer", "Изменить файлы"), a("prepare", "Установить программы", true, busy || files["installer"]?.valid != true || files["driver"]?.valid != true)] }
            let file = files[setupStep] ?? InterfaceFile()
            return cancel + [a(file.checking ? "cancel-\(setupStep)" : setupStep, file.checking ? "Отменить проверку" : (file.name.isEmpty ? "Выбрать " : "Заменить ") + (setupStep == "installer" ? "установщик…" : "драйвер…")), a("setup-next", "Продолжить", true, !file.valid || file.checking)]
        case "agent-update": return [a("quit", "Выключить и выйти", true)]
        case "unknown", "data-error": return [a("recheck", "Проверить состояние", true)]
        case "rollback-error": return [a("start", "Включить"), a("replace", "Переустановить…"), a("rollback", "Повторить возврат", true)]
        case "restore-error": return [a("restore", "Повторить возврат", true)]
        case "install-error":
            if ["missing-license-manager", "ambiguous-license-manager"].contains(text("installerIssue")) { return [a("replace", "Выбрать другие файлы", true)] }
            return [a("replace", "Другие файлы…"), a("retry-install", "Повторить установку", true)]
        case "start-error", "exhausted": return (flag("previousAvailable") ? [a("rollback", "Вернуть предыдущую версию")] : []) + [a("replace", "Переустановить…"), a("start", "Включить", true)]
        case "client-missing": return [a("client-help", "Как установить 1С"), a("check-client", "Проверить наличие 1С", true)]
        case "client-unknown": return [a("check-client", "Проверить наличие 1С", true)]
        case "review-settings", "client-unconfigured": return [a("configure", "Настроить поиск лицензии", true, locked)]
        case "access-error": return [a("retry-access", "Повторить настройку", true, locked)]
        case "client-external": return [a("review-settings", "Исправить настройки", true, locked)]
        case "unsafe": return [a("replace", "Переустановить…", false, locked), a("recheck", "Проверить защиту", true)]
        case "multiple": return [a("recheck", "Проверить подключение", true)]
        case "waiting": return [a("check-key", "Проверить подключение", true)]
        case "update-error": return [a("start", "Включить"), a("rollback", "Вернуть предыдущую версию", true)]
        case "stop-unsaved": return [a("storage-help", "Как освободить место"), a("save-stop", "Сохранить выключение", true)]
        case "stopped": return [a("start", "Включить", true, client != "managed")]
        case "ready": return [a("diagnose", "1С не получает лицензию"), a("monitor", "Посмотреть занятые лицензии", true)]
        case "diagnosis": return (["failure", "timeout", "unconfirmed"].contains(text("proof")) ? [a("manual-license", "Как проверить в своей базе", text("proof") == "unconfirmed")] : []) + [a("probe", "Проверить в 1С", text("proof") != "unconfirmed", !canRequestDiagnostic("probe"))]
        case "monitor-error": return [a("manual-license", "Как проверить в своей базе"), a("monitor", "Открыть монитор ещё раз", true)]
        case "resources": return [a("measure", "Измерить", false, !canRequestDiagnostic("measure"))]
        case "additional": return [a(flag("prepared") ? "replace" : "open-install", flag("prepared") ? "Переустановить…" : "Установить…", false, locked), a("restore", "Вернуть настройки…", false, locked || !flag("backupAvailable"))]
        case "permission": return [a("open-permission-settings", "Открыть настройки"), a("check-permission", "Проверить разрешение", true)]
        case "settings":
            var actions: [InterfaceAction] = []
            if pendingAuto != nil { actions = [a("cancel-auto", "Отмена", false, autoWorking), a("retry-auto", "Сохранить выбор", true, autoWorking)] }
            else if client == "external" { actions = [a("review-settings", "Исправить настройки", true, locked)] }
            else if flag("autoAvailable") {
                if flag("auto") && text("permission") == "unregistered" { actions = [a("resume-auto", "Восстановить автозапуск", true)] }
                else if flag("auto") && flag("hold") { actions = [a("resume-auto", "Возобновить автозапуск", true)] }
                else if text("permission") == "denied" { actions = [a("permission", "Разрешить в macOS", true)] }
                else if text("permission") == "unknown" { actions = [a("check-permission", "Проверить разрешение", true)] }
            }
            return [a("additional-actions", "Дополнительные действия…")] + actions
        default: return []
        }
    }
    var backAction: InterfaceAction? {
        switch screen {
        case "setup":
            if setupStep != "installer" { return .init(id: "setup-back", title: "Назад") }
            return replacing ? .init(id: "back", title: "Назад") : nil
        case "review-settings": return .init(id: "cancel-settings", title: "Отмена")
        case "access-error": return .init(id: "dismiss-access", title: "Отмена")
        case "restore-error": return .init(id: "restore-back", title: "Назад")
        case "diagnosis", "additional", "resources", "manual", "permission", "client-help", "storage", "monitor-error": return .init(id: "back", title: "Назад")
        default: return nil
        }
    }
    var stopDisabled: Bool { phase == "loading" || phase == "stopping" || pendingAction("stop") || pendingAction("quit") || (flag("saved") && !busy && !active && !["unknown", "data-error"].contains(phase) && !(editing && replacing)) }
    var stopTitle: String { phase == "stopping" ? "Выключаем…" : phase == "stopped" && !flag("saved") ? "Сохранить выключение" : phase == "preparing" ? "Отменить установку" : "Выключить" }
    var footnote: String {
        if diagnosticWaiting { return diagnosticWaitMessage }
        switch phase {
        case "loading", "reconciling": return "Проверяем состояние…"
        case "paused": return observedSleep ? "Ожидаем пробуждения." : "Проверяем состояние macOS."
        case "unknown": return "Статус ключа неизвестен."
        case "data-error": return "Данные требуют проверки."
        case "stopping": return "Освобождаем USB-ключ…"
        case "starting", "recovering": return "Проверяем USB-ключ…"
        case "ready", "probing", "agent-update": return "Может прервать работу 1С."
        case "waiting": return "USB-ключ не найден."
        case "preparing": return "Можно отменить установку."
        case "first": return "Установка на этот Mac."
        default: return editing ? "Установка на этот Mac." : "USB-ключ не используется."
        }
    }
    var autoExplanation: String {
        if autoWorking { return "Сохраняем выбор… Текущая работа KeyBridge не меняется." }
        if pendingAuto != nil { return "Новый выбор автозапуска не сохранён. " + (autoError.isEmpty ? "Повторите сохранение или отмените изменение." : autoError) }
        if !flag("autoAvailable") { return flag("auto") ? "Автозапуск недоступен в этой сборке. Сохранённый выбор можно выключить." : "Автозапуск недоступен в этой сборке. Открывайте KeyBridge вручную." }
        if !flag("auto") { return "Автозапуск выключен. Текущая работа KeyBridge не меняется." }
        if text("permission") == "unregistered" { return "В macOS нет записи автозапуска KeyBridge. Восстановите её, чтобы приложение запускалось при входе." }
        if flag("hold") { return "Автозапуск приостановлен. При следующем входе KeyBridge останется выключенным, пока вы не разрешите запуск." }
        if text("permission") == "denied" { return "Для запуска при входе нужно разрешение macOS. Текущая работа KeyBridge не меняется." }
        if text("permission") == "unknown" { return "Разрешение macOS неизвестно: запуск при входе пока не подтверждён." }
        if !text("safetyBlock").isEmpty || phase == "reconciling" { return "Состояние работы пока не подтверждено. Автозапуск возможен только после успешной проверки." }
        if !flag("prepared") || client != "managed" { return "Перед автозапуском нужно установить программы для ключа и настроить поиск лицензии в 1С." }
        return "KeyBridge сможет включиться при следующем входе. Текущая работа KeyBridge не меняется."
    }
    var permissionValue: String {
        if !flag("autoAvailable") { return "Недоступен в этой сборке" }
        if text("permission") == "unregistered" { return flag("auto") ? "Не зарегистрирован" : "Выключен" }
        if !result("permission").isEmpty { return result("permission") }
        return ["allowed": "Разрешён", "denied": "Запрещён", "unknown": "Не удалось проверить"][text("permission")] ?? "Не удалось проверить"
    }
    var permissionExplanation: String {
        if !flag("autoAvailable") { return "Не удалось подтвердить поддержку запуска при входе. Установите полную сборку KeyBridge из выпуска GitHub." }
        switch text("permission") {
        case "unregistered": return flag("auto") ? "Запись могла быть удалена в настройках macOS. Нажмите «Восстановить автозапуск»." : "Включите переключатель, чтобы KeyBridge запускался при входе в macOS."
        case "allowed": return "macOS разрешает запускать KeyBridge при входе."
        case "denied": return "Разрешите KeyBridge в настройках macOS → «Основные» → «Объекты входа», затем повторите проверку."
        default: return "Не удалось определить разрешение. Проверьте KeyBridge в настройках macOS → «Основные» → «Объекты входа»."
        }
    }
}
