// SPDX-License-Identifier: MIT
import XCTest
@testable import KeyBridgeCore

final class PreparationPresentationTests: XCTestCase {
    private func snapshot(_ state: String = "running", phase: String = "manager_install", finished: String = "null") throws -> PreparationSnapshot {
        try JSONDecoder().decode(PreparationSnapshot.self, from: Data("""
        {"id":"test","state":"\(state)","phase":"\(phase)","startedAt":100,"phaseStartedAt":140,"updatedAt":190,"lastOutputAt":150,"finishedAt":\(finished)}
        """.utf8))
    }
    func testSilentInstallerDoesNotClaimMeasuredCompletion() throws {
        let progress = try snapshot()
        XCTAssertEqual(progress.stageIndex, 3)
        XCTAssertEqual(progress.elapsed(at: Date(timeIntervalSince1970: 200)), "1:40")
        XCTAssertTrue(progress.activity(at: Date(timeIntervalSince1970: 200)).contains("0:50 назад"))
        XCTAssertTrue(progress.detail.contains("без новых строк"))
    }
    func testGuestImportValidationIsNotPresentedAsFirstBoot() throws {
        let progress = try snapshot(phase: "verify_imports")
        XCTAssertEqual(progress.stageIndex, 3)
        XCTAssertEqual(progress.action, "Проверяем установщики в Alpine")
        XCTAssertTrue(progress.detail.contains("уже загрузился"))
    }
    func testStaleHeartbeatDoesNotClaimAgentIsAlive() throws {
        XCTAssertEqual(try snapshot().activity(at: Date(timeIntervalSince1970: 220)), "Ожидаем обновления статуса от фонового агента")
    }
    func testFinishedDurationStopsAndFailureIsNotSuccess() throws {
        let progress = try snapshot("failed", finished: "220")
        XCTAssertFalse(progress.isRunning)
        XCTAssertEqual(progress.elapsed(at: Date(timeIntervalSince1970: 600)), "2:00")
        XCTAssertEqual(progress.heading, "Подготовка не завершена")
    }
    func testRestartExplainsInterruptionWithoutInventingInstallerError() throws {
        let progress = try JSONDecoder().decode(PreparationSnapshot.self, from: Data("""
        {"id":"test","state":"failed","phase":"manager_install","startedAt":100,"phaseStartedAt":140,"updatedAt":220,"lastOutputAt":150,"finishedAt":220,"recoveryReason":"agent_restarted"}
        """.utf8))
        XCTAssertFalse(progress.isRunning)
        XCTAssertTrue(progress.detail.contains("агент перезапустился"))
        XCTAssertFalse(progress.detail.contains("Устраните указанную ошибку"))
    }
    func testTailIsBoundedAndRemovesTerminalEscapes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((String(repeating: "old line\n", count: 1000) + "\u{001B}[32mГотово\u{001B}[0m\rследующий шаг").utf8).write(to: url)
        let tail = try PreparationConsole.tail(at: url, maximumBytes: 100)
        XCTAssertTrue(tail.contains("Готово\nследующий шаг"))
        XCTAssertFalse(tail.contains("\u{001B}"))
        XCTAssertLessThan(tail.utf8.count, 300)
    }
}
