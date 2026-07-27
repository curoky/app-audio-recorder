import Foundation
import XCTest
@testable import AppAudioRecorder

final class PathSupportTests: XCTestCase {
    func testUniqueFileUsesFirstAvailableSuffix() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = URL.uniqueFile(in: directory, stem: "call", pathExtension: "m4a")
        XCTAssertEqual(first.lastPathComponent, "call.m4a")
        try Data().write(to: first)

        let second = URL.uniqueFile(in: directory, stem: "call", pathExtension: "m4a")
        XCTAssertEqual(second.lastPathComponent, "call-2.m4a")
        try Data().write(to: second)

        let third = URL.uniqueFile(in: directory, stem: "call", pathExtension: "m4a")
        XCTAssertEqual(third.lastPathComponent, "call-3.m4a")
    }

    func testWatchAcceptsWritableDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let command = try WatchCommand.parse(["--output-dir", directory.path])
        XCTAssertEqual(try command.outputDirectory(), directory)
    }

    func testWatchRejectsRegularFileAsOutputDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: file)

        let command = try WatchCommand.parse(["--output-dir", file.path])
        XCTAssertThrowsError(try command.outputDirectory())
    }

    func testWatchRejectsMissingOutputDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing", isDirectory: true)

        let command = try WatchCommand.parse(["--output-dir", missing.path])
        XCTAssertThrowsError(try command.outputDirectory())
    }

    func testExpandingPathExpandsHomeDirectory() {
        let url = URL(expandingPath: "~/recordings")
        XCTAssertEqual(
            url.path,
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("recordings").path
        )
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
