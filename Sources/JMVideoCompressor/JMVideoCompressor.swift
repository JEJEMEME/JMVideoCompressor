//
//  JMVideoCompressor.swift
//  JMVideoCompressor
//
//  Created by raykim on 4/24/25.
//
import Foundation
import AVFoundation
import CoreMedia
import CoreServices
import VideoToolbox

// MARK: - Top-Level Public Enum

/// Quality presets for simple configuration. Uses H.264 codec by default.
/// For HEVC or more control, use `CompressionConfig`.
public enum VideoQuality {
    case lowQuality
    case mediumQuality
    case highQuality
    /// Preset optimized for social media platforms (e.g., 720p, good balance).
    case socialMedia
    /// Preset optimized for messaging apps (smaller file size, ~480p).
    case messaging

    /// Generates a default `CompressionConfig` based on the quality preset.
    public var defaultConfig: CompressionConfig {
        var config = CompressionConfig.default
        switch self {
        case .lowQuality:
            config.maxLongerDimension = 640
            config.videoBitrate = 500_000
            config.fps = 20
            config.audioBitrate = 64_000
            config.audioChannels = 1
            config.preprocessing.noiseReduction = .low
        case .mediumQuality:
            config.maxLongerDimension = 1280
            config.videoBitrate = 2_000_000
            config.fps = 30
            config.audioBitrate = 128_000
        case .highQuality:
            config.maxLongerDimension = 1920
            config.videoBitrate = 5_000_000
            config.fps = 30
            config.audioBitrate = 192_000
            if VideoCodec.hevc.isSupported() { config.videoCodec = .hevc }
        case .socialMedia:
             config.maxLongerDimension = 1280
             config.videoBitrate = 3_500_000
             config.fps = 30
             config.audioBitrate = 128_000
        case .messaging:
             config.maxLongerDimension = 854
             config.videoBitrate = 1_000_000
             config.fps = 24
             config.audioBitrate = 64_000
             config.audioChannels = 1
             config.preprocessing.noiseReduction = .medium
        }
        // 기본 프리셋은 시각적 인코딩을 강제하지 않음 (기존 동작 유지)
        // config.forceVisualEncodingDimensions = false // 기본값이 false이므로 명시적 설정 불필요
        return config
    }
}

// MARK: - Compression Analytics Struct

/// Contains statistics about the compression process.
public struct CompressionAnalytics {
    /// Original file size in bytes.
    public let originalFileSize: Int64
    /// Compressed file size in bytes.
    public let compressedFileSize: Int64
    /// Compression ratio (originalSize / compressedSize). Higher is better.
    public let compressionRatio: Float
    /// Total time taken for the compression process in seconds.
    public let processingTime: TimeInterval
    /// **Visual dimensions** (width, height) of the original video (considering rotation).
    public let originalDimensions: CGSize
    /// **Encoded dimensions** (width, height) of the compressed video.
    public let compressedDimensions: CGSize
    /// Estimated bitrate of the original video track in bits per second.
    public let originalVideoBitrate: Float
    /// Target or estimated bitrate of the compressed video track in bits per second.
    public let compressedVideoBitrate: Float
    /// Estimated bitrate of the original audio track (if present) in bits per second.
    public let originalAudioBitrate: Float?
    /// Target or estimated bitrate of the compressed audio track (if present) in bits per second.
    public let compressedAudioBitrate: Float?
}


// MARK: - Main Compressor Class

/// A class for compressing video files using AVFoundation.
public class JMVideoCompressor {

    // MARK: - Private Properties
    private let isolationQueue = DispatchQueue(label: "com.jmvideocompressor.isolation")
    private var assetWriter: AVAssetWriter?
    private var assetReader: AVAssetReader?
    private var cancelled: Bool = false
    private var startTime: Date?
    private weak var videoInput: AVAssetWriterInput?
    private weak var audioInput: AVAssetWriterInput?
    private var totalSourceTime: CMTime = .zero

    // MARK: - Initialization
    public init() {}

    // MARK: - Public API

