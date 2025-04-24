//
//  JMVideoCompressor.swift
//  JMVideoCompressor
//
//  Created by raykim on 4/24/25.
//
import Foundation
import AVFoundation
import CoreMedia
import CoreServices // For UTType definitions if needed
import VideoToolbox // Import VideoToolbox for profile level constants and codec checks

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
            config.scale = CGSize(width: 640, height: -1) // Target max ~360p height
            config.videoBitrate = 500_000
            config.fps = 20
            config.audioBitrate = 64_000
            config.audioChannels = 1 // Mono often acceptable
            config.preprocessing.noiseReduction = .low // Apply some noise reduction
        case .mediumQuality:
            config.scale = CGSize(width: 1280, height: -1) // Target max ~720p height
            config.videoBitrate = 2_000_000
            config.fps = 30
            config.audioBitrate = 128_000
        case .highQuality:
            config.scale = CGSize(width: 1920, height: -1) // Target max ~1080p height
            config.videoBitrate = 5_000_000
            config.fps = 30
            config.audioBitrate = 192_000
            // Try HEVC if supported for high quality
            if VideoCodec.hevc.isSupported() {
                config.videoCodec = .hevc
            }
        case .socialMedia:
             config.scale = CGSize(width: 1280, height: -1) // Target 720p height
             config.videoBitrate = 3_500_000 // Slightly lower than medium bitrate
             config.fps = 30
             config.audioBitrate = 128_000
             // config.preprocessing.autoLevels = true // Optional: Adjust levels
        case .messaging:
             config.scale = CGSize(width: 854, height: -1) // Target 480p height
             config.videoBitrate = 1_000_000 // Lower bitrate
             config.fps = 24
             config.audioBitrate = 64_000
             config.audioChannels = 1 // Mono often preferred
             config.preprocessing.noiseReduction = .medium
        }
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
    /// Dimensions (width, height) of the original video.
    public let originalDimensions: CGSize
    /// Dimensions (width, height) of the compressed video.
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
    // Store references to inputs/outputs for progress calculation
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
        outputDirectory: URL? = nil,
        progressHandler: ((Float) -> Void)? = nil
    ) async throws -> (url: URL, analytics: CompressionAnalytics) {
        var config = quality.defaultConfig
        config.outputDirectory = outputDirectory
        return try await compressVideo(url, config: config, frameReducer: frameReducer, progressHandler: progressHandler)
    }

    /// Compresses the video at the given URL using custom configuration.
    public func compressVideo(
        _ url: URL,
        config: CompressionConfig,
        frameReducer: VideoFrameReducer = ReduceFrameEvenlySpaced(),
        progressHandler: ((Float) -> Void)? = nil
    ) async throws -> (url: URL, analytics: CompressionAnalytics) {

        isolationQueue.sync {
            self.cancelled = false
            self.startTime = Date()
            self.assetReader = nil
            self.assetWriter = nil
            self.videoInput = nil
            self.audioInput = nil
            self.totalSourceTime = .zero
        }

        // --- Input Validation & Codec Check ---
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw JMVideoCompressorError.invalidSourceURL(url)
        }
        guard config.videoCodec.isSupported() else {
            throw JMVideoCompressorError.codecNotSupported(config.videoCodec)
        }

        let sourceAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        self.totalSourceTime = try await sourceAsset.load(.duration)

        // --- Load Tracks ---
        guard let sourceVideoTrack = try? await sourceAsset.loadTracks(withMediaType: .video).first else {
            throw JMVideoCompressorError.missingVideoTrack
        }
        let sourceAudioTrack = try? await sourceAsset.loadTracks(withMediaType: .audio).first

        // --- Calculate Settings ---
        let sourceVideoSettings = try await loadSourceVideoSettings(track: sourceVideoTrack)
        let sourceAudioSettings = try await loadSourceAudioSettings(track: sourceAudioTrack)

        let contentType = config.contentAwareOptimization ? detectContentType(videoTrack: sourceVideoTrack) : .standard
        var effectiveConfig = config
        applyContentAwareOptimizations(to: &effectiveConfig, contentType: contentType)

        let targetFPS = min(effectiveConfig.fps, sourceVideoSettings.fps)
        let needsFrameReduction = targetFPS < sourceVideoSettings.fps

        let targetVideoSettings = try createTargetVideoSettings(config: effectiveConfig, source: sourceVideoSettings)
        let targetAudioSettings = try createTargetAudioSettings(config: effectiveConfig, source: sourceAudioSettings)

        // --- Determine Output URL ---
        let outputURL = try determineOutputURL(config: effectiveConfig, sourceURL: url)

        // --- Setup Reader & Writer ---
        do {
            assetReader = try AVAssetReader(asset: sourceAsset)
        } catch {
            throw JMVideoCompressorError.readerInitializationFailed(error)
        }
        do {
            assetWriter = try AVAssetWriter(url: outputURL, fileType: effectiveConfig.fileType)
        } catch {
            throw JMVideoCompressorError.writerInitializationFailed(error)
        }

        guard let reader = assetReader, let writer = assetWriter else {
            throw JMVideoCompressorError.compressionFailed(NSError(domain: "JMVideoCompressor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Reader or Writer became nil unexpectedly."]))
        }
        writer.shouldOptimizeForNetworkUse = true

        // --- Configure Reader Outputs ---
        let videoOutputSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let videoOutput = AVAssetReaderTrackOutput(track: sourceVideoTrack, outputSettings: videoOutputSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw JMVideoCompressorError.compressionFailed(NSError(domain: "JMVideoCompressor", code: -2, userInfo: [NSLocalizedDescriptionKey: "Cannot add video reader output."]))
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let sourceAudio = sourceAudioTrack, targetAudioSettings != nil {
            let audioDecompressionSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVNumberOfChannelsKey: effectiveConfig.audioChannels ?? sourceAudioSettings?.channels ?? 2
            ]
            let output = AVAssetReaderTrackOutput(track: sourceAudio, outputSettings: audioDecompressionSettings)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) { reader.add(output); audioOutput = output }
            else { print("Warning: Could not add audio reader output.") }
        }

        // --- Configure Writer Inputs ---
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: targetVideoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = try await sourceVideoTrack.load(.preferredTransform)
        guard writer.canAdd(videoInput) else {
            throw JMVideoCompressorError.compressionFailed(NSError(domain: "JMVideoCompressor", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video writer input."]))
        }
        writer.add(videoInput)
        self.videoInput = videoInput // Store weak reference for progress

        var audioInput: AVAssetWriterInput?
        if let settings = targetAudioSettings, audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioInput = input; self.audioInput = input } // Store weak reference
            else { print("Warning: Could not add audio writer input."); audioOutput = nil }
        }

        // --- Start Compression ---
        logCompressionStart(sourceURL: url, outputURL: outputURL, config: effectiveConfig)

        guard reader.startReading() else { throw JMVideoCompressorError.readerInitializationFailed(reader.error) }
        guard writer.startWriting() else { throw JMVideoCompressorError.writerInitializationFailed(writer.error) }
        writer.startSession(atSourceTime: .zero)

        // --- Process Samples Asynchronously ---
        let frameIndexesToKeep = needsFrameReduction ? frameReducer.reduce(
            originalFPS: sourceVideoSettings.fps,
            to: targetFPS,
            with: Float(totalSourceTime.seconds)
        ) : nil

        // Use TaskGroup for concurrent processing
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.processTrack(
                    assetWriterInput: videoInput,
                    readerOutput: videoOutput,
                    frameIndexesToKeep: frameIndexesToKeep,
                    progressHandler: progressHandler // Pass progress handler
                )
            }
            if let audioIn = audioInput, let audioOut = audioOutput {
                group.addTask {
                    await self.processTrack(
                        assetWriterInput: audioIn,
                        readerOutput: audioOut,
                        frameIndexesToKeep: nil,
                        progressHandler: nil // Only report progress based on video track for simplicity
                    )
                }
            }
        }

        // --- Finish Writing ---
        if isolationQueue.sync(execute: { self.cancelled }) {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw JMVideoCompressorError.cancelled
        } else {
            await writer.finishWriting()
            switch writer.status {
            case .completed:
                let analytics = try await gatherAnalytics(
                    originalURL: url,
                    compressedURL: outputURL,
                    sourceVideoSettings: sourceVideoSettings,
                    sourceAudioSettings: sourceAudioSettings,
                    targetVideoSettings: targetVideoSettings,
                    targetAudioSettings: targetAudioSettings
                )
                logCompressionEnd(outputURL: outputURL, analytics: analytics)
                return (outputURL, analytics) // Return URL and analytics
            case .failed:
                try? FileManager.default.removeItem(at: outputURL)
                throw JMVideoCompressorError.compressionFailed(writer.error ?? NSError(domain: "JMVideoCompressor", code: -4, userInfo: [NSLocalizedDescriptionKey: "Writer finished with failed status."]))
            case .cancelled:
                 try? FileManager.default.removeItem(at: outputURL)
                 throw JMVideoCompressorError.cancelled
            default:
                 try? FileManager.default.removeItem(at: outputURL)
                 throw JMVideoCompressorError.compressionFailed(NSError(domain: "JMVideoCompressor", code: -5, userInfo: [NSLocalizedDescriptionKey: "Writer finished with unexpected status: \(writer.status.rawValue)"]))
            }
        }
    }

    /// Cancels the current compression operation.
    public func cancel() {
        isolationQueue.sync {
            guard !self.cancelled else { return }
            self.cancelled = true
            self.assetReader?.cancelReading()
            self.assetWriter?.cancelWriting()
            print("JMVideoCompressor: Cancellation requested.")
        }
    }

    // MARK: - Private Processing Logic
    private func processTrack(
        assetWriterInput: AVAssetWriterInput,
        readerOutput: AVAssetReaderOutput,
        frameIndexesToKeep: [Int]?,
        progressHandler: ((Float) -> Void)?
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) -> Void in
            var frameCounter: Int = 0
            var keepFrameIndicesIterator = frameIndexesToKeep?.makeIterator()
            var nextIndexToKeep: Int? = keepFrameIndicesIterator?.next()
            var lastProgressUpdate: Float = -1.0 // Track last progress update

            assetWriterInput.requestMediaDataWhenReady(on: isolationQueue) { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                guard !self.cancelled else {
                    assetWriterInput.markAsFinished()
                    continuation.resume()
                    return
                }

                while assetWriterInput.isReadyForMoreMediaData && !self.cancelled {
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
                            // --- Progress Reporting ---
                            if let handler = progressHandler, self.totalSourceTime.seconds > 0 {
                                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                                if pts.isValid {
                                    let progress = Float(pts.seconds / self.totalSourceTime.seconds)
                                    if progress >= lastProgressUpdate + 0.01 || progress >= 1.0 { // Report 1.0 always
                                        handler(min(max(progress, 0.0), 1.0)) // Clamp progress
                                        lastProgressUpdate = progress
                                    }
                                }
                            }
                            // --- End Progress Reporting ---

                            if !assetWriterInput.append(sampleBuffer) {
                                print("Warning: Failed to append \(assetWriterInput.mediaType) buffer. Writer status: \(self.assetWriter?.status.rawValue ?? -1). Error: \(self.assetWriter?.error?.localizedDescription ?? "unknown")")
                            }
                        }
                    } else {
                        assetWriterInput.markAsFinished()
                        if let handler = progressHandler, lastProgressUpdate < 1.0 { handler(1.0) } // Final progress update
                        continuation.resume()
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
        if let specificURL = config.outputURL {
            finalURL = specificURL
            let outputDir = finalURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: outputDir.path) {
                do { try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true, attributes: nil) }
                catch { throw JMVideoCompressorError.invalidOutputPath(outputDir) }
            }
        } else {
            let baseDirectory = config.outputDirectory ?? fileManager.temporaryDirectory
            let uniqueFilename = UUID().uuidString + "." + config.fileType.preferredFilenameExtension
            finalURL = baseDirectory.appendingPathComponent(uniqueFilename)
            if !fileManager.fileExists(atPath: baseDirectory.path) {
                do { try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: nil) }
                catch { throw JMVideoCompressorError.invalidOutputPath(baseDirectory) }
            }
        }
        try? fileManager.removeItem(at: finalURL)
        return finalURL
    }

    /// Internal helper struct for source video properties.
    internal struct SourceVideoSettings {
        let size: CGSize
        let fps: Float
        let bitrate: Float
        let transform: CGAffineTransform
    }

    private func loadSourceVideoSettings(track: AVAssetTrack) async throws -> SourceVideoSettings {
        async let size = track.load(.naturalSize)
        async let fps = track.load(.nominalFrameRate)
        async let bitrate = track.load(.estimatedDataRate)
        async let transform = track.load(.preferredTransform)
        return try await SourceVideoSettings(size: size, fps: fps, bitrate: bitrate, transform: transform)
    }

    /// Internal helper struct for source audio properties.
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
        } else { print("Warning: Could not read source audio format description.") }
        return try await SourceAudioSettings(bitrate: bitrate, sampleRate: sampleRate, channels: channels, formatID: formatID)
    }

    /// Creates the video output settings dictionary.
    private func createTargetVideoSettings(config: CompressionConfig, source: SourceVideoSettings) throws -> [String: Any] {
        let targetSize = calculateTargetSize(scale: config.scale, originalSize: source.size, sourceTransform: source.transform)
        var compressionProperties: [String: Any] = [
            AVVideoProfileLevelKey: (config.videoCodec == .hevc) ? (kVTProfileLevel_HEVC_Main_AutoLevel as String) : AVVideoProfileLevelH264HighAutoLevel,
            // AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC, // *** REMOVED conditional logic below ***
            AVVideoMaxKeyFrameIntervalKey: config.maxKeyFrameInterval,
            AVVideoAllowFrameReorderingKey: false,
        ]

        // *** CORRECTED: Conditionally add H.264 specific property ***
        if config.videoCodec == .h264 {
            compressionProperties[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        }

        if config.useExplicitBitrate {
            let minBitrate: Float = 50_000
            var effectiveBitrate = Float(config.videoBitrate)
            if effectiveBitrate > source.bitrate * 1.2 { effectiveBitrate = max(source.bitrate * 0.8, minBitrate) }
            effectiveBitrate = max(effectiveBitrate, minBitrate)
            compressionProperties[AVVideoAverageBitRateKey] = Int(effectiveBitrate)
        } else {
            compressionProperties[AVVideoQualityKey] = max(0.0, min(1.0, config.videoQuality))
        }
        return [
            AVVideoCodecKey: config.videoCodec.avCodecType,
            AVVideoWidthKey: targetSize.width,
            AVVideoHeightKey: targetSize.height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
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
        if (targetCodec == .aac_he_v1 || targetCodec == .aac_he_v2) && targetSampleRate > 48000 {
            print("Warning: HE-AAC codec might not support sample rate \(targetSampleRate) Hz. Falling back to standard AAC.")
            targetCodec = .aac
        }
        return [
            AVFormatIDKey: targetCodec.formatID, AVEncoderBitRateKey: Int(effectiveBitrate),
            AVSampleRateKey: targetSampleRate, AVNumberOfChannelsKey: targetChannels,
            AVChannelLayoutKey: Data(bytes: &audioChannelLayout, count: MemoryLayout<AudioChannelLayout>.size)
        ]
    }

    // MARK: - Private Calculation & Analysis Helpers
    private func calculateTargetSize(scale: CGSize?, originalSize: CGSize, sourceTransform: CGAffineTransform) -> CGSize {
        let isRotated = abs(sourceTransform.b) == 1.0 && abs(sourceTransform.c) == 1.0
        let visualOriginalSize = isRotated ? CGSize(width: originalSize.height, height: originalSize.width) : originalSize
        guard let scale = scale, !(scale.width == -1 && scale.height == -1) else {
            return CGSize(width: floor(visualOriginalSize.width / 2.0) * 2.0, height: floor(visualOriginalSize.height / 2.0) * 2.0)
        }
        var targetWidth: CGFloat; var targetHeight: CGFloat
        if scale.width != -1 && scale.height != -1 { targetWidth = scale.width; targetHeight = scale.height }
        else if scale.width != -1 { targetWidth = scale.width; targetHeight = scale.width * visualOriginalSize.height / visualOriginalSize.width }
        else { targetHeight = scale.height; targetWidth = scale.height * visualOriginalSize.width / visualOriginalSize.height }
        targetWidth = max(2, floor(targetWidth / 2.0) * 2.0); targetHeight = max(2, floor(targetHeight / 2.0) * 2.0)
        return CGSize(width: targetWidth, height: targetHeight)
    }

    /// Basic content type detection based on heuristics.
    private func detectContentType(videoTrack: AVAssetTrack) -> VideoContentType {
        let fps = videoTrack.nominalFrameRate
        let size = videoTrack.naturalSize
        if fps > 45 { return .highMotion }
        if fps < 24 { return .lowMotion }
        if (size.width == 1920 && size.height == 1080) || (size.width == 1280 && size.height == 720) || (size.width == 3840 && size.height == 2160) {
            return .screencast
        }
        return .standard
    }

    /// Adjusts configuration based on detected content type.
    private func applyContentAwareOptimizations(to config: inout CompressionConfig, contentType: VideoContentType) {
        guard config.contentAwareOptimization else { return }
        switch contentType {
        case .highMotion:
            config.maxKeyFrameInterval = min(config.maxKeyFrameInterval, 15)
        case .lowMotion:
            config.maxKeyFrameInterval = max(config.maxKeyFrameInterval, 60)
        case .screencast:
            if config.useExplicitBitrate { config.videoBitrate = max(config.videoBitrate, 2_500_000) }
            else { config.videoQuality = max(config.videoQuality, 0.75) }
            config.maxKeyFrameInterval = max(config.maxKeyFrameInterval, 90)
        case .standard:
            break
        }
    }

    /// Gathers analytics data after successful compression.
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
        if let bitrate = (targetVideoSettings[AVVideoCompressionPropertiesKey] as? [String: Any])?[AVVideoAverageBitRateKey] as? NSNumber {
            compressedVideoBitrate = bitrate.floatValue
        } else {
            compressedVideoBitrate = (totalSourceTime.seconds > 0) ? Float(compressedFileSize * 8) / Float(totalSourceTime.seconds) : 0
        }

        let compressedAudioBitrate = (targetAudioSettings?[AVEncoderBitRateKey] as? NSNumber)?.floatValue
        let processingTime = Date().timeIntervalSince(self.startTime ?? Date())

        return CompressionAnalytics(
            originalFileSize: originalFileSize, compressedFileSize: compressedFileSize,
            compressionRatio: ratio, processingTime: processingTime,
            originalDimensions: sourceVideoSettings.size, compressedDimensions: compressedDimensions,
            originalVideoBitrate: sourceVideoSettings.bitrate, compressedVideoBitrate: compressedVideoBitrate,
            originalAudioBitrate: sourceAudioSettings?.bitrate, compressedAudioBitrate: compressedAudioBitrate
        )
    }

    /// Helper to get file size safely.
    private func getFileSize(url: URL) -> Int64 {
        do { return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }
        catch { print("Warning: Could not get file size for \(url.path): \(error)"); return 0 }
    }

    // MARK: - Logging Helpers
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
         Original Res: \(analytics.originalDimensions.width)x\(analytics.originalDimensions.height) -> Compressed Res: \(analytics.compressedDimensions.width)x\(analytics.compressedDimensions.height)
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
                switch self { case .mov: return "mov"; case .mp4: return "mp4"; case .m4v: return "m4v"; case .m4a: return "m4a"; default: return "tmp" }
            }
            return ext as String
        }
    }
}
