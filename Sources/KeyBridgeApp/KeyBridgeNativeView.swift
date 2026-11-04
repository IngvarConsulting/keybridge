// SPDX-License-Identifier: MIT
import AppKit
import KeyBridgeCore
import SwiftUI

@MainActor
struct KeyBridgeNativeView: View {
    @ObservedObject var interface: KeyBridgeInterfaceState
    private let observeLayout: (([String: CGRect]) -> Void)?
    @FocusState private var focusedAction: String?

    init(interface: KeyBridgeInterfaceState, observeLayout: (([String: CGRect]) -> Void)? = nil) {
        self.interface = interface
        self.observeLayout = observeLayout
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 28) {
                tab("Ключ", "main")
                tab("Настройки", "settings")
                Spacer()
            }
            .padding(.horizontal, 24).frame(height: 46)
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 20)
                    .background(ScrollPositionReader(interface: interface, route: interface.routeKey))
            }
            .accessibilityIdentifier("keybridge-content")
            .interfaceFrame("content")
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .interfaceFrame("root")
        .coordinateSpace(name: "keybridge-native")
        .onPreferenceChange(InterfaceFramesKey.self) { observeLayout?($0) }
        .onChange(of: interface.requestedFocus) { value in
            if let value { focusedAction = value; interface.requestedFocus = nil }
        }
        .onChange(of: focusedAction) { value in
            if let value { interface.lastFocusedAction = value }
        }
        .onChange(of: interface.feedbackRevision) { _ in
            let message = interface.feedbackAnnouncement.isEmpty ? interface.pageCopy.title : interface.feedbackAnnouncement
            NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    private func tab(_ title: String, _ destination: String) -> some View {
        Button { interface.navigate(destination) } label: {
            Text(title).font(.system(size: 14, weight: interface.tab == destination ? .semibold : .regular))
                .foregroundStyle(interface.tab == destination ? Color.primary : Color.secondary)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) {
                    if interface.tab == destination { Rectangle().fill(Color.accentColor).frame(height: 2) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(interface.tab == destination ? .isSelected : [])
        .accessibilityIdentifier("tab-\(destination)")
        .focused($focusedAction, equals: "tab-\(destination)")
    }
    @ViewBuilder private var content: some View {
        switch interface.screen {
        case "settings": settings
        case "setup": setup
        case "manual": manual
        case "additional": additional
        case "resources": resources
        default:
            heading(interface.pageCopy)
            if ["review-settings", "client-unconfigured"].contains(interface.screen) {
                VStack(alignment:.leading,spacing:10) {
                    Text("Общий поиск лицензии для установленных версий 1С")
                    Text("rclic.cfg — адрес нового менеджера лицензий 1С: 127.0.0.1:15441. Широковещательный поиск отключён.")
                    Text("nethasp.ini — адрес для поиска по правилам HASP: 127.0.0.1, порт 15441, UDP. Эти параметры читает и новая 1С. Для клиентов до 8.5.4 этой настройки недостаточно: rmlic не заменяет прежний HASP License Manager.")
                    if let files=interface.state["configurationFiles"] as? [String],!files.isEmpty {
                        Text("Изменяемые файлы:\n" + files.joined(separator:"\n")).textSelection(.enabled)
                    }
                    Text("Версии 1С используют эти общие настройки, если у них нет отдельных переопределений. При конфликте KeyBridge покажет мешающие файлы. Базы и их конфигурации не изменяются.")
                    if !interface.text("configurationError").isEmpty {Text(interface.text("configurationError")).textSelection(.enabled)}
                }.font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            } else if interface.screen == "client-unknown",!interface.text("configurationError").isEmpty {
                Text(interface.text("configurationError")).font(.system(size:12)).textSelection(.enabled)
            } else if interface.screen == "preparing" {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(["Копируем файлы", "Устанавливаем и настраиваем", "Проверяем установку"].enumerated()), id: \.offset) { index, title in
                        HStack(spacing: 10) {
                            Image(systemName: index < (interface.state["step"] as? Int ?? 0) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(index == (interface.state["step"] as? Int ?? 0) ? Color.accentColor : Color.secondary)
                            Text(title)
                        }
                    }
                }
                ProgressView().controlSize(.small)
            } else if ["loading", "starting", "stopping", "recovering", "reconciling", "configuring", "restoring", "restoring-version"].contains(interface.screen) {
                ProgressView().controlSize(.small)
            } else if interface.screen == "ready" {
                row("USB-ключ", interface.keyLabel.isEmpty ? "Подключён" : interface.keyLabel)
            } else if interface.screen == "waiting" {
                row("KeyBridge", "Включён")
                row("USB-ключ", interface.result("key").isEmpty ? "Не найден" : interface.result("key"))
            } else if interface.screen == "diagnosis" { proof }
            else if interface.screen == "permission" { permission }
            else if interface.screen == "client-help" { download("1С", "https://releases.1c.ru/project/Platform85") }
        }
    }
    private func heading(_ copy: InterfacePageCopy) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(copy.title).font(.system(size: 23, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("page-title")
            if !copy.body.isEmpty { paragraph(copy.body) }
            if !copy.remedy.isEmpty { paragraph(copy.remedy) }
        }
    }
    private func paragraph(_ value: String) -> some View {
        Text(value).lineSpacing(3).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).fontWeight(.medium).lineLimit(1).fixedSize()
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(value)
        }
        .padding(.vertical, 8)
    }
    private func download(_ vendor: String, _ url: String) -> some View {
        Button("Скачать с сайта \(vendor) ↗") { interface.request("open-url", value: url) }
            .buttonStyle(.link).fixedSize().accessibilityIdentifier("download-\(vendor)")
            .focused($focusedAction, equals: "download-\(vendor)")
            .interfaceFrame("download-\(vendor)")
    }
    @ViewBuilder private var setup: some View {
        if interface.text("fault") == "space" {
            heading(.init(title: "Установка не началась: не хватает места", body: interface.result("space").isEmpty ? "На Mac недостаточно свободного места для установки выбранных программ." : interface.result("space"), remedy: "Освободите место, затем нажмите «Проверить место». После проверки можно будет продолжить выбор файлов."))
        } else {
            let step = interface.setupStep
            let title = step == "installer" ? "Выберите установщик 1С" : step == "driver" ? "Выберите драйвер USB-ключа" : "Проверьте файлы перед установкой"
            let intro = step == "installer" ? "Сначала выберите два файла и установите программы для ключа. Затем настроим поиск лицензии в 1С на этом Mac." : step == "driver" ? "Установщик 1С уже выбран. Добавьте драйвер USB-ключа." : interface.client == "managed" ? "KeyBridge установит программы из выбранных файлов. Сохранённые настройки поиска лицензии в 1С останутся." : "KeyBridge установит программы из выбранных файлов. После установки останется настроить поиск лицензии в 1С — для этого понадобится разрешение macOS."
            heading(.init(title: title, body: intro))
            Text("Подготовка файлов: шаг \(step == "installer" ? 1 : step == "driver" ? 2 : 3) из 3")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if step == "review" {
                reviewFile("installer", title: "Установщик 1С")
                reviewFile("driver", title: "Драйвер HASP")
                Text("На этом шаге KeyBridge ещё не использует USB-ключ.").foregroundStyle(.secondary)
            } else { fileChoice(step) }
        }
    }
    private func fileChoice(_ kind: String) -> some View {
        let installer = kind == "installer"
        let file = interface.files[kind] ?? InterfaceFile()
        let feedback = interface.result("file-" + kind)
        let status = !feedback.isEmpty ? feedback : file.checking ? (file.message.isEmpty ? "Проверяем файл…" : file.message) : !file.error.isEmpty ? file.error : !file.message.isEmpty ? file.message : file.valid ? "Файл выбран" : "Файл ещё не выбран"
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(installer ? "Установщик 1С" : "Драйвер HASP").fontWeight(.semibold)
                Spacer()
                download(installer ? "1С" : "Thales", installer ? "https://releases.1c.ru/project/Platform85" : "https://supportportal.thalesgroup.com/csm?_runtime_packages=&id=kb_search&query=kbcat_drivers_%26_runtime_packages&u_products_available_in_portal_search=50303b92db852e00d298728dae96199d")
            }
            Text(installer ? "Потребуется учётная запись 1С. Скачайте полную поставку платформы 1С 8.5.4 или новее для Linux x86-64: файл .run или архив ZIP / tar.gz. Менеджер лицензий rmlic появился в 8.5.4. Распаковывать архив не нужно." : "Скачайте Sentinel LDK Run-time для Linux: пакет DEB для amd64 или архив ZIP / tar.gz. Распаковывать не нужно — KeyBridge найдёт драйвер и проверит его программы.")
                .foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(file.name.isEmpty ? "Пример имени: " + (installer ? "setup-full-…-x86_64.run" : "aksusbd_…_amd64.deb") : file.name)
                .lineLimit(1).truncationMode(.middle).help(file.name).accessibilityIdentifier("selected-\(kind)")
                .interfaceFrame("selected-\(kind)")
            HStack(alignment: .top, spacing: 10) {
                if file.checking { ProgressView().controlSize(.small) }
                Text(status).foregroundStyle(!file.error.isEmpty || !feedback.isEmpty ? Color.red : file.valid ? Color.green : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("status-\(kind)")
            }
            .frame(minHeight: 36, alignment: .topLeading)
        }
        .padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
    private func reviewFile(_ kind: String, title: String) -> some View {
        let file = interface.files[kind] ?? InterfaceFile()
        return VStack(alignment: .leading, spacing: 6) {
            row(title, file.valid ? (file.validation == "preflight" ? "Менеджер лицензий заявлен" : "Проверен") : "Не проверен")
            Text(file.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(file.name)
            Divider()
        }
    }
    private var proof: some View {
        let values: [String: (String, String)] = [
            "none": ("Проверьте лицензию в 1С", "Проверка ещё не запускалась."),
            "success": ("1С получила лицензию", "Проверка подтвердила получение лицензии от этого USB-ключа через KeyBridge."),
            "unconfirmed": ("Получение лицензии не подтверждено", "1С выполнила проверку, но её результат не позволяет определить, получена ли лицензия от этого USB-ключа через KeyBridge."),
            "failure": ("1С не завершила проверку", "Проверочное приложение завершилось с ошибкой. Её причину пока не удалось установить. KeyBridge продолжает работать."),
            "timeout": ("Проверка не завершилась", "1С не ответила за время ожидания. Почему она не ответила, пока неизвестно. KeyBridge продолжает работать."),
            "stale": ("Проверьте лицензию ещё раз", "После изменений в работе KeyBridge прежний результат проверки больше не подтверждает получение лицензии.")]
        let checking = interface.phase == "probing" || interface.pendingAction("probe")
        let failure = interface.result("probe")
        let value = interface.diagnosticWaiting && interface.text("pendingDiagnostic") == "probe" ? ("Проверка ожидает", interface.diagnosticWaitMessage) : checking ? ("Проверяем лицензию в 1С", "Запрос отправлен. Результата пока нет.") : !failure.isEmpty ? ("Не удалось выполнить проверку", failure) : values[interface.text("proof")] ?? values["none"]!
        return VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                Text(value.0).font(.system(size: 16, weight: .semibold)).foregroundStyle(interface.text("proof") == "success" && !checking ? Color.green : Color.primary)
                if checking { ProgressView().controlSize(.small) }
            }
            paragraph(value.1)
            if !checking, failure.isEmpty, interface.text("proof") != "none", !interface.proofTime.isEmpty {
                Text("Результат проверки · \(interface.proofTime)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !checking, !interface.proofSaveNote.isEmpty {
                paragraph(interface.proofSaveNote).font(.system(size: 12)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("proof-save-note").interfaceFrame("proof-save-note")
            }
            if interface.text("proof") == "unconfirmed", !checking {
                Text("Теперь посмотрите лицензию в своей базе").fontWeight(.semibold)
                paragraph("Это поможет выяснить, какую лицензию использует ваша 1С.")
                Text("Повторите проверку после изменения настроек поиска лицензии или подключения ключа. Без изменений результат может остаться прежним.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if ["failure", "timeout"].contains(interface.text("proof")), !checking {
                paragraph("Можно также проверить лицензию в своей рабочей базе 1С.")
            }
            if interface.flag("updateProblem") { Text("Если проблема появилась после обновления, выключите KeyBridge — можно будет вернуть предыдущую версию.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Включать KeyBridge при входе в macOS", isOn: Binding(get: { interface.pendingAuto ?? interface.flag("auto") }, set: { interface.chooseAuto($0) }))
                        .toggleStyle(.checkbox).disabled(interface.autoWorking || (!interface.flag("autoAvailable") && !interface.flag("auto")))
                        .accessibilityIdentifier("autostart")
                        .interfaceFrame("autostart")
                    Spacer(minLength: 8)
                    Text(interface.autoWorking ? "Сохраняем…" : interface.pendingAuto != nil ? "Ошибка" : interface.autoSaved ? "Сохранено" : " ")
                        .font(.system(size: 12)).foregroundStyle(interface.pendingAuto != nil && !interface.autoWorking ? Color.red : Color.secondary)
                        .frame(width: 86, alignment: .trailing)
                }
                Text(interface.autoExplanation).foregroundStyle(.secondary).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 34, alignment: .topLeading).padding(.leading, 20)
            }
            permission
            pageLink("Поиск лицензии 1С: rclic.cfg и nethasp.ini", "review-settings")
            if !interface.text("configurationError").isEmpty {
                Text(interface.text("configurationError")).font(.system(size:12)).textSelection(.enabled)
            }
            if interface.client == "external", interface.pendingAuto == nil, !interface.autoWorking {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Поиск лицензии требует настройки").fontWeight(.semibold)
                    Text("rclic.cfg или nethasp.ini отличаются от настройки KeyBridge. Нажмите «Исправить настройки», чтобы посмотреть пути файлов и подтвердить изменение.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            company
        }
    }
    private var permission: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Запуск при входе", interface.permissionValue)
            Text(interface.permissionExplanation).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var company: some View {
        Button {
            interface.request("open-url", value: "https://ingvar.pro/?utm_source=keybridge&utm_medium=app&utm_campaign=settings")
        } label: {
            HStack(alignment: .center, spacing: 20) {
                if let image = companyImage { Image(nsImage: image).resizable().scaledToFit().frame(width: 248, height: 44) }
                else { Text("Ingvar Consulting").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white).frame(width: 248) }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ingvar Consulting помогает 1С-командам разбирать процессы разработки: планирование, релизы, ревью, онбординг и повышает управляемость команды.")
                        .font(.system(size: 12)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    Text("ingvar.pro →").font(.system(size: 12, weight: .semibold))
                }.foregroundStyle(Color(white: 0.88))
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.106, green: 0.165, blue: 0.267), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityLabel("Ingvar Consulting — открыть сайт в браузере").accessibilityIdentifier("company-banner")
            .interfaceFrame("company-banner")
    }
    private var companyImage: NSImage? {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("ingvar-consulting.png"), Bundle.main.resourceURL?.appendingPathComponent("interface/ingvar-consulting.png"), sourceRoot.appendingPathComponent("Resources/ingvar-consulting.png"), sourceRoot.appendingPathComponent("Resources/interface/ingvar-consulting.png")]
        for case let url? in candidates {
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }
    private var additional: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(interface.pageCopy)
            Text("Программы для ключа").fontWeight(.semibold)
            Text(interface.flag("prepared") ? (interface.componentLabel.isEmpty ? "Программы установлены" : interface.componentLabel) : "Ещё не установлены").foregroundStyle(.secondary)
            Text("Если нужно выбрать другой установщик 1С или драйвер ключа. Сначала выключите KeyBridge.").font(.system(size: 12)).foregroundStyle(.secondary)
            Divider()
            Text("Поиск лицензии в 1С").fontWeight(.semibold)
            Text("rclic.cfg — новый менеджер лицензий; nethasp.ini — поиск по правилам HASP. KeyBridge сохраняет оба файла перед изменением.").font(.system(size:12)).foregroundStyle(.secondary)
            pageLink("Что изменяет настройка", "review-settings")
            Text(interface.flag("clientRestored") ? "Прежний поиск лицензии восстановлен." : "Вернуть поиск лицензии, который был до KeyBridge.")
            Text(interface.flag("clientRestored") ? "1С больше не ищет лицензию через KeyBridge. Базы и конфигурации не изменены." : "1С перестанет искать лицензию через KeyBridge. Базы и конфигурации 1С не изменятся.").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                pageLink("Технические сведения", "resources")
            }.padding(.top, 4)
        }
    }
    private func pageLink(_ title: String, _ action: String) -> some View {
        Button("\(title) →") { interface.perform(action) }.buttonStyle(.link).focused($focusedAction, equals: action).accessibilityIdentifier(action)
    }
    private var resources: some View {
        VStack(alignment: .leading, spacing: 2) {
            heading(interface.pageCopy).padding(.bottom, 12)
            if interface.resourceRows.isEmpty {
                row("Память для работы с ключом", "Нет данных")
                row("Время замера", "Измерение не проводилось")
            } else {
                ForEach(Array(interface.resourceRows.enumerated()), id: \.offset) { _, item in row(item.label, item.value); Divider() }
            }
            Text(!interface.result("resources").isEmpty ? interface.result("resources") : interface.resourcesNote.isEmpty ? "Физически занятое место на Mac и виртуальная ёмкость диска — разные величины. Память Linux и процесса на Mac измеряются отдельно." : interface.resourcesNote)
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
        }
    }
    private var manual: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(.init(title: "Посмотрите лицензию в своей базе 1С", body: ""))
            paragraph("1. Откройте свою рабочую базу в приложении 1С.")
            paragraph("2. В меню окна 1С выберите «Сервис и настройки» → «О программе». В старом интерфейсе — «Справка» → «О программе».")
            paragraph("3. Откройте страницу «Лицензия». Если отдельной страницы нет, найдите раздел «Лицензия» и строку «Текущая». Смотрите клиентскую лицензию, которую 1С использует сейчас.")
            Text("Что означает запись").font(.system(size: 16, weight: .semibold))
            paragraph("Например, «Сетевой HASP …» означает получение лицензии от сетевого USB-ключа. Регистрационный номер и путь к файлу — локальную программную лицензию. «Выдал сервер» означает выдачу сервером 1С. Вид записи зависит от версии 1С.")
            paragraph("Надпись HASP сама по себе не подтверждает получение через KeyBridge. Результат проверки в KeyBridge от чтения этой записи не изменится.").foregroundStyle(.secondary)
            Text("Если запись непонятна или база не открывается").font(.system(size: 16, weight: .semibold))
            paragraph("Обратитесь к специалисту, который настраивает вашу 1С. Сообщите запись о текущей клиентской лицензии или текст сообщения при открытии базы. Попросите проверить поиск лицензии от USB-ключа через KeyBridge.")
        }
    }
    private var footer: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                if let back = interface.backAction { actionButton(back) }
                if interface.screen != "stop-unsaved" {
                    actionButton(.init(id: "stop", title: interface.stopTitle, disabled: interface.stopDisabled))
                }
                Menu {
                    Button("Выключить и выйти") { interface.perform("quit") }
                } label: { Image(systemName: "ellipsis").frame(width: 18) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Действия KeyBridge")
                Spacer(minLength: 6)
                ForEach(interface.footerActions) { action in actionButton(action) }
            }
            .frame(height: 36)
            HStack {
                Text(interface.footnote).lineLimit(1)
                Spacer()
                if interface.screen == "diagnosis" { Text("Откроется пустая база.").lineLimit(1).frame(width: 168) }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.top, 9).frame(height: 100)
        .accessibilityIdentifier("keybridge-actions")
        .interfaceFrame("footer")
    }
    @ViewBuilder private func actionButton(_ action: InterfaceAction) -> some View {
        let button = Button { interface.lastFocusedAction = action.id; interface.perform(action.id) } label: {
            Text(action.title).lineLimit(1).fixedSize()
                .frame(maxWidth: action.id == "probe" ? .infinity : nil, minHeight: 24)
        }
        .controlSize(.large)
        .disabled(action.disabled)
        .focused($focusedAction, equals: action.id)
        .accessibilityIdentifier(action.id)
        if action.primary { button.buttonStyle(.borderedProminent).frame(width: action.id == "probe" ? 168 : nil, height: 36).interfaceFrame(action.id) }
        else { button.buttonStyle(.bordered).frame(width: action.id == "probe" ? 168 : nil, height: 36).interfaceFrame(action.id) }
    }
}

