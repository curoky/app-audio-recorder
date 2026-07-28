import Foundation
import XCTest

@testable import AppAudioRecorder

final class RecordingFilesTests: XCTestCase {
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

    func testAcceptsWritableDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNoThrow(try RecordingFiles.validateOutputDirectory(directory))
    }

    func testRejectsRegularFileAsOutputDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: file)

        XCTAssertThrowsError(try RecordingFiles.validateOutputDirectory(file))
    }

    func testRejectsMissingOutputDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing", isDirectory: true)

        XCTAssertThrowsError(try RecordingFiles.validateOutputDirectory(missing))
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
