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
    // Use a serial queue for state synchronization and AVFoundation interaction.
    private let isolationQueue = DispatchQueue(label: "com.jmvideocompressor.isolation")
    private var assetWriter: AVAssetWriter?
    private var assetReader: AVAssetReader?
    private var cancelled: Bool = false // Synchronized via isolationQueue
    private var startTime: Date? // Synchronized via isolationQueue
    // Store references to inputs/outputs for progress calculation
    private weak var videoInput: AVAssetWriterInput? // Access synchronized via isolationQueue
    private weak var audioInput: AVAssetWriterInput? // Access synchronized via isolationQueue
    private var totalSourceTime: CMTime = .zero // Set once, read concurrently okay

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

        // Reset state within the isolation queue
        isolationQueue.sync {
            self.cancelled = false
            self.startTime = Date()
            self.assetReader = nil
            self.assetWriter = nil
            self.videoInput = nil
            self.audioInput = nil
            // totalSourceTime is reset below after loading asset duration
        }

        // --- Input Validation & Codec Check ---
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw JMVideoCompressorError.invalidSourceURL(url)
        }
        guard config.videoCodec.isSupported() else {
            throw JMVideoCompressorError.codecNotSupported(config.videoCodec)
        }

        let sourceAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        // Load duration and store it (safe to read concurrently later)
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

        // --- Determine Output URL (and validate path *before* writer init) ---
        let outputURL = try determineOutputURL(config: effectiveConfig, sourceURL: url)

        // --- Setup Reader & Writer ---
        let localReader: AVAssetReader
        let localWriter: AVAssetWriter
        do {
            localReader = try AVAssetReader(asset: sourceAsset)
        } catch {
            throw JMVideoCompressorError.readerInitializationFailed(error)
        }
        do {
            // Writer initialization now happens *after* output path validation
            localWriter = try AVAssetWriter(url: outputURL, fileType: effectiveConfig.fileType)
        } catch {
            // Catch specific error if writer fails due to path issues (though determineOutputURL should prevent most)
            // *** REMOVED check for AVError.cannotCreateFile ***
             if let nsError = error as NSError?, nsError.domain == AVFoundationErrorDomain, nsError.code == AVError.fileFormatNotRecognized.rawValue {
                 throw JMVideoCompressorError.invalidOutputPath(outputURL) // Map to our specific error
             }
            throw JMVideoCompressorError.writerInitializationFailed(error)
        }
        localWriter.shouldOptimizeForNetworkUse = true

        // Store reader/writer references within isolation queue
        isolationQueue.sync {
            self.assetReader = localReader
            self.assetWriter = localWriter
        }

        // --- Configure Reader Outputs ---
        let videoOutputSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let videoOutput = AVAssetReaderTrackOutput(track: sourceVideoTrack, outputSettings: videoOutputSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard localReader.canAdd(videoOutput) else {
            throw JMVideoCompressorError.compressionFailed(NSError(domain: "JMVideoCompressor", code: -2, userInfo: [NSLocalizedDescriptionKey: "Cannot add video reader output."]))
        }
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
        videoInput.transform = try await sourceVideoTrack.load(.preferredTransform)
        guard localWriter.canAdd(videoInput) else {
            throw JMVideoCompressorError.compressionFailed(NSError(domain: "JMVideoCompressor", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video writer input."]))
        }
        localWriter.add(videoInput)
        isolationQueue.sync { self.videoInput = videoInput } // Store weak reference

        var audioInput: AVAssetWriterInput?
        if let settings = targetAudioSettings, audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            if localWriter.canAdd(input) {
                localWriter.add(input)
                audioInput = input
                isolationQueue.sync { self.audioInput = input } // Store weak reference
            } else {
                print("Warning: Could not add audio writer input.")
                audioOutput = nil // Ensure audioOutput is nil if input couldn't be added
            }
        }

        // --- Start Compression ---
        logCompressionStart(sourceURL: url, outputURL: outputURL, config: effectiveConfig)

        guard localReader.startReading() else { throw JMVideoCompressorError.readerInitializationFailed(localReader.error) }
        guard localWriter.startWriting() else { throw JMVideoCompressorError.writerInitializationFailed(localWriter.error) }
        localWriter.startSession(atSourceTime: .zero)

        // --- Process Samples Asynchronously ---
        let frameIndexesToKeep = needsFrameReduction ? frameReducer.reduce(
            originalFPS: sourceVideoSettings.fps,
            to: targetFPS,
            with: Float(totalSourceTime.seconds)
        ) : nil

        // Use TaskGroup for concurrent processing of video and audio tracks
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.processTrack(
                    assetWriterInput: videoInput,
                    readerOutput: videoOutput,
                    frameIndexesToKeep: frameIndexesToKeep,
                    progressHandler: progressHandler // Pass progress handler
                )
            }
            if let audioIn = audioInput, let audioOut = audioOutput {
                group.addTask {
                    try await self.processTrack(
                        assetWriterInput: audioIn,
                        readerOutput: audioOut,
                        frameIndexesToKeep: nil, // No frame reduction for audio
                        progressHandler: nil // Only report progress based on video track
                    )
                }
            }
            // Wait for all track processing tasks to complete or throw
            try await group.waitForAll()
        } // End TaskGroup

        // --- Finish Writing ---
        // Check cancellation status safely using the isolation queue
        if isolationQueue.sync(execute: { self.cancelled }) {
            localWriter.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw JMVideoCompressorError.cancelled
        } else {
            await localWriter.finishWriting()
            switch localWriter.status {
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
        isolationQueue.sync { // Synchronize access to shared state
            guard !self.cancelled else { return }
            self.cancelled = true
            // Use the reader/writer references stored during setup
            self.assetReader?.cancelReading()
            self.assetWriter?.cancelWriting()
            print("JMVideoCompressor: Cancellation requested.")
        }
    }

    // MARK: - Private Processing Logic

    /// Processes samples for a single track (video or audio).
    /// Throws an error if appending samples fails.
    private func processTrack(
        assetWriterInput: AVAssetWriterInput,
        readerOutput: AVAssetReaderOutput,
        frameIndexesToKeep: [Int]?,
        progressHandler: ((Float) -> Void)?
    ) async throws { // Marked as throwing
        // Create a state manager actor instance for this specific track processing task
        // Removed actor state as direct processing on isolation queue is simpler
        // let state = TrackProcessorState(frameIndexesToKeep: frameIndexesToKeep)
        var frameCounter: Int = 0
        var keepFrameIndicesIterator = frameIndexesToKeep?.makeIterator()
        var nextIndexToKeep: Int? = keepFrameIndicesIterator?.next()
        var lastProgressUpdate: Float = -1.0 // Track last progress update

        // Use a continuation to bridge the callback-based API with async/await
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) -> Void in
            var didResume = false // Flag to prevent double resumption

            // Function to safely resume the continuation exactly once
            // Marked @Sendable as it's called from a concurrent queue's closure
            @Sendable func safeResume(throwing error: Error? = nil) {
                if !didResume {
                    didResume = true
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }

            // Request media data on the isolation queue for thread safety with AVFoundation objects
            assetWriterInput.requestMediaDataWhenReady(on: isolationQueue) { [weak self] in
                guard let self = self else {
                    safeResume() // Resume if self is nil
                    return
                }

                // --- Start Processing Logic (Simplified: Directly on isolationQueue) ---
                while assetWriterInput.isReadyForMoreMediaData && !self.cancelled {
                    // Check for cancellation first inside the loop
                    if self.cancelled {
                        assetWriterInput.markAsFinished()
                        safeResume(throwing: JMVideoCompressorError.cancelled)
                        return // Exit loop and closure
                    }

                    // Read the next sample buffer
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        var shouldAppend = true

                        // --- Frame Reduction Logic ---
                        if frameIndexesToKeep != nil {
                            if let targetIndex = nextIndexToKeep {
                                if frameCounter == targetIndex {
                                    nextIndexToKeep = keepFrameIndicesIterator?.next() // Advance iterator
                                } else {
                                    shouldAppend = false
                                }
                            } else {
                                shouldAppend = false // No more indices to keep
                            }
                            frameCounter += 1
                        }
                        // --- End Frame Reduction ---

                        if shouldAppend {
                            // --- Progress Reporting ---
                            if let handler = progressHandler, self.totalSourceTime.seconds > 0 {
                                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                                if pts.isValid {
                                    let progress = Float(pts.seconds / self.totalSourceTime.seconds)
                                    // Update progress if changed significantly or final
                                    if progress >= lastProgressUpdate + 0.01 || progress >= 1.0 {
                                        // Call handler on main thread for UI updates
                                        DispatchQueue.main.async {
                                            handler(min(max(progress, 0.0), 1.0))
                                        }
                                        lastProgressUpdate = progress
                                    }
                                }
                            }
                            // --- End Progress ---

                            // --- Append Buffer --- (Already on isolationQueue)
                            if !assetWriterInput.append(sampleBuffer) {
                                let writerError = self.assetWriter?.error // Get writer error safely
                                print("Error: Failed to append \(assetWriterInput.mediaType) buffer. Writer status: \(self.assetWriter?.status.rawValue ?? -1). Error: \(writerError?.localizedDescription ?? "unknown")")
                                safeResume(throwing: JMVideoCompressorError.compressionFailed(writerError ?? NSError(domain: "JMVideoCompressor", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to append sample buffer."])))
                                return // Exit loop and closure on error
                            }
                            // If append succeeded, loop continues
                        } // End if shouldAppend
                    } else {
                        // No more sample buffers available
                        assetWriterInput.markAsFinished()
                        // Send final progress update if needed
                        if let handler = progressHandler, lastProgressUpdate < 1.0 {
                             DispatchQueue.main.async {
                                handler(1.0)
                             }
                        }
                        safeResume() // Resume after marking finished
                        return // Exit loop and closure
                    }
                } // End while loop

                // If loop finished because input is not ready or cancelled (already handled),
                // the callback will be invoked again when ready, or the continuation was resumed.
            } // End requestMediaDataWhenReady closure
        } // End withCheckedThrowingContinuation
    }


    // MARK: - Private Configuration & Setup Helpers
    /// Determines the final output URL and validates the path.
    private func determineOutputURL(config: CompressionConfig, sourceURL: URL) throws -> URL {
        let finalURL: URL
        let fileManager = FileManager.default
        let directoryToCheck: URL

        if let specificURL = config.outputURL {
            finalURL = specificURL
            directoryToCheck = finalURL.deletingLastPathComponent() // Check parent directory
            // Ensure parent directory exists
            if !fileManager.fileExists(atPath: directoryToCheck.path) {
                do {
                    try fileManager.createDirectory(at: directoryToCheck, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    throw JMVideoCompressorError.invalidOutputPath(directoryToCheck)
                }
            }
        } else {
            let baseDirectory = config.outputDirectory ?? fileManager.temporaryDirectory
            let uniqueFilename = UUID().uuidString + "." + config.fileType.preferredFilenameExtension
            finalURL = baseDirectory.appendingPathComponent(uniqueFilename)
            directoryToCheck = baseDirectory // Check the specified/temp directory itself
            // Ensure base directory exists
            if !fileManager.fileExists(atPath: directoryToCheck.path) {
                do {
                    try fileManager.createDirectory(at: directoryToCheck, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    throw JMVideoCompressorError.invalidOutputPath(directoryToCheck)
                }
            }
        }

        // --- Path Validation ---
        var isDirectory: ObjCBool = false
        // Check if the *directory* path exists and is indeed a directory
        guard fileManager.fileExists(atPath: directoryToCheck.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            // Throw error if the intended directory path is not valid or is a file
            throw JMVideoCompressorError.invalidOutputPath(directoryToCheck)
        }

        // Attempt to remove any existing file at the *final* output path
        try? fileManager.removeItem(at: finalURL)

        return finalURL
    }


    /// Internal helper struct for source video properties.
    internal struct SourceVideoSettings {
        let size: CGSize
        let fps: Float
        let bitrate: Float
        let transform: CGAffineTransform
        // HDR Metadata
        let colorPrimaries: String? // e.g., "ITU_R_2020"
        let transferFunction: String? // e.g., "ITU_R_2100_PQ" or "ITU_R_2100_HLG"
        let yCbCrMatrix: String? // e.g., "ITU_R_2020"
    }

    private func loadSourceVideoSettings(track: AVAssetTrack) async throws -> SourceVideoSettings {
        async let size = track.load(.naturalSize)
        async let fps = track.load(.nominalFrameRate)
        async let bitrate = track.load(.estimatedDataRate)
        async let transform = track.load(.preferredTransform)
        async let formatDescriptions = track.load(.formatDescriptions)

        // Default SDR values
        var colorPrimaries: String? = kCMFormatDescriptionColorPrimaries_SMPTE_C as String // Or ITU_R_709_2? Check common SDR
        var transferFunction: String? = kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String
        var yCbCrMatrix: String? = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String

        // Attempt to read HDR metadata from format descriptions
        if let formatDesc = try await formatDescriptions.first {
            func getStringValue(for key: CFString) -> String? {
                CMFormatDescriptionGetExtension(formatDesc, extensionKey: key) as? String
            }
            colorPrimaries = getStringValue(for: kCMFormatDescriptionExtension_ColorPrimaries) ?? colorPrimaries
            transferFunction = getStringValue(for: kCMFormatDescriptionExtension_TransferFunction) ?? transferFunction
            yCbCrMatrix = getStringValue(for: kCMFormatDescriptionExtension_YCbCrMatrix) ?? yCbCrMatrix
        } else {
            print("Warning: Could not read source video format description.")
        }

        return try await SourceVideoSettings(
            size: size, fps: fps, bitrate: bitrate, transform: transform,
            colorPrimaries: colorPrimaries, transferFunction: transferFunction, yCbCrMatrix: yCbCrMatrix
        )
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

    /// Creates the video output settings dictionary. Handles SDR and HDR based on source metadata.
    private func createTargetVideoSettings(config: CompressionConfig, source: SourceVideoSettings) throws -> [String: Any] {
        let targetSize = calculateTargetSize(scale: config.scale, originalSize: source.size, sourceTransform: source.transform)

        var compressionProperties: [String: Any] = [
            AVVideoMaxKeyFrameIntervalKey: config.maxKeyFrameInterval,
            AVVideoAllowFrameReorderingKey: false,
        ]

        // --- Determine HDR status ---
        let isHDR: Bool
        // Compare against known string values instead of potentially unavailable constants
        if source.colorPrimaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) ||
           source.transferFunction == "ITU_R_2100_PQ" ||
           source.transferFunction == "ITU_R_2100_HLG" {
            isHDR = true
        } else {
            isHDR = false
        }

        let targetCodec = config.videoCodec
        var profileLevel: String? = nil

        // --- Set Profile Level and HDR Metadata --- 
        if isHDR {
            if targetCodec == .hevc {
                // Use HEVC Main10 AutoLevel for 10-bit HDR
                profileLevel = kVTProfileLevel_HEVC_Main10_AutoLevel as String

                // Add HDR metadata to compression properties
                if let primaries = source.colorPrimaries {
                    compressionProperties[kVTCompressionPropertyKey_ColorPrimaries as String] = primaries
                }
                if let transfer = source.transferFunction {
                    compressionProperties[kVTCompressionPropertyKey_TransferFunction as String] = transfer
                }
                if let matrix = source.yCbCrMatrix {
                    compressionProperties[kVTCompressionPropertyKey_YCbCrMatrix as String] = matrix
                }
                print("Info: HDR detected and HEVC Main10 profile selected. Applying HDR metadata.")
            } else {
                 // HDR detected but codec is not HEVC
                 print("Warning: HDR metadata detected, but video codec is not HEVC. HDR information might be lost. Consider using .hevc codec.")
                 // Set profile for the non-HEVC codec (e.g., H.264)
                 if targetCodec == .h264 {
                     profileLevel = AVVideoProfileLevelH264HighAutoLevel
                     compressionProperties[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
                 } else {
                     // Handle other potential codecs if added later
                     print("Warning: Unsupported codec for HDR passthrough: \(targetCodec)")
                 }
                 // Do not add HDR metadata properties for non-HEVC codecs
            }
        } else {
            // Standard SDR configuration
            if targetCodec == .hevc {
                profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel as String
            } else if targetCodec == .h264 {
                profileLevel = AVVideoProfileLevelH264HighAutoLevel
                compressionProperties[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
            }
            // Handle other codecs if needed
        }

        // Apply the determined profile level
        if let level = profileLevel {
            compressionProperties[AVVideoProfileLevelKey] = level
        }

        // --- Bitrate/Quality Settings (Same as before) ---
        if config.useExplicitBitrate {
            let minBitrate: Float = 50_000
            var effectiveBitrate = Float(config.videoBitrate)
            if effectiveBitrate > source.bitrate * 1.2 { effectiveBitrate = max(source.bitrate * 0.8, minBitrate) }
            effectiveBitrate = max(effectiveBitrate, minBitrate)
            compressionProperties[AVVideoAverageBitRateKey] = Int(effectiveBitrate)
        } else {
            compressionProperties[AVVideoQualityKey] = max(0.0, min(1.0, config.videoQuality))
        }

        // --- Final Output Settings ---
        return [
            AVVideoCodecKey: targetCodec.avCodecType,
            AVVideoWidthKey: targetSize.width,
            AVVideoHeightKey: targetSize.height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
    }


    /// Creates the audio output settings dictionary.
    private func createTargetAudioSettings(config: CompressionConfig, source: SourceAudioSettings?) throws -> [String: Any]? {
        guard let source = source else { return nil } // Return nil if no source audio track
        var audioChannelLayout = AudioChannelLayout(); memset(&audioChannelLayout, 0, MemoryLayout<AudioChannelLayout>.size)
        // Determine target channels (max 2, use config or source)
        let targetChannels = min(config.audioChannels ?? source.channels, 2)
        audioChannelLayout.mChannelLayoutTag = (targetChannels == 1) ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo

        // Clamp target sample rate within valid range
        let targetSampleRate = max(8000.0, min(192_000.0, Double(config.audioSampleRate)))

        // Determine and clamp effective bitrate
        let minBitrate: Float = 16_000
        var effectiveBitrate = Float(config.audioBitrate)
        if effectiveBitrate > source.bitrate * 1.2 { effectiveBitrate = max(source.bitrate * 0.8, minBitrate) }
        effectiveBitrate = max(effectiveBitrate, minBitrate)

        // Adjust codec if HE-AAC is selected with an unsupported sample rate
        var targetCodec = config.audioCodec
        if (targetCodec == .aac_he_v1 || targetCodec == .aac_he_v2) && targetSampleRate > 48000 {
            print("Warning: HE-AAC codec might not support sample rate \(targetSampleRate) Hz. Falling back to standard AAC.")
            targetCodec = .aac
        }

        // Final audio settings dictionary
        return [
            AVFormatIDKey: targetCodec.formatID,
            AVEncoderBitRateKey: Int(effectiveBitrate),
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVChannelLayoutKey: Data(bytes: &audioChannelLayout, count: MemoryLayout<AudioChannelLayout>.size)
        ]
    }

    // MARK: - Private Calculation & Analysis Helpers
    /// Calculates the target dimensions, ensuring even numbers and respecting aspect ratio.
    private func calculateTargetSize(scale: CGSize?, originalSize: CGSize, sourceTransform: CGAffineTransform) -> CGSize {
        // Determine if the video's visual orientation is rotated 90 degrees
        let isRotated = abs(sourceTransform.b) == 1.0 && abs(sourceTransform.c) == 1.0
        let visualOriginalSize = isRotated ? CGSize(width: originalSize.height, height: originalSize.width) : originalSize

        // If no scale is provided or both dimensions are -1, use original size
        guard let scale = scale, !(scale.width == -1 && scale.height == -1) else {
            // Return original size, rounded down to nearest even number
            return CGSize(width: floor(visualOriginalSize.width / 2.0) * 2.0, height: floor(visualOriginalSize.height / 2.0) * 2.0)
        }

        var targetWidth: CGFloat
        var targetHeight: CGFloat

        // Calculate target dimensions based on the scale config
        if scale.width != -1 && scale.height != -1 {
            // Specific width and height provided
            targetWidth = scale.width
            targetHeight = scale.height
        } else if scale.width != -1 {
            // Width provided, calculate height maintaining aspect ratio
            targetWidth = scale.width
            targetHeight = (visualOriginalSize.height / visualOriginalSize.width) * targetWidth
        } else { // scale.height != -1
            // Height provided, calculate width maintaining aspect ratio
            targetHeight = scale.height
            targetWidth = (visualOriginalSize.width / visualOriginalSize.height) * targetHeight
        }

        // Ensure dimensions are at least 2 and are even numbers (required by many codecs)
        targetWidth = max(2, floor(targetWidth / 2.0) * 2.0)
        targetHeight = max(2, floor(targetHeight / 2.0) * 2.0)

        return CGSize(width: targetWidth, height: targetHeight)
    }


    /// Basic content type detection based on heuristics.
    private func detectContentType(videoTrack: AVAssetTrack) -> VideoContentType {
        let fps = videoTrack.nominalFrameRate
        let size = videoTrack.naturalSize
        // Simple heuristics (can be expanded)
        if fps > 45 { return .highMotion }
        if fps < 24 { return .lowMotion }
        // Check common screen recording resolutions
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
            // Shorter keyframe interval for better seeking in fast action
            config.maxKeyFrameInterval = min(config.maxKeyFrameInterval, 15)
        case .lowMotion:
            // Longer keyframe interval can save space if motion is low
            config.maxKeyFrameInterval = max(config.maxKeyFrameInterval, 60)
        case .screencast:
            // Higher bitrate/quality often needed for sharp text/graphics
            if config.useExplicitBitrate { config.videoBitrate = max(config.videoBitrate, 2_500_000) }
            else { config.videoQuality = max(config.videoQuality, 0.75) }
            // Longer keyframe interval usually okay for screencasts
            config.maxKeyFrameInterval = max(config.maxKeyFrameInterval, 90)
        case .standard:
            break // No specific adjustments for standard content
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

        // Determine compressed video bitrate (use target if explicit, else estimate)
        let compressedVideoBitrate: Float
        if let compressionProps = targetVideoSettings[AVVideoCompressionPropertiesKey] as? [String: Any],
           let bitrate = compressionProps[AVVideoAverageBitRateKey] as? NSNumber {
            compressedVideoBitrate = bitrate.floatValue
        } else {
            // Estimate bitrate based on file size and duration if not explicitly set
            let duration = totalSourceTime.seconds // Use the loaded duration
            compressedVideoBitrate = (duration > 0) ? Float(compressedFileSize * 8) / Float(duration) : 0
        }

        // Get compressed audio bitrate from target settings
        let compressedAudioBitrate = (targetAudioSettings?[AVEncoderBitRateKey] as? NSNumber)?.floatValue

        // Calculate processing time using the stored start time
        let processingTime = Date().timeIntervalSince(self.isolationQueue.sync { self.startTime ?? Date() })

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
       print("  Config: \(config)") // Uses CompressionConfig's CustomStringConvertible
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
         Original Res: \(Int(analytics.originalDimensions.width))x\(Int(analytics.originalDimensions.height)) -> Compressed Res: \(Int(analytics.compressedDimensions.width))x\(Int(analytics.compressedDimensions.height))
         Original Bitrate: \(String(format: "%.0f kbps", analytics.originalVideoBitrate / 1000)) -> Compressed Bitrate: \(String(format: "%.0f kbps", analytics.compressedVideoBitrate / 1000))
       -------------------------------------
       """)
       #endif
    }
}

// MARK: - AVFileType Extension Helper (Internal)
extension AVFileType {
    /// Provides a best-effort filename extension for the AVFileType.
    var preferredFilenameExtension: String {
        if #available(iOS 14.0, macOS 11.0, *) {
            // Use UTType for modern OS versions
            return UTType(self.rawValue)?.preferredFilenameExtension ?? "tmp"
        } else {
            // Fallback for older OS versions using CoreServices
            guard let ext = UTTypeCopyPreferredTagWithClass(self as CFString, kUTTagClassFilenameExtension)?.takeRetainedValue() else {
                // Provide common fallbacks if UTType lookup fails
                switch self {
                    case .mov: return "mov"
                    case .mp4: return "mp4"
                    case .m4v: return "m4v"
                    case .m4a: return "m4a"
                    default: return "tmp" // Default fallback
                }
            }
            return ext as String
        }
    }
}
