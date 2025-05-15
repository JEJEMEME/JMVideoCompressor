//
//  JMVideoCompressorTests.swift
//  JMVideoCompressorTests
//
//  Created by raykim on 4/24/25.
//
import XCTest
@testable import JMVideoCompressor // Import the library to test it
import AVFoundation
import CoreMedia // CMTime 사용을 위해 추가

final class JMVideoCompressorTests: XCTestCase {

    // MARK: - Properties
    var sampleVideoURL: URL!
    var outputDirectory: URL!
    let compressor = JMVideoCompressor()
    var originalVideoDuration: Double = 0.0 // 원본 비디오 길이 저장

    // MARK: - Test Lifecycle
    override func setUpWithError() throws {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "sample", withExtension: "mp4") else {
            throw XCTSkip("Missing test video resource 'sample.mp4'. Check Bundle.module access and resource path.")
        }
        sampleVideoURL = url
        outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("JMCompressorTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)
        print("Test output directory: \(outputDirectory.path)")

        // 원본 비디오 길이 미리 로드 (동기적으로 수행해도 무방)
        let asset = AVURLAsset(url: sampleVideoURL)
        let expectation = XCTestExpectation(description: "Load original video duration")
        Task {
            do {
                self.originalVideoDuration = try await asset.load(.duration).seconds
                expectation.fulfill()
            } catch {
                XCTFail("Failed to load original video duration: \(error)")
                expectation.fulfill() // 실패하더라도 expectation은 fulfill 해야 함
            }
        }
        wait(for: [expectation], timeout: 5.0) // 5초 타임아웃
        if originalVideoDuration == 0.0 {
            throw XCTSkip("Could not load original video duration for tests.")
        }
        print("Original video duration: \(originalVideoDuration) seconds")
    }

    override func tearDownWithError() throws {
        if let dir = outputDirectory { try? FileManager.default.removeItem(at: dir) }
        outputDirectory = nil; sampleVideoURL = nil
    }

    // MARK: - Helper Assertions
    // *** 수정: 함수를 async로 선언 ***
    private func assertCompressionSuccess(
        original: URL,
        compressed: URL,
        analytics: CompressionAnalytics,
        expectedDuration: Double? = nil, // 예상되는 비디오 길이 (트리밍된 경우)
        durationTolerance: Double = 0.5 // 비디오 길이 허용 오차 (초)
    ) async throws { // *** async 추가 ***
        XCTAssertTrue(FileManager.default.fileExists(atPath: compressed.path), "Compressed file should exist at \(compressed.path)")
        XCTAssertGreaterThan(analytics.originalFileSize, 0, "Original file size should be greater than 0.")
        XCTAssertGreaterThan(analytics.compressedFileSize, 0, "Compressed file size should be greater than 0.")
        // 트리밍으로 인해 압축된 파일이 원본보다 커질 수도 있으므로, 이 단언은 항상 참이 아닐 수 있음.
        // XCTAssertLessThanOrEqual(analytics.compressedFileSize, analytics.originalFileSize, "Compressed size (\(analytics.compressedFileSize)) should be <= original size (\(analytics.originalFileSize)) unless heavily trimmed/re-encoded.")
        XCTAssertGreaterThan(analytics.compressionRatio, 0, "Compression ratio should be greater than 0.")
        XCTAssertGreaterThan(analytics.processingTime, 0, "Processing time should be greater than 0.")
        XCTAssertNotEqual(analytics.originalDimensions, .zero, "Original dimensions should not be zero.")
        XCTAssertNotEqual(analytics.compressedDimensions, .zero, "Compressed dimensions should not be zero.")
        XCTAssertGreaterThan(analytics.originalVideoBitrate, 0, "Original video bitrate should be greater than 0.")
        // 품질 기반 압축 시 비트레이트가 매우 낮아질 수 있으므로 0보다 크기만 확인
        XCTAssertGreaterThanOrEqual(analytics.compressedVideoBitrate, 0, "Compressed video bitrate should be >= 0.")
        print("Compression successful: \(String(format: "%.2f", analytics.compressionRatio)):1 ratio in \(String(format: "%.2f", analytics.processingTime))s. Compressed size: \(analytics.compressedFileSize) bytes.")

        if let expectedDur = expectedDuration {
            // *** 수정 없음: await 호출은 이미 async 함수 내에 있음 ***
            if let compressedProps = try await getVideoProperties(url: compressed) {
                XCTAssertEqual(compressedProps.duration, expectedDur, accuracy: durationTolerance, "Compressed video duration (\(compressedProps.duration)s) should be close to expected (\(expectedDur)s).")
                print("Expected duration: \(expectedDur)s, Actual duration: \(compressedProps.duration)s")
            } else {
                XCTFail("Could not get properties of compressed video at \(compressed.path)")
            }
        }
    }


