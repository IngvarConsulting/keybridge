// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import XCTest
@testable import KeyBridgeApp

/// Hosts production SwiftUI directly. The injected store records commands only;
/// these tests never construct AppModel, run an agent, or open an installer.
@MainActor
final class NativeInterfaceRenderingTests: XCTestCase {
    func testFirstLaunchRequiresBothFilesAndSelectionKeepsDownloadHelpInPlace() async throws {
        let rendered = NativeRenderedInterface(["phase": "first", "prepared": false, "client": "missing"])
        defer { rendered.close() }
        await rendered.settle()
        XCTAssertEqual(rendered.interface.screen, "setup")
        XCTAssertTrue(try XCTUnwrap(rendered.interface.footerActions.last).disabled)
        let download = try rendered.frame("download-1С")
        let footer = try rendered.frame("setup-next")
        rendered.interface.update(["files": ["installer": ["name": String(repeating: "long-", count: 30) + "server.zip", "valid": true, "validation": "preflight", "message": "Менеджер лицензий заявлен в составе"]]])
        await rendered.settle()
        XCTAssertFalse(try XCTUnwrap(rendered.interface.footerActions.last).disabled)
        XCTAssertEqual(try rendered.frame("download-1С"), download)
        XCTAssertEqual(try rendered.frame("setup-next"), footer)
        XCTAssertLessThanOrEqual(try rendered.frame("selected-installer").height, 24)
        rendered.interface.perform("setup-next")
        await rendered.settle()
        XCTAssertTrue(try XCTUnwrap(rendered.interface.footerActions.last).disabled)
        XCTAssertGreaterThan(try rendered.frame("download-Thales").width, 0)
        XCTAssertTrue(rendered.requests.isEmpty)
        try rendered.assertRendered()
    }

    func testSettingsBannerFitsAndSavingFeedbackDoesNotMoveControls() async throws {
        let rendered = NativeRenderedInterface()
        defer { rendered.close() }
        rendered.interface.navigate("settings")
        await rendered.settle()
        let banner = try rendered.frame("company-banner")
        let toggle = try rendered.frame("autostart")
        let additional = try rendered.frame("additional-actions")
        let scroll = try XCTUnwrap(rendered.scrollViews.single)
        let viewport = try rendered.frame("content")
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(banner), "Banner \(banner), viewport \(viewport)")
        XCTAssertLessThanOrEqual(scroll.documentView?.frame.height ?? .infinity, scroll.contentView.bounds.height + 1)
        let enable = try XCTUnwrap(rendered.interface.request("autostart", value: true))
        rendered.interface.update(["state": ["auto": true, "hold": false], "feedback": ["id": enable["id"]!, "action": "autostart", "ok": true]])
        await rendered.settle()
        XCTAssertEqual(try rendered.frame("autostart"), toggle)
        XCTAssertEqual(try rendered.frame("company-banner"), banner)
        XCTAssertEqual(try rendered.frame("additional-actions"), additional)
        try rendered.assertRendered()
    }

    func testProbeButtonRetainsFrameAndLabelAcrossAllDiagnosticResults() async throws {
        let rendered = NativeRenderedInterface(["phase": "ready", "key": true])
        defer { rendered.close() }
        rendered.interface.perform("diagnose")
        await rendered.settle()
        let baseline = try rendered.frame("probe")
        XCTAssertEqual(baseline.width, 168)
        XCTAssertEqual(baseline.height, 36)
        for proof in ["none", "success", "unconfirmed", "failure", "timeout", "stale"] {
            rendered.interface.update(["state": ["proof": proof]])
            await rendered.settle()
            let button = try XCTUnwrap(rendered.interface.footerActions.first { $0.id == "probe" })
            XCTAssertEqual(button.title, "Проверить в 1С", proof)
            XCTAssertEqual(try rendered.frame("probe"), baseline, proof)
            XCTAssertFalse(button.disabled, proof)
        }
        let rejected = try XCTUnwrap(rendered.interface.request("probe"))
        rendered.interface.update(["feedback": ["id": rejected["id"]!, "action": "probe", "ok": false,
            "message": "Проверка 1С не началась: KeyBridge ещё выполняет другое действие. Подождите несколько секунд и нажмите «Проверить в 1С»."]])
        await rendered.settle()
        XCTAssertFalse(rendered.interface.result("probe").isEmpty)
        XCTAssertEqual(try rendered.frame("probe"), baseline)
        rendered.interface.update(["state": ["phase": "probing"]])
        await rendered.settle()
        XCTAssertEqual(try rendered.frame("probe"), baseline)
        XCTAssertTrue(try XCTUnwrap(rendered.interface.footerActions.last).disabled)
        XCTAssertEqual(rendered.requests.count, 1)
        try rendered.assertRendered()
    }

    func testUnsavedProofAndQueuedDiagnosticRemainVisibleWithoutMovingActions() async throws {
        let rendered=NativeRenderedInterface(["phase":"ready","key":true,"proof":"success"])
        defer {rendered.close()}
        rendered.interface.perform("diagnose")
        await rendered.settle()
        let footer=try rendered.frame("footer"),probe=try rendered.frame("probe")
        rendered.interface.update(["state":["proofSaveError":"Недостаточно места"]])
        await rendered.settle()
        XCTAssertGreaterThan(try rendered.frame("proof-save-note").height,0)
        XCTAssertEqual(rendered.interface.text("proof"),"success")
        XCTAssertEqual(try rendered.frame("footer"),footer)
        XCTAssertEqual(try rendered.frame("probe"),probe)
        rendered.interface.update(["state":["phase":"starting","operationPending":true,"pendingDiagnostic":"probe"]])
        await rendered.settle()
        XCTAssertEqual(rendered.interface.footnote,"Проверка ожидает завершения текущего действия")
        XCTAssertEqual(try rendered.frame("footer"),footer)
        try rendered.assertRendered()
    }

    func testRecoveryActionsStayInsideOneFooterRowAtMinimumWidth() async throws {
        let cases: [(String, [String: Any], String)] = [
            ("rollback", ["phase": "rollback-error", "previousAvailable": true], ""),
            ("start", ["phase": "start-error", "previousAvailable": true], ""),
            ("exhausted", ["phase": "exhausted", "previousAvailable": true], ""),
            ("monitor", ["phase": "ready", "key": true], "monitor-error"),
            ("diagnosis", ["phase": "ready", "key": true, "proof": "unconfirmed"], "diagnosis"),
            ("settings", ["auto": true, "permission": "unregistered"], "settings")
        ]
        for (name, state, route) in cases {
            let rendered = NativeRenderedInterface(state)
            defer { rendered.close() }
            if route == "settings" { rendered.interface.navigate("settings") }
            else if !route.isEmpty { rendered.interface.push(route) }
            await rendered.settle()
            try rendered.assertFooterFits(name)
        }
        let saving = NativeRenderedInterface()
        defer { saving.close() }
        saving.interface.navigate("settings")
        let enable = try XCTUnwrap(saving.interface.request("autostart", value: true))
        saving.interface.update(["feedback": ["id": enable["id"]!, "action": "autostart", "ok": false,
                                              "message": String(repeating: "Ошибка сохранения. ", count: 25)]])
        await saving.settle()
        try saving.assertFooterFits("failed preference")
        try saving.assertRendered()
    }

    func testLongHelpScrollsOnlyCentralContentAndLeavesFooterFixed() async throws {
        let rendered = NativeRenderedInterface(["phase": "ready", "key": true])
        defer { rendered.close() }
        rendered.interface.perform("diagnose")
        rendered.interface.perform("manual-license")
        await rendered.settle()
        let scroll = try XCTUnwrap(rendered.scrollViews.single)
        let back = try rendered.frame("back")
        let stop = try rendered.frame("stop")
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        scroll.reflectScrolledClipView(scroll.contentView)
        await rendered.settle()
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
        XCTAssertEqual(try rendered.frame("back"), back)
        XCTAssertEqual(try rendered.frame("stop"), stop)
        XCTAssertEqual(rendered.scrollViews.count, 1)
        XCTAssertEqual(rendered.hosting.frame.size, NSSize(width: 760, height: 532))
        try rendered.assertRendered()
    }
}

