import Foundation
import XCTest
@testable import AppAudioRecorderCLI

final class CommandValidationTests: XCTestCase {
    func testRecordRejectsInvalidAudioConfiguration() {
        XCTAssertThrowsError(try RecordCommand.parse(["--sample-rate", "7999"]))
        XCTAssertThrowsError(try RecordCommand.parse(["--sample-rate", "48001"]))
        XCTAssertThrowsError(try RecordCommand.parse(["--channels", "3"]))
        XCTAssertThrowsError(try RecordCommand.parse(["--duration=-1"]))
    }

    func testRecordAcceptsSupportedAudioBoundaries() throws {
        let minimum = try RecordCommand.parse(["--sample-rate", "8000", "--channels", "1"])
        XCTAssertEqual(minimum.sampleRate, 8_000)
        XCTAssertEqual(minimum.channels, 1)

        let maximum = try RecordCommand.parse(["--sample-rate", "48000", "--channels", "2"])
        XCTAssertEqual(maximum.sampleRate, 48_000)
        XCTAssertEqual(maximum.channels, 2)
    }

    func testRecordRejectsBlankAppQuery() {
        XCTAssertThrowsError(try RecordCommand.parse(["--app", " \n "]))
    }

    func testRecordRejectsBlankOutputPath() {
        XCTAssertThrowsError(try RecordCommand.parse(["--output", " \n "]))
    }

    func testRecordDefaultOutputUsesFirstAvailableName() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = try RecordCommand.parse([])
        let date = Date(timeIntervalSince1970: 0)

        let first = try command.containerURL(
            appName: "Test/App",
            date: date,
            defaultDirectory: directory
        )
        try Data().write(to: first)
        let second = try command.containerURL(
            appName: "Test/App",
            date: date,
            defaultDirectory: directory
        )

        XCTAssertEqual(second.deletingPathExtension().lastPathComponent, "\(first.deletingPathExtension().lastPathComponent)-2")
        XCTAssertEqual(second.pathExtension, "m4a")
    }

    func testRecordExplicitOutputNormalizesSupportedExtension() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = try RecordCommand.parse([
            "--output", directory.appendingPathComponent("call.wav").path,
        ])

        let output = try command.containerURL(appName: "Test")

        XCTAssertEqual(output, directory.appendingPathComponent("call.m4a"))
    }

    func testWatchRejectsInvalidConfiguration() {
        XCTAssertThrowsError(try WatchCommand.parse(["--sample-rate", "7999"]))
        XCTAssertThrowsError(try WatchCommand.parse(["--sample-rate", "48001"]))
        XCTAssertThrowsError(try WatchCommand.parse(["--channels", "3"]))
        XCTAssertThrowsError(try WatchCommand.parse(["--silence=-1"]))
        XCTAssertThrowsError(try WatchCommand.parse(["--silence", "inf"]))
        XCTAssertThrowsError(try WatchCommand.parse(["--silence", "nan"]))
    }

    func testWatchAcceptsSupportedBoundaries() throws {
        let command = try WatchCommand.parse([
            "--sample-rate", "8000",
            "--channels", "1",
            "--silence", "0",
        ])
        XCTAssertEqual(command.sampleRate, 8_000)
        XCTAssertEqual(command.channels, 1)
        XCTAssertEqual(command.silence, 0)
    }

    func testWatchRejectsBlankAppQuery() {
        XCTAssertThrowsError(try WatchCommand.parse(["--app", " \n "]))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }
}
