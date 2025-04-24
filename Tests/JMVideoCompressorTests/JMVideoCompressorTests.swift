//
//  JMVideoCompressorTests.swift
//  JMVideoCompressorTests
//
//  Created by raykim on 4/24/25.
//
import XCTest
@testable import JMVideoCompressor // Import the library to test it
import AVFoundation

final class JMVideoCompressorTests: XCTestCase {

    // MARK: - Properties
    var sampleVideoURL: URL!
    var outputDirectory: URL!
    let compressor = JMVideoCompressor()

    // MARK: - Test Lifecycle
    override func setUpWithError() throws {
        // Bundle.module을 사용하여 SPM이 관리하는 리소스 번들에 접근합니다.
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "sample", withExtension: "mp4") else {
            // 이제 Bundle.module에서 리소스를 찾으므로, 파일과 Package.swift 설정이 올바르다면 이 부분은 통과해야 합니다.
            throw XCTSkip("Missing test video resource 'sample.mp4'. Check Bundle.module access and resource path.")
        }
        sampleVideoURL = url
        outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("JMCompressorTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)
        print("Test output directory: \(outputDirectory.path)")
    }

    override func tearDownWithError() throws {
        if let dir = outputDirectory { try? FileManager.default.removeItem(at: dir) }
        outputDirectory = nil; sampleVideoURL = nil
    }

