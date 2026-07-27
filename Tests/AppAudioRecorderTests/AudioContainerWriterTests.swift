import AVFoundation
import CoreMedia
import XCTest

@testable import AppAudioRecorder

final class AudioContainerWriterTests: XCTestCase {
    func testWriterPreservesExistingFileByDefault() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("existing.m4a")
        let original = Data("existing".utf8)
        try original.write(to: output)

        XCTAssertThrowsError(
            try AudioContainerWriter(
                outputURL: output,
                configuration: RecordingConfiguration(
                    sampleRate: .hz8K,
                    channelCount: .mono,
                    capturesMicrophone: false
                )
            )
        )
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    func testCancelRemovesIncompleteOutput() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("cancelled.m4a")
        let writer = try AudioContainerWriter(
            outputURL: output,
            configuration: RecordingConfiguration(
                sampleRate: .hz8K,
                channelCount: .mono,
                capturesMicrophone: false
            )
        )

        writer.cancelWriting(removeOutput: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testMissingTrackStartsSessionAfterOneSecondOfPendingAudio() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("bounded-pending.m4a")
        let writer = try AudioContainerWriter(
            outputURL: output,
            configuration: RecordingConfiguration(
                sampleRate: .hz8K,
                channelCount: .mono,
                capturesMicrophone: true
            )
        )

        try writer.append(
            makeSampleBuffer(frameCount: 4_000, presentationTime: .zero),
            to: .app
        )
        XCTAssertEqual(writer.appFrames, 0)

        try writer.append(
            makeSampleBuffer(
                frameCount: 4_000,
                presentationTime: CMTime(value: 4_000, timescale: 8_000)
            ),
            to: .app
        )
        XCTAssertEqual(writer.appFrames, 8_000)

        try writer.finalizeInputs()
        try await writer.completeWriting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testWritesTwoTracksWithRelativeStartOffset() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("two-tracks.m4a")
        let writer = try AudioContainerWriter(
            outputURL: output,
            configuration: RecordingConfiguration(
                sampleRate: .hz8K,
                channelCount: .mono,
                capturesMicrophone: true
            )
        )

        try writer.append(
            makeSampleBuffer(
                frameCount: 800,
                presentationTime: CMTime(seconds: 10.25, preferredTimescale: 8_000)
            ),
            to: .mic
        )
        try writer.append(
            makeSampleBuffer(
                frameCount: 800,
                presentationTime: CMTime(seconds: 10, preferredTimescale: 8_000)
            ),
            to: .app
        )
        try writer.finalizeInputs()
        try await writer.completeWriting()

        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 2)

        let audibleStarts = try tracks.map { try firstAudibleFrame(asset: asset, track: $0) }.sorted()
        XCTAssertEqual(audibleStarts, [0, 2_000])
    }

    func testAcceptsTrackThatFirstProducesAudioAfterSessionStarts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("late-track.m4a")
        let writer = try AudioContainerWriter(
            outputURL: output,
            configuration: RecordingConfiguration(
                sampleRate: .hz8K,
                channelCount: .mono,
                capturesMicrophone: true
            )
        )

        try writer.append(
            makeSampleBuffer(frameCount: 8_000, presentationTime: .zero),
            to: .app
        )
        try await Task.sleep(for: .milliseconds(200))
        try writer.append(
            makeSampleBuffer(
                frameCount: 800,
                presentationTime: CMTime(seconds: 1, preferredTimescale: 8_000)
            ),
            to: .mic
        )
        try writer.finalizeInputs()
        try await writer.completeWriting()

        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 2)
        let audibleStarts = try tracks.map { try firstAudibleFrame(asset: asset, track: $0) }.sorted()
        XCTAssertEqual(audibleStarts, [0, 8_000])
    }

    func testWritesStereoSamples() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("stereo.m4a")
        let writer = try AudioContainerWriter(
            outputURL: output,
            configuration: RecordingConfiguration(
                sampleRate: .hz8K,
                channelCount: .stereo,
                capturesMicrophone: false
            )
        )

        try writer.append(
            makeSampleBuffer(
                frameCount: 800,
                presentationTime: .zero,
                channels: 2
            ),
            to: .app
        )
        try writer.finalizeInputs()
        try await writer.completeWriting()

        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        let descriptions = try await tracks[0].load(.formatDescriptions)
        let streamDescription = descriptions.first.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        }
        XCTAssertEqual(streamDescription?.mChannelsPerFrame, 2)
    }

    func testFinalizePropagatesBufferedAppendFailure() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("invalid-timeline.m4a")
        let writer = try AudioContainerWriter(
            outputURL: output,
            configuration: RecordingConfiguration(
                sampleRate: .hz8K,
                channelCount: .mono,
                capturesMicrophone: true
            )
        )
        writer.cancelWriting(removeOutput: false)

        try writer.append(
            makeSampleBuffer(frameCount: 800, presentationTime: .zero),
            to: .app
        )

        XCTAssertThrowsError(try writer.finalizeInputs())
    }

    private func firstAudibleFrame(asset: AVAsset, track: AVAssetTrack) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: true,
            ]
        )
        guard reader.canAdd(output) else {
            throw TestError.cannotReadTrack
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? TestError.cannotReadTrack
        }
        var precedingFrames = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                var streamDescription =
                    CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
                let format = AVAudioFormat(streamDescription: &streamDescription)
            else {
                throw TestError.cannotReadTrack
            }
            let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw TestError.cannotReadTrack
            }
            pcmBuffer.frameLength = frameCount
            guard
                CMSampleBufferCopyPCMDataIntoAudioBufferList(
                    sampleBuffer,
                    at: 0,
                    frameCount: Int32(frameCount),
                    into: pcmBuffer.mutableAudioBufferList
                ) == noErr, let channels = pcmBuffer.floatChannelData
            else {
                throw TestError.cannotReadTrack
            }

            for frame in 0..<Int(frameCount) {
                for channel in 0..<Int(format.channelCount)
                where abs(channels[channel][frame]) > 0.000_001 {
                    return precedingFrames + frame
                }
            }
            precedingFrames += Int(frameCount)
        }
        throw reader.error ?? TestError.cannotReadTrack
    }

    private func makeSampleBuffer(
        frameCount: Int,
        presentationTime: CMTime,
        sampleRate: Int = 8_000,
        channels: Int = 1
    ) throws -> CMSampleBuffer {
        let bytesPerFrame = channels * MemoryLayout<Float>.size
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw TestError.coreMediaStatus(formatStatus)
        }

        let byteCount = frameCount * bytesPerFrame
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw TestError.coreMediaStatus(blockStatus)
        }

        let samples = [Float](repeating: 0.125, count: frameCount * channels)
        let copyStatus = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw TestError.coreMediaStatus(copyStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw TestError.coreMediaStatus(sampleStatus)
        }
        return sampleBuffer
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

    private enum TestError: Error {
        case cannotReadTrack
        case coreMediaStatus(OSStatus)
    }
}