private struct InterfaceFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}
private extension View {
    func interfaceFrame(_ id: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: InterfaceFramesKey.self, value: [id: proxy.frame(in: .named("keybridge-native"))])
        })
    }
}

/// Keeps the native central scroll view at the user's position when visiting a
/// help page and returning. Status polling does not recreate the scroll view.
private struct ScrollPositionReader: NSViewRepresentable {
    let interface: KeyBridgeInterfaceState
    let route: String
    func makeCoordinator() -> Coordinator { Coordinator(interface: interface) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(view.enclosingScrollView, route: route) }
    }
    @MainActor final class Coordinator {
        let interface: KeyBridgeInterfaceState
        weak var scroll: NSScrollView?
        var observer: NSObjectProtocol?
        var route = ""
        var restoring = false
        init(interface: KeyBridgeInterfaceState) { self.interface = interface }
        func attach(_ scroll: NSScrollView?, route next: String) {
            guard let scroll else { return }
            if self.scroll !== scroll {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                self.scroll = scroll
                scroll.contentView.postsBoundsChangedNotifications = true
                observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.restoring, !self.route.isEmpty else { return }
                        self.interface.scrollPositions[self.route] = self.scroll?.contentView.bounds.origin.y ?? 0
                    }
                }
            }
            guard route != next else { return }
            route = next; restoring = true
            scroll.contentView.scroll(to: NSPoint(x: 0, y: interface.scrollPositions[next] ?? 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            restoring = false
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