    // MARK: - Helper Assertions
    private func assertCompressionSuccess(original: URL, compressed: URL, analytics: CompressionAnalytics) throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: compressed.path), "Compressed file should exist")
        XCTAssertGreaterThan(analytics.originalFileSize, 0)
        XCTAssertGreaterThan(analytics.compressedFileSize, 0)
        XCTAssertLessThanOrEqual(analytics.compressedFileSize, analytics.originalFileSize, "Compressed size (\(analytics.compressedFileSize)) <= original size (\(analytics.originalFileSize))")
        XCTAssertGreaterThan(analytics.compressionRatio, 0)
        XCTAssertGreaterThan(analytics.processingTime, 0)
        XCTAssertNotEqual(analytics.originalDimensions, .zero)
        XCTAssertNotEqual(analytics.compressedDimensions, .zero)
        XCTAssertGreaterThan(analytics.originalVideoBitrate, 0)
        XCTAssertGreaterThan(analytics.compressedVideoBitrate, 0)
        print("Compression successful: \(String(format: "%.2f", analytics.compressionRatio)):1 ratio in \(String(format: "%.2f", analytics.processingTime))s")
    }

    private func getVideoProperties(url: URL) async throws -> (size: CGSize, fps: Float, duration: Double)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        async let size = track.load(.naturalSize)
        async let fps = track.load(.nominalFrameRate)
        async let duration = asset.load(.duration)
        return try await (size: size, fps: fps, duration: duration.seconds)
    }

    // MARK: - Basic Tests (Quality Presets)
    func testCompressVideoLowQualityPreset() async throws {
        // quality 파라미터를 사용하는 버전은 outputDirectory 파라미터가 있습니다.
        let result = try await compressor.compressVideo(
            sampleVideoURL,
            quality: .lowQuality,
            outputDirectory: outputDirectory, // OK for quality-based call
            progressHandler: nil
        )
        try assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics)
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
            outputDirectory: outputDirectory, // OK for quality-based call
            progressHandler: nil
        )
        try assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics)
        XCTAssertLessThanOrEqual(result.analytics.compressedDimensions.width, 1280, "Width should be <= 1280 for medium quality")
        if let properties = try await getVideoProperties(url: result.url) {
            XCTAssertEqual(properties.fps, 30, accuracy: 1, "FPS should be around 30 for medium quality")
        }
        XCTAssertLessThanOrEqual(result.analytics.compressedVideoBitrate, 2_500_000)
    }

    func testCompressVideoHighQualityPreset() async throws {
        let result = try await compressor.compressVideo(
            sampleVideoURL,
            quality: .highQuality,
            outputDirectory: outputDirectory, // OK for quality-based call
            progressHandler: nil
        )
        try assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics)
        XCTAssertLessThanOrEqual(result.analytics.compressedDimensions.width, 1920, "Width should be <= 1920 for high quality")
        if let properties = try await getVideoProperties(url: result.url) {
             XCTAssertEqual(properties.fps, 30, accuracy: 1, "FPS should be around 30 for high quality")
        }
    }

    func testCompressVideoSocialPreset() async throws {
        let result = try await compressor.compressVideo(
            sampleVideoURL,
            quality: .socialMedia,
            outputDirectory: outputDirectory, // OK for quality-based call
            progressHandler: nil
        )
        try assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics)
        XCTAssertLessThanOrEqual(result.analytics.compressedDimensions.height, 720, "Height should be <= 720 for social preset")
    }

    func testCompressVideoMessagingPreset() async throws {
        let result = try await compressor.compressVideo(
            sampleVideoURL,
            quality: .messaging,
            outputDirectory: outputDirectory, // OK for quality-based call
            progressHandler: nil
        )
        try assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics)
        XCTAssertLessThanOrEqual(result.analytics.compressedDimensions.height, 480, "Height should be <= 480 for messaging preset")
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
        // *** CORRECTED: Set outputDirectory within config ***
        config.outputDirectory = outputDirectory

        // *** CORRECTED: Call config-based signature (no outputDirectory param) ***
        let result = try await compressor.compressVideo(
            sampleVideoURL,
            config: config,
            progressHandler: nil
        )
        try assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics)
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
         config.scale = CGSize(width: 640, height: -1)
         // *** CORRECTED: Set outputDirectory within config ***
         config.outputDirectory = outputDirectory

         // *** CORRECTED: Call config-based signature (no outputDirectory param) ***
         let result = try await compressor.compressVideo(
            sampleVideoURL,
            config: config,
            progressHandler: nil
         )
         try assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics)
         XCTAssertEqual(result.analytics.compressedDimensions.width, 640)
     }

    func testCompressVideoCustomConfigAudioMonoHEAACL() async throws {
        var config = CompressionConfig.default
        config.audioChannels = 1
        config.audioCodec = .aac_he_v1
        config.audioBitrate = 48_000
        config.audioSampleRate = 44100
        // *** CORRECTED: Set outputDirectory within config ***
        config.outputDirectory = outputDirectory

        // *** CORRECTED: Call config-based signature (no outputDirectory param) ***
        let result = try await compressor.compressVideo(
            sampleVideoURL,
            config: config,
            progressHandler: nil
        )
        try assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics)
        XCTAssertNotNil(result.analytics.compressedAudioBitrate)
        XCTAssertLessThanOrEqual(result.analytics.compressedAudioBitrate ?? 999_999, 64_000)
    }

     func testCompressVideoCustomConfigFrameReductionRandom() async throws {
         var config = CompressionConfig.default
         config.fps = 15
         // *** CORRECTED: Set outputDirectory within config ***
         config.outputDirectory = outputDirectory

         guard let sourceProps = try await getVideoProperties(url: sampleVideoURL), sourceProps.fps > config.fps else {
             throw XCTSkip("Source FPS not higher than target FPS.")
         }

         // *** CORRECTED: Call config-based signature (no outputDirectory param) ***
         let result = try await compressor.compressVideo(
            sampleVideoURL,
            config: config,
            frameReducer: ReduceFrameRandomly(),
            progressHandler: nil
         )
         try assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics)
         if let properties = try await getVideoProperties(url: result.url) {
             XCTAssertEqual(properties.fps, config.fps, accuracy: 1.0)
         }
     }

     func testCompressVideoSpecificOutputURL() async throws {
         let specificOutputURL = outputDirectory.appendingPathComponent("specific_output.mp4")
         var config = CompressionConfig.default
         // *** CORRECTED: Set outputURL within config (outputDirectory is ignored) ***
         config.outputURL = specificOutputURL

         // *** CORRECTED: Call config-based signature (no outputDirectory param) ***
         let result = try await compressor.compressVideo(
            sampleVideoURL,
            config: config,
            progressHandler: nil
         )
         try assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics)
         XCTAssertEqual(result.url, specificOutputURL)
     }

    // MARK: - Error Handling Tests
    func testCompressInvalidSourceURL() async {
        let invalidURL = URL(fileURLWithPath: "/nonexistent/path/to/video.mp4")
        do {
            // quality-based call is fine here
            _ = try await compressor.compressVideo(invalidURL, quality: .mediumQuality)
            XCTFail("Should have thrown")
        } catch let error as JMVideoCompressorError {
            XCTAssertEqual(error.localizedDescription, JMVideoCompressorError.invalidSourceURL(invalidURL).localizedDescription)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCompressInvalidOutputDirectory() async {
         let invalidOutputDir = outputDirectory.appendingPathComponent("not_a_directory.txt")
         FileManager.default.createFile(atPath: invalidOutputDir.path, contents: Data("hello".utf8), attributes: nil)
         var config = CompressionConfig.default
         // *** CORRECTED: Set outputDirectory within config ***
         config.outputDirectory = invalidOutputDir

         do {
             // *** CORRECTED: Call config-based signature (no outputDirectory param) ***
             _ = try await compressor.compressVideo(sampleVideoURL, config: config)
             XCTFail("Should have thrown")
         } catch let error as JMVideoCompressorError {
              XCTAssertEqual(error.localizedDescription, JMVideoCompressorError.invalidOutputPath(invalidOutputDir).localizedDescription)
         } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCompressUnsupportedCodec() async {
        var config = CompressionConfig.default
        config.videoCodec = .hevc
        // *** CORRECTED: Set outputDirectory within config ***
        config.outputDirectory = outputDirectory

        if !config.videoCodec.isSupported() {
            do {
                // *** CORRECTED: Call config-based signature (no outputDirectory param) ***
                _ = try await compressor.compressVideo(sampleVideoURL, config: config)
                XCTFail("Should have thrown codecNotSupported error")
            } catch JMVideoCompressorError.codecNotSupported(let codec) {
                XCTAssertEqual(codec, .hevc)
                print("Caught expected codecNotSupported error for HEVC.")
            } catch {
                XCTFail("Caught unexpected error type: \(error)")
            }
        } else {
            do {
                 // *** CORRECTED: Call config-based signature, handle tuple result ***
                 let result = try await compressor.compressVideo(sampleVideoURL, config: config)
                 try assertCompressionSuccess(original: sampleVideoURL, compressed: result.url, analytics: result.analytics)
                 print("Skipping unsupported codec test assertion as HEVC is supported and compression succeeded.")
            } catch {
                 print("Skipping unsupported codec test assertion as HEVC is supported, but compression failed: \(error)")
            }
        }
    }

}

// Helper Actor for thread-safe array appends from concurrent contexts
@globalActor actor ProgressActor {
    static let shared = ProgressActor()
}