@MainActor
private final class NativeRenderedInterface {
    let interface: KeyBridgeInterfaceState
    let hosting: NSHostingView<KeyBridgeNativeView>
    let window: NSWindow
    private let recorder: RequestRecorder
    private let layout: LayoutRecorder
    var requests: [[String: Any]] { recorder.values }

    init(_ state: [String: Any] = [:]) {
        _ = NSApplication.shared
        let recorder = RequestRecorder()
        self.recorder = recorder
        let layout = LayoutRecorder()
        self.layout = layout
        interface = KeyBridgeInterfaceState(send: { recorder.values.append($0) })
        interface.update(["state": ["phase": "stopped", "prepared": true, "client": "managed", "key": false,
                                    "want": false, "saved": true, "hold": false, "auto": false, "autoAvailable": true,
                                    "permission": "allowed", "contextVersion": "native-render", "operationPending": false]
            .merging(state) { _, new in new }])
        hosting = NSHostingView(rootView: KeyBridgeNativeView(interface: interface, observeLayout: { layout.frames = $0 }))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 532)
        window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
    }

    func close() { window.contentView = nil; window.close() }
    func settle() async {
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        hosting.layoutSubtreeIfNeeded()
    }
    var scrollViews: [NSScrollView] {
        func collect(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(collect)
        }
        return collect(hosting)
    }
    func frame(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        try XCTUnwrap(layout.frames[identifier], "Missing rendered layout for \(identifier). Present: \(layout.frames.keys.sorted())", file: file, line: line)
    }
    func assertFooterFits(_ scenario: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var ids = interface.footerActions.map(\.id)
        if let back = interface.backAction { ids.append(back.id) }
        if interface.screen != "stop-unsaved" { ids.append("stop") }
        let frames = try ids.map { try frame($0, file: file, line: line) }.sorted { $0.minX < $1.minX }
        let bounds = hosting.bounds
        for frame in frames {
            XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(scenario): footer action \(frame) exceeds \(bounds)", file: file, line: line)
            XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 2, "\(scenario): second row", file: file, line: line)
        }
        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(left.maxX, right.minX + 1, "\(scenario): overlapping actions", file: file, line: line)
        }
        XCTAssertEqual(hosting.frame.size, NSSize(width: 760, height: 532), file: file, line: line)
    }
    func assertRendered(file: StaticString = #filePath, line: UInt = #line) throws {
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds), file: file, line: line)
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0, file: file, line: line)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0, file: file, line: line)
    }
}

@MainActor
private final class RequestRecorder { var values: [[String: Any]] = [] }

@MainActor
private final class LayoutRecorder { var frames: [String: CGRect] = [:] }

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