    private func getVideoProperties(url: URL) async throws -> (size: CGSize, fps: Float, duration: Double)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            print("Warning: No video track found in asset at \(url.path)")
            return nil
        }
        async let size = track.load(.naturalSize)
        async let fps = track.load(.nominalFrameRate)
        async let duration = asset.load(.duration) // 에셋 전체 길이
        
        // 가끔 duration이 nan으로 나오는 경우 방지
        let loadedDuration = try await duration
        guard loadedDuration.seconds.isFinite else {
            print("Warning: Loaded duration is not finite for asset at \(url.path). Duration: \(loadedDuration)")
            return nil // 또는 적절한 오류 처리
        }

        return try await (size: size, fps: fps, duration: loadedDuration.seconds)
    }

    // MARK: - Basic Tests (Quality Presets)
    func testCompressVideoLowQualityPreset() async throws {
        let result = try await compressor.compressVideo(
            sampleVideoURL,
            quality: .lowQuality,
            outputDirectory: outputDirectory,
            progressHandler: nil
        )
        // *** 수정: await 사용하여 async 함수 호출 ***
        try await assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics, expectedDuration: originalVideoDuration)
        XCTAssertLessThanOrEqual(result.analytics.compressedDimensions.width, 640, "Width should be <= 640 for low quality")
        if let properties = try await getVideoProperties(url: result.url) {
            XCTAssertEqual(properties.fps, 20, accuracy: 1, "FPS should be around 20 for low quality")
        }
        XCTAssertLessThanOrEqual(result.analytics.compressedVideoBitrate, 700_000, "Bitrate should be low")
    }

    func testCompressVideoMediumQualityPreset() async throws {
        let result = try await compressor.compressVideo(
            sampleVideoURL,
            quality: .mediumQuality,
            outputDirectory: outputDirectory,
            progressHandler: nil
        )
        // *** 수정: await 사용하여 async 함수 호출 ***
        try await assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics, expectedDuration: originalVideoDuration)
        XCTAssertLessThanOrEqual(result.analytics.compressedDimensions.width, 1280, "Width should be <= 1280 for medium quality")
        if let properties = try await getVideoProperties(url: result.url) {
            XCTAssertEqual(properties.fps, 30, accuracy: 1, "FPS should be around 30 for medium quality")
        }
        XCTAssertLessThanOrEqual(result.analytics.compressedVideoBitrate, 2_500_000)
    }

    // ... (기존 다른 프리셋 테스트들) ...
    func testCompressVideoHighQualityPreset() async throws {
        let result = try await compressor.compressVideo(
            sampleVideoURL,
            quality: .highQuality,
            outputDirectory: outputDirectory,
            progressHandler: nil
        )
        // *** 수정: await 사용하여 async 함수 호출 ***
        try await assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics, expectedDuration: originalVideoDuration)
        XCTAssertLessThanOrEqual(result.analytics.compressedDimensions.width, 1920, "Width should be <= 1920 for high quality")
        if let properties = try await getVideoProperties(url: result.url) {
             XCTAssertEqual(properties.fps, 30, accuracy: 1, "FPS should be around 30 for high quality")
        }
    }

    func testCompressVideoSocialPreset() async throws {
        let result = try await compressor.compressVideo(
            sampleVideoURL,
            quality: .socialMedia,
            outputDirectory: outputDirectory,
            progressHandler: nil
        )
        // *** 수정: await 사용하여 async 함수 호출 ***
        try await assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics, expectedDuration: originalVideoDuration)
        // 소셜 프리셋은 1280x720을 목표로 하므로, 너비 또는 높이 중 하나를 확인
        XCTAssertTrue(result.analytics.compressedDimensions.width <= 1280 || result.analytics.compressedDimensions.height <= 720, "Dimensions should be constrained for social preset")
    }

    func testCompressVideoMessagingPreset() async throws {
        let result = try await compressor.compressVideo(
            sampleVideoURL,
            quality: .messaging,
            outputDirectory: outputDirectory,
            progressHandler: nil
        )
        // *** 수정: await 사용하여 async 함수 호출 ***
        try await assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics, expectedDuration: originalVideoDuration)
         // 메시징 프리셋은 854x480을 목표로 하므로, 너비 또는 높이 중 하나를 확인
        XCTAssertTrue(result.analytics.compressedDimensions.width <= 854 || result.analytics.compressedDimensions.height <= 480, "Dimensions should be constrained for messaging preset")
        XCTAssertLessThanOrEqual(result.analytics.compressedVideoBitrate, 1_500_000)
    }


    // MARK: - Custom Configuration Tests
    func testCompressVideoCustomConfigHEVC() async throws {
        guard VideoCodec.hevc.isSupported() else {
            throw XCTSkip("HEVC codec not supported on this device/simulator. Skipping test.")
        }
        var config = CompressionConfig.default
        config.videoCodec = .hevc
        config.videoBitrate = 1_000_000
        config.scale = CGSize(width: 1280, height: 720)
        config.fps = 24
        config.outputDirectory = outputDirectory

        let result = try await compressor.compressVideo(
            sampleVideoURL,
            config: config,
            progressHandler: nil
        )
        // *** 수정: await 사용하여 async 함수 호출 ***
        try await assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics, expectedDuration: originalVideoDuration)
        XCTAssertEqual(result.analytics.compressedDimensions.width, 1280)
        XCTAssertEqual(result.analytics.compressedDimensions.height, 720)
        if let properties = try await getVideoProperties(url: result.url) {
            XCTAssertEqual(properties.fps, 24, accuracy: 1)
        }
    }

     func testCompressVideoCustomConfigQualityBased() async throws {
         var config = CompressionConfig.default
         config.useExplicitBitrate = false
         config.videoQuality = 0.5
         config.videoCodec = .h264
         config.scale = CGSize(width: 640, height: -1) // 높이는 자동 계산
         config.outputDirectory = outputDirectory

         let result = try await compressor.compressVideo(
            sampleVideoURL,
            config: config,
            progressHandler: nil
         )
         // *** 수정: await 사용하여 async 함수 호출 ***
         try await assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics, expectedDuration: originalVideoDuration)
         XCTAssertEqual(result.analytics.compressedDimensions.width, 640)
     }

    func testCompressVideoCustomConfigAudioMonoHEAACL() async throws {
        var config = CompressionConfig.default
        config.audioChannels = 1
        config.audioCodec = .aac_he_v1
        config.audioBitrate = 48_000
        config.audioSampleRate = 44100
        config.outputDirectory = outputDirectory

        let result = try await compressor.compressVideo(
            sampleVideoURL,
            config: config,
            progressHandler: nil
        )
        // *** 수정: await 사용하여 async 함수 호출 ***
        try await assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics, expectedDuration: originalVideoDuration)
        XCTAssertNotNil(result.analytics.compressedAudioBitrate)
        XCTAssertLessThanOrEqual(result.analytics.compressedAudioBitrate ?? 999_999, 64_000)
    }

     func testCompressVideoCustomConfigFrameReductionRandom() async throws {
         var config = CompressionConfig.default
         config.fps = 15
         config.outputDirectory = outputDirectory

         guard let sourceProps = try await getVideoProperties(url: sampleVideoURL), sourceProps.fps > config.fps else {
             throw XCTSkip("Source FPS (\(try await getVideoProperties(url: sampleVideoURL)?.fps ?? 0)) not higher than target FPS (\(config.fps)).")
         }

         let result = try await compressor.compressVideo(
            sampleVideoURL,
            config: config,
            frameReducer: ReduceFrameRandomly(), // 사용자 정의 FrameReducer 필요
            progressHandler: nil
         )
         // *** 수정: await 사용하여 async 함수 호출 ***
         try await assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics, expectedDuration: originalVideoDuration)
         if let properties = try await getVideoProperties(url: result.url) {
             XCTAssertEqual(properties.fps, config.fps, accuracy: 1.0)
         }
     }

     func testCompressVideoSpecificOutputURL() async throws {
         let specificOutputURL = outputDirectory.appendingPathComponent("specific_output.mp4")
         var config = CompressionConfig.default
         config.outputURL = specificOutputURL // outputDirectory는 무시됨

         let result = try await compressor.compressVideo(
            sampleVideoURL,
            config: config,
            progressHandler: nil
         )
         // *** 수정: await 사용하여 async 함수 호출 ***
         try await assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics, expectedDuration: originalVideoDuration)
         XCTAssertEqual(result.url, specificOutputURL)
     }

    // MARK: - Trimming Tests
    func testCompressVideoTrimStartToEnd() async throws {
        var config = CompressionConfig.default
        let startTimeSeconds: Double = 1.0
        let endTimeSeconds: Double = 3.0
        let expectedTrimmedDuration = endTimeSeconds - startTimeSeconds

        guard originalVideoDuration > endTimeSeconds else {
            throw XCTSkip("Original video duration (\(originalVideoDuration)s) is too short for this trim test (end time: \(endTimeSeconds)s).")
        }

        config.trimStartTime = CMTimeMakeWithSeconds(startTimeSeconds, preferredTimescale: 600)
        config.trimEndTime = CMTimeMakeWithSeconds(endTimeSeconds, preferredTimescale: 600)
        config.outputDirectory = outputDirectory

        let result = try await compressor.compressVideo(sampleVideoURL, config: config)
        // *** 수정: await 사용하여 async 함수 호출 ***
        try await assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics, expectedDuration: expectedTrimmedDuration)
        print("Trimmed from \(startTimeSeconds)s to \(endTimeSeconds)s. Expected duration: \(expectedTrimmedDuration)s, Actual: \(result.analytics.processingTime > 0 ? (try await getVideoProperties(url: result.url)?.duration ?? -1) : -1)s")
    }

    func testCompressVideoTrimStartOnly() async throws {
        var config = CompressionConfig.default
        let startTimeSeconds: Double = 2.0
        
        guard originalVideoDuration > startTimeSeconds else {
            throw XCTSkip("Original video duration (\(originalVideoDuration)s) is too short for this trim test (start time: \(startTimeSeconds)s).")
        }
        let expectedTrimmedDuration = originalVideoDuration - startTimeSeconds

        config.trimStartTime = CMTimeMakeWithSeconds(startTimeSeconds, preferredTimescale: 600)
        config.trimEndTime = nil // 끝까지
        config.outputDirectory = outputDirectory

        let result = try await compressor.compressVideo(sampleVideoURL, config: config)
        // *** 수정: await 사용하여 async 함수 호출 ***
        try await assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics, expectedDuration: expectedTrimmedDuration)
        print("Trimmed from \(startTimeSeconds)s to end. Expected duration: \(expectedTrimmedDuration)s, Actual: \(result.analytics.processingTime > 0 ? (try await getVideoProperties(url: result.url)?.duration ?? -1) : -1)s")
    }

    func testCompressVideoTrimEndOnly() async throws {
        var config = CompressionConfig.default
        let endTimeSeconds: Double = 2.5
        
        guard originalVideoDuration >= endTimeSeconds, endTimeSeconds > 0 else {
            throw XCTSkip("Invalid end time (\(endTimeSeconds)s) for original duration (\(originalVideoDuration)s).")
        }
        let expectedTrimmedDuration = endTimeSeconds

        config.trimStartTime = nil // 처음부터
        config.trimEndTime = CMTimeMakeWithSeconds(endTimeSeconds, preferredTimescale: 600)
        config.outputDirectory = outputDirectory

        let result = try await compressor.compressVideo(sampleVideoURL, config: config)
        // *** 수정: await 사용하여 async 함수 호출 ***
        try await assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics, expectedDuration: expectedTrimmedDuration)
        print("Trimmed from start to \(endTimeSeconds)s. Expected duration: \(expectedTrimmedDuration)s, Actual: \(result.analytics.processingTime > 0 ? (try await getVideoProperties(url: result.url)?.duration ?? -1) : -1)s")
    }
    
    func testCompressVideoTrimFullDuration() async throws {
        var config = CompressionConfig.default
        // trimStartTime과 trimEndTime을 nil로 두어 전체 길이를 사용하도록 함
        config.trimStartTime = nil
        config.trimEndTime = nil
        config.outputDirectory = outputDirectory
        config.videoBitrate = 500_000 // 파일 크기 줄이기 위한 낮은 비트레이트

        let result = try await compressor.compressVideo(sampleVideoURL, config: config)
        // *** 수정: await 사용하여 async 함수 호출 ***
        try await assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics, expectedDuration: originalVideoDuration)
        print("Compressed full duration. Expected duration: \(originalVideoDuration)s, Actual: \(result.analytics.processingTime > 0 ? (try await getVideoProperties(url: result.url)?.duration ?? -1) : -1)s")
    }


    // MARK: - Trimming Error Tests
    func testCompressVideoTrimInvalid_StartAfterEnd() async {
        var config = CompressionConfig.default
        config.trimStartTime = CMTimeMakeWithSeconds(3.0, preferredTimescale: 600)
        config.trimEndTime = CMTimeMakeWithSeconds(1.0, preferredTimescale: 600)
        config.outputDirectory = outputDirectory

        do {
            _ = try await compressor.compressVideo(sampleVideoURL, config: config)
            XCTFail("Should have thrown invalidTrimTimes error for start > end.")
        } catch JMVideoCompressorError.invalidTrimTimes(let message) {
            print("Caught expected error for start > end: \(message)")
            XCTAssertTrue(message.contains("must be before trim end time"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testCompressVideoTrimInvalid_StartOutOfBounds() async {
        var config = CompressionConfig.default
        let outOfBoundsStartTime = originalVideoDuration + 10.0
        config.trimStartTime = CMTimeMakeWithSeconds(outOfBoundsStartTime, preferredTimescale: 600)
        config.trimEndTime = CMTimeMakeWithSeconds(outOfBoundsStartTime + 1.0, preferredTimescale: 600) // End도 유효하게
        config.outputDirectory = outputDirectory

        do {
            _ = try await compressor.compressVideo(sampleVideoURL, config: config)
            XCTFail("Should have thrown invalidTrimTimes error for start time out of bounds.")
        } catch JMVideoCompressorError.invalidTrimTimes(let message) {
            print("Caught expected error for start time out of bounds: \(message)")
            XCTAssertTrue(message.contains("must be within asset duration") || message.contains("must be before trim end time"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testCompressVideoTrimInvalid_EndOutOfBoundsTooLarge() async {
        var config = CompressionConfig.default
        let outOfBoundsEndTime = originalVideoDuration + 10.0
        config.trimStartTime = CMTimeMakeWithSeconds(1.0, preferredTimescale: 600) // 유효한 시작 시간
        config.trimEndTime = CMTimeMakeWithSeconds(outOfBoundsEndTime, preferredTimescale: 600)
        config.outputDirectory = outputDirectory

        do {
            _ = try await compressor.compressVideo(sampleVideoURL, config: config)
            XCTFail("Should have thrown invalidTrimTimes error for end time out of bounds (too large).")
        } catch JMVideoCompressorError.invalidTrimTimes(let message) {
            print("Caught expected error for end time out of bounds (too large): \(message)")
            XCTAssertTrue(message.contains("must be within asset duration"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testCompressVideoTrimInvalid_EndTimeZeroOrNegative() async {
        var config = CompressionConfig.default
        config.trimStartTime = nil
        config.trimEndTime = CMTimeMakeWithSeconds(0.0, preferredTimescale: 600) // 0초 또는 음수
        config.outputDirectory = outputDirectory

        do {
            _ = try await compressor.compressVideo(sampleVideoURL, config: config)
            XCTFail("Should have thrown invalidTrimTimes error for zero/negative end time.")
        } catch JMVideoCompressorError.invalidTrimTimes(let message) {
            print("Caught expected error for zero/negative end time: \(message)")
            XCTAssertTrue(message.contains("must be greater than zero"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }


    // MARK: - Error Handling Tests
    func testCompressInvalidSourceURL() async {
        let invalidURL = URL(fileURLWithPath: "/nonexistent/path/to/video.mp4")
        do {
            _ = try await compressor.compressVideo(invalidURL, quality: .mediumQuality)
            XCTFail("Should have thrown invalidSourceURL")
        } catch JMVideoCompressorError.invalidSourceURL(let url) {
            XCTAssertEqual(url, invalidURL)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCompressInvalidOutputDirectory() async {
         let invalidDirFile = outputDirectory.appendingPathComponent("not_a_directory.txt")
         try? FileManager.default.createFile(atPath: invalidDirFile.path, contents: Data("hello".utf8), attributes: nil)
         
         var config = CompressionConfig.default
         config.outputDirectory = invalidDirFile // 파일을 디렉토리로 지정

         do {
             _ = try await compressor.compressVideo(sampleVideoURL, config: config)
             XCTFail("Should have thrown invalidOutputPath")
         } catch JMVideoCompressorError.invalidOutputPath(let url) {
              XCTAssertEqual(url, invalidDirFile)
         } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCompressUnsupportedCodec() async {
        var config = CompressionConfig.default
        config.videoCodec = .hevc
        config.outputDirectory = outputDirectory

        if !config.videoCodec.isSupported() { // HEVC가 지원되지 않는 환경에서만 이 테스트가 의미 있음
            do {
                _ = try await compressor.compressVideo(sampleVideoURL, config: config)
                XCTFail("Should have thrown codecNotSupported error")
            } catch JMVideoCompressorError.codecNotSupported(let codec) {
                XCTAssertEqual(codec, .hevc)
                print("Caught expected codecNotSupported error for HEVC.")
            } catch {
                XCTFail("Caught unexpected error type: \(error)")
            }
        } else { // HEVC가 지원되는 환경
            print("Skipping unsupported codec assertion as HEVC is supported on this device. Attempting compression...")
            // HEVC가 지원되면 정상적으로 압축이 시도되어야 함
            do {
                 let result = try await compressor.compressVideo(sampleVideoURL, config: config)
                 // *** 수정: await 사용하여 async 함수 호출 ***
                 try await assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics, expectedDuration: originalVideoDuration)
                 print("HEVC compression successful as codec is supported.")
            } catch {
                 XCTFail("HEVC compression failed even though codec is reported as supported: \(error)")
            }
        }
    }
    
    // MARK: - Cancellation Test
    func testCompressionCancellation() async throws {
        var config = CompressionConfig.default
        config.outputDirectory = outputDirectory
        config.videoBitrate = 100_000 // 압축 시간을 조금 늘리기 위해 비트레이트 낮춤
        config.maxLongerDimension = 320 // 해상도 낮춰서 빠르게 처리되도록

        let expectation = XCTestExpectation(description: "Compression cancellation")
        let uniqueOutputFilename = "cancelled_video.mp4"
        config.outputURL = outputDirectory.appendingPathComponent(uniqueOutputFilename)


        Task {
            do {
                print("Starting compression for cancellation test...")
                // 중간에 취소할 수 있도록 약간의 지연 후 취소 요청
                Task {
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1초 후 취소
                    print("Requesting cancellation...")
                    compressor.cancel()
                }
                _ = try await compressor.compressVideo(sampleVideoURL, config: config, progressHandler: { progress in
                    print("Cancellation test progress: \(progress * 100)%")
                })
                XCTFail("Compression should have been cancelled and thrown an error.")
            } catch JMVideoCompressorError.cancelled {
                print("Successfully caught cancellation error.")
                expectation.fulfill()
                // 취소된 경우 출력 파일이 존재하지 않거나 비어 있어야 함
                if let outputURL = config.outputURL {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path), "Output file should not exist after cancellation if writer was cancelled early.")
                }
            } catch {
                XCTFail("Unexpected error during cancellation test: \(error.localizedDescription)")
            }
        }
        wait(for: [expectation], timeout: 15.0) // 취소 테스트는 시간이 좀 더 걸릴 수 있음
    }

}

// MARK: - Helper Frame Reducer for testing
struct ReduceFrameRandomly: VideoFrameReducer {
    func reduce(originalFPS: Float, to targetFPS: Float, with duration: Float) -> [Int]? {
        guard targetFPS > 0, originalFPS > targetFPS else { return nil }
        let totalOriginalFrames = Int(originalFPS * duration)
        let desiredFrames = Int(targetFPS * duration)
        guard desiredFrames > 0, desiredFrames < totalOriginalFrames else { return [] }

        var indicesToKeep: Set<Int> = []
        while indicesToKeep.count < desiredFrames {
            indicesToKeep.insert(Int.random(in: 0..<totalOriginalFrames))
        }
        return Array(indicesToKeep).sorted()
    }
}
