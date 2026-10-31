// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var mainWindow: NSWindow?
    private var mayTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.regular)
        showWindow()
    }
    func showWindow() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "KeyBridge"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.identifier = NSUserInterfaceItemIdentifier("keybridge-main")
            window.minSize = NSSize(width: 760, height: 560)
            window.isReleasedWhenClosed = false
            window.contentViewController = KeyBridgeWindowController(model: .shared)
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func finishQuit() { mayTerminate = true; NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if mayTerminate { return .terminateNow }
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