    /// Compresses the video at the given URL using a quality preset.
    public func compressVideo(
        _ url: URL,
        quality: VideoQuality = .mediumQuality,
        frameReducer: VideoFrameReducer = ReduceFrameEvenlySpaced(),
        outputDirectory: URL? = nil, // Deprecated for config-based approach
        progressHandler: ((Float) -> Void)? = nil
    ) async throws -> (url: URL, analytics: CompressionAnalytics) {
        var config = quality.defaultConfig
        if let explicitOutputDir = outputDirectory {
            config.outputDirectory = explicitOutputDir
            config.outputURL = nil
        }
        // 사용자가 forceVisualEncodingDimensions를 프리셋과 함께 사용하고 싶다면,
        // 이 함수 호출 후 config 값을 직접 수정해야 함.
        // 예: var config = VideoQuality.highQuality.defaultConfig
        //     config.forceVisualEncodingDimensions = true
        //     try await compressor.compressVideo(url, config: config, ...)
        return try await compressVideo(url, config: config, frameReducer: frameReducer, progressHandler: progressHandler)
    }

    /// Compresses the video at the given URL using custom configuration.
    public func compressVideo(
        _ url: URL,
        config: CompressionConfig,
        frameReducer: VideoFrameReducer = ReduceFrameEvenlySpaced(),
        progressHandler: ((Float) -> Void)? = nil
    ) async throws -> (url: URL, analytics: CompressionAnalytics) {

        // Reset state
        isolationQueue.sync {
             self.cancelled = false
             self.startTime = Date()
             self.assetReader = nil
             self.assetWriter = nil
             self.videoInput = nil
             self.audioInput = nil
             // totalSourceTime is reset below
        }

        // Input Validation & Codec Check
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { throw JMVideoCompressorError.invalidSourceURL(url) }
        guard config.videoCodec.isSupported() else { throw JMVideoCompressorError.codecNotSupported(config.videoCodec) }

        let sourceAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        self.totalSourceTime = try await sourceAsset.load(.duration)

        // Load Tracks
        guard let sourceVideoTrack = try? await sourceAsset.loadTracks(withMediaType: .video).first else { throw JMVideoCompressorError.missingVideoTrack }
        let sourceAudioTrack = try? await sourceAsset.loadTracks(withMediaType: .audio).first

        // Calculate Settings
        let sourceVideoSettings = try await loadSourceVideoSettings(track: sourceVideoTrack)
        let sourceAudioSettings = try await loadSourceAudioSettings(track: sourceAudioTrack)

        let contentType = config.contentAwareOptimization ? detectContentType(videoTrack: sourceVideoTrack) : .standard
        var effectiveConfig = config
        applyContentAwareOptimizations(to: &effectiveConfig, contentType: contentType)

        let targetFPS = min(effectiveConfig.fps, sourceVideoSettings.fps)
        let needsFrameReduction = targetFPS < sourceVideoSettings.fps

        // --- 여기가 중요: createTargetVideoSettings 호출 시 config 전달 ---
        // targetVideoSettings 딕셔너리와 함께 finalTransform 값도 받아옴
        let (targetVideoSettings, finalTransform) = try createTargetVideoSettings(config: effectiveConfig, source: sourceVideoSettings)
        let targetAudioSettings = try createTargetAudioSettings(config: effectiveConfig, source: sourceAudioSettings)

        // Determine Output URL
        let outputURL = try determineOutputURL(config: effectiveConfig, sourceURL: url)

        // Setup Reader & Writer
        let localReader: AVAssetReader
        let localWriter: AVAssetWriter
        defer {
            // Ensure cleanup happens even if initialization fails partially
            isolationQueue.sync {
                self.assetReader?.cancelReading()
                self.assetWriter?.cancelWriting()
                self.assetReader = nil
                self.assetWriter = nil
                self.videoInput = nil
                self.audioInput = nil
            }
             print("JMVideoCompressor: Deferred cleanup executed.")
        }
        do { localReader = try AVAssetReader(asset: sourceAsset) } catch { throw JMVideoCompressorError.readerInitializationFailed(error) }
        do { localWriter = try AVAssetWriter(url: outputURL, fileType: effectiveConfig.fileType) } catch { throw JMVideoCompressorError.writerInitializationFailed(error) }
        localWriter.shouldOptimizeForNetworkUse = true
        isolationQueue.sync { self.assetReader = localReader; self.assetWriter = localWriter }

        // Configure Reader Outputs
        let videoOutputSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
        let videoOutput = AVAssetReaderTrackOutput(track: sourceVideoTrack, outputSettings: videoOutputSettings)
        videoOutput.alwaysCopiesSampleData = false // 성능 향상을 위해 false 권장
        guard localReader.canAdd(videoOutput) else { throw JMVideoCompressorError.compressionFailed(NSError(domain: "JMVideoCompressor", code: -2, userInfo: [NSLocalizedDescriptionKey: "Cannot add video reader output."])) }
        localReader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let sourceAudio = sourceAudioTrack, targetAudioSettings != nil {
             let audioDecompressionSettings: [String: Any] = [
                 AVFormatIDKey: kAudioFormatLinearPCM,
                 AVNumberOfChannelsKey: effectiveConfig.audioChannels ?? sourceAudioSettings?.channels ?? 2
             ]
             let output = AVAssetReaderTrackOutput(track: sourceAudio, outputSettings: audioDecompressionSettings)
             output.alwaysCopiesSampleData = false
             if localReader.canAdd(output) { localReader.add(output); audioOutput = output }
             else { print("Warning: Could not add audio reader output.") }
        }

        // --- Configure Writer Inputs ---
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: targetVideoSettings)
        videoInput.expectsMediaDataInRealTime = false
        // --- 여기가 중요: 계산된 finalTransform 적용 ---
        videoInput.transform = finalTransform // 원본 transform 대신 계산된 transform 사용
        guard localWriter.canAdd(videoInput) else { throw JMVideoCompressorError.compressionFailed(NSError(domain: "JMVideoCompressor", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video writer input."])) }
        localWriter.add(videoInput)
        isolationQueue.sync { self.videoInput = videoInput }

        var audioInput: AVAssetWriterInput?
        if let settings = targetAudioSettings, audioOutput != nil {
             let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
             input.expectsMediaDataInRealTime = false
             if localWriter.canAdd(input) {
                 localWriter.add(input)
                 audioInput = input
                 isolationQueue.sync { self.audioInput = input }
             } else {
                 print("Warning: Could not add audio writer input.")
                 audioOutput = nil
             }
        }

        // Start Compression
        logCompressionStart(sourceURL: url, outputURL: outputURL, config: effectiveConfig)
        guard localReader.startReading() else { throw JMVideoCompressorError.readerInitializationFailed(localReader.error) }
        guard localWriter.startWriting() else { throw JMVideoCompressorError.writerInitializationFailed(localWriter.error) }
        localWriter.startSession(atSourceTime: .zero)

        // Process Samples Asynchronously
        let frameIndexesToKeep = needsFrameReduction ? frameReducer.reduce(originalFPS: sourceVideoSettings.fps, to: targetFPS, with: Float(totalSourceTime.seconds)) : nil
        try await withThrowingTaskGroup(of: Void.self) { group in
             group.addTask {
                 try await self.processTrack(
                     assetWriterInput: videoInput,
                     readerOutput: videoOutput,
                     frameIndexesToKeep: frameIndexesToKeep,
                     progressHandler: progressHandler
                 )
             }
             if let audioIn = audioInput, let audioOut = audioOutput {
                 group.addTask {
                     try await self.processTrack(
                         assetWriterInput: audioIn,
                         readerOutput: audioOut,
                         frameIndexesToKeep: nil,
                         progressHandler: nil
                     )
                 }
             }
             try await group.waitForAll()
        }

        // Finish Writing
        if isolationQueue.sync(execute: { self.cancelled }) {
             localWriter.cancelWriting()
             try? FileManager.default.removeItem(at: outputURL)
             throw JMVideoCompressorError.cancelled
        }
        else {
            await localWriter.finishWriting()
            switch localWriter.status {
            case .completed:
                let analytics = try await gatherAnalytics(
                    originalURL: url, compressedURL: outputURL,
                    sourceVideoSettings: sourceVideoSettings, sourceAudioSettings: sourceAudioSettings,
                    targetVideoSettings: targetVideoSettings, targetAudioSettings: targetAudioSettings
                )
                logCompressionEnd(outputURL: outputURL, analytics: analytics)
                return (outputURL, analytics)
            case .failed:
                 try? FileManager.default.removeItem(at: outputURL)
                 throw JMVideoCompressorError.compressionFailed(localWriter.error ?? NSError(domain: "JMVideoCompressor", code: -4, userInfo: [NSLocalizedDescriptionKey: "Writer finished with failed status."]))
             case .cancelled:
                  try? FileManager.default.removeItem(at: outputURL)
                  throw JMVideoCompressorError.cancelled
             default:
                  try? FileManager.default.removeItem(at: outputURL)
                  throw JMVideoCompressorError.compressionFailed(NSError(domain: "JMVideoCompressor", code: -5, userInfo: [NSLocalizedDescriptionKey: "Writer finished with unexpected status: \(localWriter.status.rawValue)"]))
            }
        }
    }

    /// Cancels the current compression operation.
    public func cancel() {
        isolationQueue.sync {
            guard !self.cancelled else { return }
            self.cancelled = true
            print("JMVideoCompressor: Cancellation requested. Deferred cleanup will handle resource release.")
        }
    }

    // MARK: - Private Processing Logic
    private func processTrack(
        assetWriterInput: AVAssetWriterInput,
        readerOutput: AVAssetReaderOutput,
        frameIndexesToKeep: [Int]?,
        progressHandler: ((Float) -> Void)?
    ) async throws {
        var frameCounter: Int = 0
        var keepFrameIndicesIterator = frameIndexesToKeep?.makeIterator()
        var nextIndexToKeep: Int? = keepFrameIndicesIterator?.next()
        var lastProgressUpdate: Float = -1.0

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) -> Void in
            var didResume = false

            @Sendable func safeResume(throwing error: Error? = nil) {
                if !didResume {
                    didResume = true
                    if let error = error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }

            assetWriterInput.requestMediaDataWhenReady(on: isolationQueue) { [weak self] in
                guard let self = self else { safeResume(); return }

                while assetWriterInput.isReadyForMoreMediaData && !self.cancelled {
                    if self.cancelled {
                        assetWriterInput.markAsFinished()
                        safeResume(throwing: JMVideoCompressorError.cancelled)
                        return
                    }

                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        var shouldAppend = true
                        if frameIndexesToKeep != nil {
                            if let targetIndex = nextIndexToKeep {
                                if frameCounter == targetIndex { nextIndexToKeep = keepFrameIndicesIterator?.next() }
                                else { shouldAppend = false }
                            } else { shouldAppend = false }
                            frameCounter += 1
                        }

                        if shouldAppend {
                            if let handler = progressHandler, self.totalSourceTime.seconds > 0 {
                                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                                if pts.isValid {
                                    let progress = Float(pts.seconds / self.totalSourceTime.seconds)
                                    if progress >= lastProgressUpdate + 0.01 || progress >= 1.0 {
                                        DispatchQueue.main.async { handler(min(max(progress, 0.0), 1.0)) }
                                        lastProgressUpdate = progress
                                    }
                                }
                            }

                            if !assetWriterInput.append(sampleBuffer) {
                                let writerError = self.assetWriter?.error
                                print("Error: Failed to append \(assetWriterInput.mediaType) buffer. Writer status: \(self.assetWriter?.status.rawValue ?? -1). Error: \(writerError?.localizedDescription ?? "unknown")")
                                safeResume(throwing: JMVideoCompressorError.compressionFailed(writerError ?? NSError(domain: "JMVideoCompressor", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to append sample buffer."])))
                                return
                            }
                        }
                    } else {
                        assetWriterInput.markAsFinished()
                        if let handler = progressHandler, lastProgressUpdate < 1.0 {
                             DispatchQueue.main.async { handler(1.0) }
                        }
                        safeResume()
                        return
                    }
                }
            }
        }
    }

    // MARK: - Private Configuration & Setup Helpers
    private func determineOutputURL(config: CompressionConfig, sourceURL: URL) throws -> URL {
        let finalURL: URL
        let fileManager = FileManager.default
        let directoryToCheck: URL

        if let specificURL = config.outputURL {
            finalURL = specificURL
            directoryToCheck = finalURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directoryToCheck.path) {
                do { try fileManager.createDirectory(at: directoryToCheck, withIntermediateDirectories: true, attributes: nil) }
                catch { throw JMVideoCompressorError.invalidOutputPath(directoryToCheck) }
            }
        } else {
            let baseDirectory = config.outputDirectory ?? fileManager.temporaryDirectory
            let uniqueFilename = UUID().uuidString + "." + config.fileType.preferredFilenameExtension
            finalURL = baseDirectory.appendingPathComponent(uniqueFilename)
            directoryToCheck = baseDirectory
            if !fileManager.fileExists(atPath: directoryToCheck.path) {
                do { try fileManager.createDirectory(at: directoryToCheck, withIntermediateDirectories: true, attributes: nil) }
                catch { throw JMVideoCompressorError.invalidOutputPath(directoryToCheck) }
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryToCheck.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw JMVideoCompressorError.invalidOutputPath(directoryToCheck)
        }
        try? fileManager.removeItem(at: finalURL)
        return finalURL
    }

    internal struct SourceVideoSettings {
        let size: CGSize
        let fps: Float
        let bitrate: Float
        let transform: CGAffineTransform
        let colorPrimaries: String?
        let transferFunction: String?
        let yCbCrMatrix: String?
    }

    private func loadSourceVideoSettings(track: AVAssetTrack) async throws -> SourceVideoSettings {
        async let size = track.load(.naturalSize)
        async let fps = track.load(.nominalFrameRate)
        async let bitrate = track.load(.estimatedDataRate)
        async let transform = track.load(.preferredTransform)
        async let formatDescriptions = track.load(.formatDescriptions)

        var colorPrimaries: String? = nil
        var transferFunction: String? = nil
        var yCbCrMatrix: String? = nil

        do {
            let formatDescArray = try await formatDescriptions
            if let formatDesc = formatDescArray.first {
                func getStringValue(for key: CFString) -> String? {
                    guard let value = CMFormatDescriptionGetExtension(formatDesc, extensionKey: key) else { return nil }
                    return value as? String
                }
                colorPrimaries = getStringValue(for: kCMFormatDescriptionExtension_ColorPrimaries)
                transferFunction = getStringValue(for: kCMFormatDescriptionExtension_TransferFunction)
                yCbCrMatrix = getStringValue(for: kCMFormatDescriptionExtension_YCbCrMatrix)
            }
        } catch { print("Error loading format descriptions: \(error)") }

        // Assign default SDR values if reading failed
        if colorPrimaries == nil { colorPrimaries = kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String }
        if transferFunction == nil { transferFunction = kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String }
        if yCbCrMatrix == nil { yCbCrMatrix = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String }

        return try await SourceVideoSettings(
            size: size, fps: fps, bitrate: bitrate, transform: transform,
            colorPrimaries: colorPrimaries, transferFunction: transferFunction, yCbCrMatrix: yCbCrMatrix
        )
    }

    internal struct SourceAudioSettings {
        let bitrate: Float
        let sampleRate: Float
        let channels: Int
        let formatID: FourCharCode
    }

    private func loadSourceAudioSettings(track: AVAssetTrack?) async throws -> SourceAudioSettings? {
        guard let track = track else { return nil }
        async let bitrate = track.load(.estimatedDataRate)
        async let formatDescriptions = track.load(.formatDescriptions)
        var sampleRate: Float = 44100; var channels: Int = 2; var formatID: FourCharCode = 0
        if let formatDesc = try await formatDescriptions.first,
           let streamDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee {
            sampleRate = Float(streamDesc.mSampleRate); channels = Int(streamDesc.mChannelsPerFrame); formatID = streamDesc.mFormatID
        }
        return try await SourceAudioSettings(bitrate: bitrate, sampleRate: sampleRate, channels: channels, formatID: formatID)
    }

    /// Creates the video output settings dictionary and the appropriate transform.
    private func createTargetVideoSettings(config: CompressionConfig, source: SourceVideoSettings) throws -> (settings: [String: Any], transform: CGAffineTransform) {
        // 1. Calculate the desired *visual* output size based on constraints
        let targetVisualSize = calculateTargetSize(
            scale: config.scale,
            maxLongerDimension: config.maxLongerDimension,
            originalSize: source.size,
            sourceTransform: source.transform
        )

        // 2. Determine the actual encoding dimensions and transform based on the new flag
        let finalEncodingWidth: CGFloat
        let finalEncodingHeight: CGFloat
        let finalTransform: CGAffineTransform

        let sourceIsRotated = abs(source.transform.b) == 1.0 && abs(source.transform.c) == 1.0

        if config.forceVisualEncodingDimensions {
            // Encode directly using the visual dimensions, apply identity transform
            finalEncodingWidth = targetVisualSize.width
            finalEncodingHeight = targetVisualSize.height
            finalTransform = .identity // <<-- 중요: 회전 정보 제거
            print("Info: Forcing visual encoding dimensions (\(finalEncodingWidth)x\(finalEncodingHeight)) with identity transform.")
        } else {
            // Maintain current behavior: encode based on original orientation, copy transform
            if sourceIsRotated {
                finalEncodingWidth = targetVisualSize.height
                finalEncodingHeight = targetVisualSize.width
            } else {
                finalEncodingWidth = targetVisualSize.width
                finalEncodingHeight = targetVisualSize.height
            }
            finalTransform = source.transform // <<-- 중요: 원본 회전 정보 복사
            print("Info: Using original encoding orientation (\(finalEncodingWidth)x\(finalEncodingHeight)) and copying transform.")
        }

        // 3. Prepare compression properties
        var compressionProperties: [String: Any] = [
            AVVideoMaxKeyFrameIntervalKey: config.maxKeyFrameInterval,
            AVVideoAllowFrameReorderingKey: false,
        ]

        let isHDR: Bool
        if source.colorPrimaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) ||
           source.transferFunction == "ITU_R_2100_PQ" ||
           source.transferFunction == "ITU_R_2100_HLG" {
            isHDR = true
        } else {
            isHDR = false
        }

        let targetCodec = config.videoCodec
        var profileLevel: String? = nil

        if isHDR {
            if targetCodec == .hevc {
                profileLevel = kVTProfileLevel_HEVC_Main10_AutoLevel as String
                if #available(iOS 16.0, macOS 13.0, *) {
                    compressionProperties[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_Auto
                } else { /* Warning */ }
            } else { /* Warning, set SDR profile */
                 if targetCodec == .h264 {
                     profileLevel = AVVideoProfileLevelH264HighAutoLevel
                     compressionProperties[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
                 }
            }
        } else { // SDR
            if targetCodec == .hevc { profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel as String }
            else if targetCodec == .h264 {
                profileLevel = AVVideoProfileLevelH264HighAutoLevel
                compressionProperties[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
            }
        }
        if let level = profileLevel { compressionProperties[AVVideoProfileLevelKey] = level }

        if config.useExplicitBitrate {
            let minBitrate: Float = 50_000
            var effectiveBitrate = Float(config.videoBitrate)
            if effectiveBitrate > source.bitrate * 1.2 { effectiveBitrate = max(source.bitrate * 0.8, minBitrate) }
            effectiveBitrate = max(effectiveBitrate, minBitrate)
            compressionProperties[AVVideoAverageBitRateKey] = Int(effectiveBitrate)
        } else {
            compressionProperties[AVVideoQualityKey] = max(0.0, min(1.0, config.videoQuality))
        }

        // 4. Construct the final settings dictionary
        let settings: [String: Any] = [
            AVVideoCodecKey: targetCodec.avCodecType,
            AVVideoWidthKey: finalEncodingWidth,
            AVVideoHeightKey: finalEncodingHeight,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]

        // 5. Return both settings and the calculated transform
        return (settings, finalTransform)
    }


    /// Creates the audio output settings dictionary.
    private func createTargetAudioSettings(config: CompressionConfig, source: SourceAudioSettings?) throws -> [String: Any]? {
        guard let source = source else { return nil }
        var audioChannelLayout = AudioChannelLayout(); memset(&audioChannelLayout, 0, MemoryLayout<AudioChannelLayout>.size)
        let targetChannels = min(config.audioChannels ?? source.channels, 2)
        audioChannelLayout.mChannelLayoutTag = (targetChannels == 1) ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo

        let targetSampleRate = max(8000.0, min(192_000.0, Double(config.audioSampleRate)))
        let minBitrate: Float = 16_000
        var effectiveBitrate = Float(config.audioBitrate)
        if effectiveBitrate > source.bitrate * 1.2 { effectiveBitrate = max(source.bitrate * 0.8, minBitrate) }
        effectiveBitrate = max(effectiveBitrate, minBitrate)

        var targetCodec = config.audioCodec
        if (targetCodec == .aac_he_v1 || targetCodec == .aac_he_v2) && targetSampleRate > 48000 { targetCodec = .aac }

        return [
            AVFormatIDKey: targetCodec.formatID,
            AVEncoderBitRateKey: Int(effectiveBitrate),
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVChannelLayoutKey: Data(bytes: &audioChannelLayout, count: MemoryLayout<AudioChannelLayout>.size)
        ]
    }

    /// Calculates the target **visual** dimensions based on constraints.
    private func calculateTargetSize(
        scale: CGSize?,
        maxLongerDimension: CGFloat?,
        originalSize: CGSize,
        sourceTransform: CGAffineTransform
    ) -> CGSize {
        let isRotated = abs(sourceTransform.b) == 1.0 && abs(sourceTransform.c) == 1.0
        let visualOriginalSize = isRotated ? CGSize(width: originalSize.height, height: originalSize.width) : originalSize

        var targetVisualWidth: CGFloat = visualOriginalSize.width
        var targetVisualHeight: CGFloat = visualOriginalSize.height

        if let maxDim = maxLongerDimension, maxDim > 0 {
            let longerSide = max(visualOriginalSize.width, visualOriginalSize.height)
            if longerSide > maxDim {
                let scaleFactor = maxDim / longerSide
                targetVisualWidth = visualOriginalSize.width * scaleFactor
                targetVisualHeight = visualOriginalSize.height * scaleFactor
            }
        } else if let scale = scale, !(scale.width == -1 && scale.height == -1) {
             if scale.width != -1 && scale.height != -1 {
                 targetVisualWidth = scale.width
                 targetVisualHeight = scale.height
             } else if scale.width != -1 {
                 targetVisualWidth = scale.width
                 targetVisualHeight = (visualOriginalSize.height / visualOriginalSize.width) * targetVisualWidth
             } else {
                 targetVisualHeight = scale.height
                 targetVisualWidth = (visualOriginalSize.width / visualOriginalSize.height) * targetVisualHeight
             }
        }

        targetVisualWidth = max(2, floor(targetVisualWidth / 2.0) * 2.0)
        targetVisualHeight = max(2, floor(targetVisualHeight / 2.0) * 2.0)
        print("Calculated Target Visual Size: \(targetVisualWidth) x \(targetVisualHeight)")
        return CGSize(width: targetVisualWidth, height: targetVisualHeight)
    }


    private func detectContentType(videoTrack: AVAssetTrack) -> VideoContentType { return .standard }
    private func applyContentAwareOptimizations(to config: inout CompressionConfig, contentType: VideoContentType) { /* ... */ }

    private func gatherAnalytics(
        originalURL: URL, compressedURL: URL,
        sourceVideoSettings: SourceVideoSettings, sourceAudioSettings: SourceAudioSettings?,
        targetVideoSettings: [String: Any], targetAudioSettings: [String: Any]?
    ) async throws -> CompressionAnalytics {
        let originalFileSize = getFileSize(url: originalURL)
        let compressedFileSize = getFileSize(url: compressedURL)
        let ratio = (compressedFileSize > 0) ? Float(originalFileSize) / Float(compressedFileSize) : 0
        let compressedDimensions = CGSize(
            width: targetVideoSettings[AVVideoWidthKey] as? CGFloat ?? 0,
            height: targetVideoSettings[AVVideoHeightKey] as? CGFloat ?? 0
        )
        let compressedVideoBitrate: Float
        if let props = targetVideoSettings[AVVideoCompressionPropertiesKey] as? [String: Any], let br = props[AVVideoAverageBitRateKey] as? NSNumber {
            compressedVideoBitrate = br.floatValue
        } else {
            let duration = totalSourceTime.seconds
            compressedVideoBitrate = (duration > 0) ? Float(compressedFileSize * 8) / Float(duration) : 0
        }
        let compressedAudioBitrate = (targetAudioSettings?[AVEncoderBitRateKey] as? NSNumber)?.floatValue
        let processingTime = Date().timeIntervalSince(self.isolationQueue.sync { self.startTime ?? Date() })

        let isRotated = abs(sourceVideoSettings.transform.b) == 1.0 && abs(sourceVideoSettings.transform.c) == 1.0
        let visualOriginalSize = isRotated ? CGSize(width: sourceVideoSettings.size.height, height: sourceVideoSettings.size.width) : sourceVideoSettings.size

        return CompressionAnalytics(
            originalFileSize: originalFileSize, compressedFileSize: compressedFileSize,
            compressionRatio: ratio, processingTime: processingTime,
            originalDimensions: visualOriginalSize, compressedDimensions: compressedDimensions,
            originalVideoBitrate: sourceVideoSettings.bitrate, compressedVideoBitrate: compressedVideoBitrate,
            originalAudioBitrate: sourceAudioSettings?.bitrate, compressedAudioBitrate: compressedAudioBitrate
        )
    }

    private func getFileSize(url: URL) -> Int64 {
        do { return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }
        catch { return 0 }
    }

    private func logCompressionStart(sourceURL: URL, outputURL: URL, config: CompressionConfig) {
       #if DEBUG
       print("-------------------------------------")
       print("JMVideoCompressor: Starting compression...")
       print("  Source: \(sourceURL.lastPathComponent) (\(String(format: "%.2f MB", sourceURL.sizePerMB())))")
       print("  Output: \(outputURL.lastPathComponent)")
       print("  Config: \(config)")
       print("-------------------------------------")
       #endif
    }

    private func logCompressionEnd(outputURL: URL, analytics: CompressionAnalytics) {
       #if DEBUG
       print("""
       -------------------------------------
       JMVideoCompressor: Compression finished ✅
        Output: \(outputURL.lastPathComponent)
        Original Size: \(String(format: "%.2f MB", Double(analytics.originalFileSize) / (1024*1024)))
        Compressed Size: \(String(format: "%.2f MB", Double(analytics.compressedFileSize) / (1024*1024)))
        Ratio: \(String(format: "%.2f : 1", analytics.compressionRatio))
        Time Elapsed: \(String(format: "%.2f seconds", analytics.processingTime))
        Original Visual Res: \(Int(analytics.originalDimensions.width))x\(Int(analytics.originalDimensions.height)) -> Compressed Encoded Res: \(Int(analytics.compressedDimensions.width))x\(Int(analytics.compressedDimensions.height))
        Original Bitrate: \(String(format: "%.0f kbps", analytics.originalVideoBitrate / 1000)) -> Compressed Bitrate: \(String(format: "%.0f kbps", analytics.compressedVideoBitrate / 1000))
       -------------------------------------
       """)
       #endif
    }
}

// MARK: - AVFileType Extension Helper (Internal)
extension AVFileType {
    var preferredFilenameExtension: String {
        if #available(iOS 14.0, macOS 11.0, *) {
            return UTType(self.rawValue)?.preferredFilenameExtension ?? "tmp"
        } else {
            guard let ext = UTTypeCopyPreferredTagWithClass(self as CFString, kUTTagClassFilenameExtension)?.takeRetainedValue() else {
                switch self {
                    case .mov: return "mov"
                    case .mp4: return "mp4"
                    case .m4v: return "m4v"
                    case .m4a: return "m4a"
                    default: return "tmp"
                }
            }
            return ext as String
        }
    }
}
