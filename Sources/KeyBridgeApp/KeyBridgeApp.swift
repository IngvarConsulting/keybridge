// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import KeyBridgeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var mainWindow: NSWindow?
    private var mayTerminate = false
    private var finishingQuit = false
    private var sessionTerminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        let login = LoginLaunch.isLoginEvent(NSAppleEventManager.shared().currentAppleEvent)
        NSApp.setActivationPolicy(login ? .accessory : .regular)
        if login { AppModel.shared.resumeAtLogin() }
        else { showWindow(); AppModel.shared.restoreControllerIfNeeded() }
    }
    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil {
            let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            let frame = NSRect(x: 0, y: 0, width: 760, height: 560)
            let window = NSWindow(contentRect: NSWindow.contentRect(forFrameRect: frame, styleMask: style),
                                  styleMask: style,
                                  backing: .buffered, defer: false)
            window.title = "KeyBridge"
            window.identifier = NSUserInterfaceItemIdentifier("keybridge-main")
            window.minSize = frame.size
            window.isReleasedWhenClosed = false
            window.contentViewController = KeyBridgeWindowController(model: .shared, contentSize: window.contentLayoutRect.size)
            window.center()
            mainWindow = window
        }
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func finishQuit() {
        guard !finishingQuit else { return }
        finishingQuit = true
        AppModel.shared.beginTermination()
        Task {
            await AppModel.shared.finishImports()
            mayTerminate = true
            NSApp.terminate(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if mayTerminate { return .terminateNow }
        if sessionTerminationPending { return .terminateLater }
        if LoginLaunch.isSessionTerminationEvent(NSAppleEventManager.shared().currentAppleEvent) {
            sessionTerminationPending = true
            AppModel.shared.endSession { [weak self] succeeded in
                self?.sessionTerminationPending = false
                self?.mayTerminate = succeeded
                sender.reply(toApplicationShouldTerminate: succeeded)
            }
            return .terminateLater
        }
        AppModel.shared.requestQuit()
        return .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return false
    }
}

@main
struct KeyBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        MenuBarExtra("KeyBridge", systemImage: model.running ? "key.fill" : "key") {
            Text(model.title)
            Divider()
            Button("Открыть окно") { AppDelegate.shared?.showWindow() }
            Button("Посмотреть занятые лицензии") { model.command("monitor") }.disabled(model.busy)
            Button("1С не получает лицензию") {
                AppDelegate.shared?.showWindow(); model.navigate?("diagnosis")
            }
            Button("Настройки") {
                AppDelegate.shared?.showWindow(); model.navigate?("settings")
            }
            Divider()
            Button("Выключить") { model.command("stop") }
            Button("Выключить и выйти") { model.requestQuit() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appTermination) {
                Button("Выключить и выйти") { model.requestQuit() }.keyboardShortcut("q")
            }
        }
    }
}
