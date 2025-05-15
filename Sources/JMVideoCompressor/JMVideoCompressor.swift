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
        // 기본 프리셋에서는 적응형 비트레이트를 사용하지 않음 (기존 동작 유지)
        // config.useAdaptiveBitrate = false
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
    private var totalSourceTime: CMTime = .zero // 압축할 (트리밍된) 세그먼트의 총 시간
    private var effectiveTrimStartTime: CMTime = .zero // 진행률 계산을 위한 트리밍 시작 시간 저장

    // MARK: - Initialization
    public init() {}

    // MARK: - Public API
    public func compressVideo(
        _ url: URL,
        quality: VideoQuality = .mediumQuality,
        frameReducer: VideoFrameReducer = ReduceFrameEvenlySpaced(),
        outputDirectory: URL? = nil,
        progressHandler: ((Float) -> Void)? = nil
    ) async throws -> (url: URL, analytics: CompressionAnalytics) {
        var config = quality.defaultConfig
        if let explicitOutputDir = outputDirectory {
            config.outputDirectory = explicitOutputDir
            config.outputURL = nil
        }
        // 이 메서드는 CompressionConfig의 trimStartTime, trimEndTime을 사용하지 않음.
        // 트리밍을 원하면 config를 직접 전달하는 compressVideo 메서드를 사용해야 함.
        return try await compressVideo(url, config: config, frameReducer: frameReducer, progressHandler: progressHandler)
    }

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
             self.effectiveTrimStartTime = .zero // 초기화
        }

        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { throw JMVideoCompressorError.invalidSourceURL(url) }
        guard config.videoCodec.isSupported() else { throw JMVideoCompressorError.codecNotSupported(config.videoCodec) }

        let sourceAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let originalAssetDuration = try await sourceAsset.load(.duration)

        // --- Trimming Logic ---
        var effectiveTimeRange = CMTimeRange(start: .zero, duration: originalAssetDuration)
        var isTrimmed = false

        let trimStart = config.trimStartTime
        let trimEnd = config.trimEndTime

        if let start = trimStart, let end = trimEnd {
            guard CMTimeCompare(start, end) == -1, // start < end
                  CMTimeCompare(start, .zero) >= 0, // start >= 0
                  CMTimeCompare(end, originalAssetDuration) <= 0 // end <= originalAssetDuration
            else {
                throw JMVideoCompressorError.invalidTrimTimes("Trim start time (\(CMTimeGetSeconds(start))s) must be before trim end time (\(CMTimeGetSeconds(end))s) and both must be within asset duration (0-\(CMTimeGetSeconds(originalAssetDuration))s).")
            }
            effectiveTimeRange = CMTimeRangeFromTimeToTime(start: start, end: end)
            isTrimmed = true
        } else if let start = trimStart {
            guard CMTimeCompare(start, .zero) >= 0, // start >= 0
                  CMTimeCompare(start, originalAssetDuration) == -1 // start < originalAssetDuration
            else {
                throw JMVideoCompressorError.invalidTrimTimes("Trim start time (\(CMTimeGetSeconds(start))s) must be within asset duration (0-\(CMTimeGetSeconds(originalAssetDuration))s).")
            }
            effectiveTimeRange = CMTimeRange(start: start, duration: CMTimeSubtract(originalAssetDuration, start))
            isTrimmed = true
        } else if let end = trimEnd {
            guard CMTimeCompare(end, .zero) == 1, // end > 0
                  CMTimeCompare(end, originalAssetDuration) <= 0 // end <= originalAssetDuration
            else {
                throw JMVideoCompressorError.invalidTrimTimes("Trim end time (\(CMTimeGetSeconds(end))s) must be greater than zero and within asset duration (0-\(CMTimeGetSeconds(originalAssetDuration))s).")
            }
            effectiveTimeRange = CMTimeRange(start: .zero, duration: end)
            isTrimmed = true
        }
        
        self.totalSourceTime = effectiveTimeRange.duration // 진행률 및 분석에 사용될 총 시간
        self.effectiveTrimStartTime = effectiveTimeRange.start // 진행률 계산 시 PTS 오프셋으로 사용
        if isTrimmed {
            print("JMVideoCompressor: Applying trim. Effective range: \(CMTimeGetSeconds(effectiveTimeRange.start))s - \(CMTimeGetSeconds(CMTimeAdd(effectiveTimeRange.start, effectiveTimeRange.duration)))s. Duration: \(CMTimeGetSeconds(effectiveTimeRange.duration))s")
        }
        // --- End Trimming Logic ---


        guard let sourceVideoTrack = try? await sourceAsset.loadTracks(withMediaType: .video).first else { throw JMVideoCompressorError.missingVideoTrack }
        let sourceAudioTrack = try? await sourceAsset.loadTracks(withMediaType: .audio).first

        let sourceVideoSettings = try await loadSourceVideoSettings(track: sourceVideoTrack)
        let sourceAudioSettings = try await loadSourceAudioSettings(track: sourceAudioTrack)

        let contentType = config.contentAwareOptimization ? detectContentType(videoTrack: sourceVideoTrack) : .standard
        var effectiveConfig = config
        applyContentAwareOptimizations(to: &effectiveConfig, contentType: contentType)

        let targetFPS = min(effectiveConfig.fps, sourceVideoSettings.fps)
        let needsFrameReduction = targetFPS < sourceVideoSettings.fps

        let (targetVideoSettings, finalTransform) = try createTargetVideoSettings(config: effectiveConfig, source: sourceVideoSettings)
        let targetAudioSettings = try createTargetAudioSettings(config: effectiveConfig, source: sourceAudioSettings)

        let outputURL = try determineOutputURL(config: effectiveConfig, sourceURL: url)

        let localReader: AVAssetReader
        let localWriter: AVAssetWriter
        defer {
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
        
        // 트리밍 설정 적용
        if isTrimmed || CMTimeCompare(effectiveTimeRange.start, .zero) != 0 || CMTimeCompare(effectiveTimeRange.duration, originalAssetDuration) != 0 {
            localReader.timeRange = effectiveTimeRange
        }

        do { localWriter = try AVAssetWriter(url: outputURL, fileType: effectiveConfig.fileType) } catch { throw JMVideoCompressorError.writerInitializationFailed(error) }
        localWriter.shouldOptimizeForNetworkUse = true
        isolationQueue.sync { self.assetReader = localReader; self.assetWriter = localWriter }

        let videoOutputSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] // 실제 지원하는 포맷으로 변경 필요할 수 있음
        let videoOutput = AVAssetReaderTrackOutput(track: sourceVideoTrack, outputSettings: videoOutputSettings)
        videoOutput.alwaysCopiesSampleData = false
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

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: targetVideoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = finalTransform
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

        logCompressionStart(sourceURL: url, outputURL: outputURL, config: effectiveConfig)
        guard localReader.startReading() else {
            if let error = localReader.error { throw JMVideoCompressorError.readerInitializationFailed(error) }
            throw JMVideoCompressorError.readerInitializationFailed(nil)
        }
        guard localWriter.startWriting() else {
            if let error = localWriter.error { throw JMVideoCompressorError.writerInitializationFailed(error) }
            throw JMVideoCompressorError.writerInitializationFailed(nil)
        }
        // 세션 시작 시간을 트리밍된 세그먼트의 시작 시간으로 설정
        localWriter.startSession(atSourceTime: effectiveTimeRange.start)


        let frameIndexesToKeep = needsFrameReduction ? frameReducer.reduce(originalFPS: sourceVideoSettings.fps, to: targetFPS, with: Float(self.totalSourceTime.seconds)) : nil
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
                         progressHandler: nil // 오디오 트랙은 별도 진행률 보고 안 함
                     )
                 }
             }
             try await group.waitForAll()
        }

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
                    targetVideoSettings: targetVideoSettings, targetAudioSettings: targetAudioSettings,
                    // totalSourceTime은 이미 멤버 변수로 트리밍된 길이를 가짐
                    trimmedDuration: self.totalSourceTime
                )
                logCompressionEnd(outputURL: outputURL, analytics: analytics)
                return (outputURL, analytics)
            case .failed:
                 try? FileManager.default.removeItem(at: outputURL)
                 throw JMVideoCompressorError.compressionFailed(localWriter.error)
             case .cancelled:
                  try? FileManager.default.removeItem(at: outputURL)
                  throw JMVideoCompressorError.cancelled
             default:
                  try? FileManager.default.removeItem(at: outputURL)
                  throw JMVideoCompressorError.compressionFailed(NSError(domain: "JMVideoCompressor", code: -5, userInfo: [NSLocalizedDescriptionKey: "Writer finished with unexpected status: \(localWriter.status.rawValue)"]))
            }
        }
    }

    public func cancel() {
        isolationQueue.sync {
            guard !self.cancelled else { return }
            self.cancelled = true
            // 실제 취소 로직은 processTrack 내부 및 reader/writer 상태 확인으로 처리됨
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
    ) async throws {
        var frameCounter: Int = 0
        var keepFrameIndicesIterator = frameIndexesToKeep?.makeIterator()
        var nextIndexToKeep: Int? = keepFrameIndicesIterator?.next()
        var lastProgressUpdate: Float = -1.0

        // self.effectiveTrimStartTime 을 사용하여 PTS 조정
        let trimOffsetTime = self.effectiveTrimStartTime

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
                     // 루프 시작 시 취소 상태 확인
                    if self.cancelled {
                        assetWriterInput.markAsFinished() // writer input을 완료 처리
                        safeResume(throwing: JMVideoCompressorError.cancelled)
                        return
                    }

                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        // 샘플 버퍼가 더 이상 없으면 완료
                        assetWriterInput.markAsFinished()
                        if let handler = progressHandler, lastProgressUpdate < 1.0, self.totalSourceTime.seconds > 0 {
                             DispatchQueue.main.async { handler(1.0) } // 마지막으로 100% 업데이트
                        }
                        safeResume()
                        return
                    }

                    var shouldAppend = true
                    if frameIndexesToKeep != nil { // 비디오 트랙이고 프레임 감소가 필요한 경우
                        if let targetIndex = nextIndexToKeep {
                            if frameCounter == targetIndex {
                                nextIndexToKeep = keepFrameIndicesIterator?.next()
                            } else {
                                shouldAppend = false
                            }
                        } else { // 모든 필요한 프레임을 이미 처리함
                            shouldAppend = false
                        }
                        frameCounter += 1
                    }

                    if shouldAppend {
                        // 진행률 업데이트 (비디오 트랙에 대해서만)
                        if assetWriterInput.mediaType == .video, let handler = progressHandler, self.totalSourceTime.seconds > 0 {
                            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                            if pts.isValid {
                                // PTS를 트리밍된 세그먼트의 시작 시간 기준으로 조정
                                let relativePts = CMTimeSubtract(pts, trimOffsetTime)
                                let progress = Float(CMTimeGetSeconds(relativePts) / CMTimeGetSeconds(self.totalSourceTime))
                                
                                // 진행률이 실제로 변경되었을 때만 업데이트 (0.01 단위) 또는 완료 시
                                if progress >= lastProgressUpdate + 0.01 || (progress >= 1.0 && lastProgressUpdate < 1.0) {
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
                }
                // 루프 종료 후에도 isReadyForMoreMediaData가 false가 될 수 있으므로, 여기서 완료를 알리지 않음.
                // 샘플이 고갈되거나(nil 반환) 취소될 때 완료를 알림.
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
        } else {
            let baseDirectory = config.outputDirectory ?? fileManager.temporaryDirectory
            let uniqueFilename = UUID().uuidString + "." + config.fileType.preferredFilenameExtension
            finalURL = baseDirectory.appendingPathComponent(uniqueFilename)
            directoryToCheck = baseDirectory
        }

        if !fileManager.fileExists(atPath: directoryToCheck.path) {
            do { try fileManager.createDirectory(at: directoryToCheck, withIntermediateDirectories: true, attributes: nil) }
            catch { throw JMVideoCompressorError.invalidOutputPath(directoryToCheck) }
        }
        
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryToCheck.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw JMVideoCompressorError.invalidOutputPath(directoryToCheck)
        }
        try? fileManager.removeItem(at: finalURL) // 기존 파일 삭제
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
        } catch { print("Warning: Error loading format descriptions: \(error.localizedDescription)") }

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
        
        do {
            if let formatDesc = try await formatDescriptions.first,
               let streamDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee {
                sampleRate = Float(streamDesc.mSampleRate); channels = Int(streamDesc.mChannelsPerFrame); formatID = streamDesc.mFormatID
            }
        } catch {
             print("Warning: Could not load audio format descriptions. Using defaults. Error: \(error.localizedDescription)")
        }
        return try await SourceAudioSettings(bitrate: bitrate, sampleRate: sampleRate, channels: channels, formatID: formatID)
    }

    private func createTargetVideoSettings(config: CompressionConfig, source: SourceVideoSettings) throws -> (settings: [String: Any], transform: CGAffineTransform) {
        let targetVisualSize = calculateTargetSize(
            scale: config.scale,
            maxLongerDimension: config.maxLongerDimension,
            originalSize: source.size,
            sourceTransform: source.transform
        )

        let finalEncodingWidth: CGFloat
        let finalEncodingHeight: CGFloat
        let finalTransform: CGAffineTransform
        let sourceIsRotated = abs(source.transform.b) == 1.0 && abs(source.transform.c) == 1.0

        if config.forceVisualEncodingDimensions {
            finalEncodingWidth = targetVisualSize.width
            finalEncodingHeight = targetVisualSize.height
            finalTransform = .identity
        } else {
            if sourceIsRotated {
                finalEncodingWidth = targetVisualSize.height
                finalEncodingHeight = targetVisualSize.width
            } else {
                finalEncodingWidth = targetVisualSize.width
                finalEncodingHeight = targetVisualSize.height
            }
            finalTransform = source.transform
        }

        var compressionProperties: [String: Any] = [
            AVVideoMaxKeyFrameIntervalKey: config.maxKeyFrameInterval,
            AVVideoAllowFrameReorderingKey: false, // 일반적으로 false로 설정
        ]

        if config.useExplicitBitrate {
            let minBitrate: Float = 50_000
            var targetBitrate = Float(config.videoBitrate)

            if config.useAdaptiveBitrate && source.bitrate > 0 {
                if source.bitrate < targetBitrate {
                    targetBitrate = max(source.bitrate, minBitrate)
                } else {
                    // 기존 로직 유지 또는 수정 가능. 여기서는 사용자가 지정한 비트레이트가 소스보다 낮으면 그대로 사용.
                    // 만약 사용자가 지정한 비트레이트가 소스보다 너무 높다면, 소스 비트레이트 근처로 제한할 수 있음.
                    // 예: if targetBitrate > source.bitrate * 1.2 { targetBitrate = source.bitrate }
                }
            } else if source.bitrate > 0 && targetBitrate > source.bitrate * 1.2 { // 적응형 비트레이트 false일 때
                 targetBitrate = max(source.bitrate * 0.8, minBitrate) // 너무 높은 목표 비트레이트 방지
            }
            
            let effectiveBitrate = max(targetBitrate, minBitrate)
            compressionProperties[AVVideoAverageBitRateKey] = Int(effectiveBitrate)
        } else {
            compressionProperties[AVVideoQualityKey] = max(0.0, min(1.0, config.videoQuality))
        }
        
        let isHDR: Bool = (source.colorPrimaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) ||
                           source.transferFunction == "ITU_R_2100_PQ" || // kCMFormatDescriptionTransferFunction_ITU_R_2100_PQ
                           source.transferFunction == "ITU_R_2100_HLG")  // kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG

        let targetCodec = config.videoCodec
        var profileLevel: String? = nil
        if isHDR {
            if targetCodec == .hevc {
                profileLevel = kVTProfileLevel_HEVC_Main10_AutoLevel as String
                if #available(iOS 16.0, macOS 13.0, *) {
                    compressionProperties[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_Auto
                } else { print("Warning: HDR metadata insertion not available on this OS version for HEVC.") }
            } else {
                 print("Warning: HDR content detected, but H.264 codec selected. HDR information might be lost or improperly handled. Consider HEVC for HDR.")
                 profileLevel = AVVideoProfileLevelH264HighAutoLevel
                 compressionProperties[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
            }
        } else { // SDR
            if targetCodec == .hevc { profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel as String }
            else if targetCodec == .h264 {
                profileLevel = AVVideoProfileLevelH264HighAutoLevel
                compressionProperties[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
            }
        }
        if let level = profileLevel { compressionProperties[AVVideoProfileLevelKey] = level }

        var settings: [String: Any] = [
            AVVideoCodecKey: targetCodec.avCodecType,
            AVVideoWidthKey: finalEncodingWidth,
            AVVideoHeightKey: finalEncodingHeight,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        
        // 컬러 프로퍼티 설정 (소스에서 최대한 가져오도록)
        var colorProperties: [String: String] = [:]
        if let primaries = source.colorPrimaries { colorProperties[AVVideoColorPrimariesKey] = primaries }
        if let transfer = source.transferFunction { colorProperties[AVVideoTransferFunctionKey] = transfer }
        if let matrix = source.yCbCrMatrix { colorProperties[AVVideoYCbCrMatrixKey] = matrix }
        if !colorProperties.isEmpty {
            settings[AVVideoColorPropertiesKey] = colorProperties
        }


        return (settings, finalTransform)
    }

    private func createTargetAudioSettings(config: CompressionConfig, source: SourceAudioSettings?) throws -> [String: Any]? {
        guard let sourceAudio = source else { return nil } // 원본 오디오 트랙 없으면 nil 반환
        // 사용자가 오디오 비트레이트를 0으로 설정하여 오디오 제거를 의도한 경우
        if config.audioBitrate <= 0 {
            print("Info: Audio bitrate is 0, audio track will be removed.")
            return nil
        }

        var audioChannelLayout = AudioChannelLayout(); memset(&audioChannelLayout, 0, MemoryLayout<AudioChannelLayout>.size)
        let targetChannels = min(config.audioChannels ?? sourceAudio.channels, 2) // 최대 2채널 (스테레오)
        audioChannelLayout.mChannelLayoutTag = (targetChannels == 1) ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo

        let targetSampleRate = max(8000.0, min(Double(config.audioSampleRate), Double(sourceAudio.sampleRate))) // 원본 샘플레이트 초과하지 않도록
        
        let minBitrate: Float = 16_000
        var effectiveBitrate = Float(config.audioBitrate)
        if sourceAudio.bitrate > 0 && effectiveBitrate > sourceAudio.bitrate * 1.2 {
             effectiveBitrate = max(sourceAudio.bitrate * 0.8, minBitrate)
        }
        effectiveBitrate = max(effectiveBitrate, minBitrate)

        var targetCodec = config.audioCodec
        if (targetCodec == .aac_he_v1 || targetCodec == .aac_he_v2) && targetSampleRate > 48000 {
            print("Warning: HE-AAC is typically used with sample rates <= 48kHz. Forcing AAC-LC for \(targetSampleRate)Hz.")
            targetCodec = .aac
        }

        return [
            AVFormatIDKey: targetCodec.formatID,
            AVEncoderBitRateKey: Int(effectiveBitrate),
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVChannelLayoutKey: Data(bytes: &audioChannelLayout, count: MemoryLayout<AudioChannelLayout>.size)
        ]
    }

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
        } else if let scale = scale, !(scale.width == -1 && scale.height == -1) { // scale이 (-1, -1)이 아닌 경우
             if scale.width != -1 && scale.height != -1 { // 너비와 높이 모두 지정
                 targetVisualWidth = scale.width
                 targetVisualHeight = scale.height
             } else if scale.width != -1 { // 너비만 지정
                 targetVisualWidth = scale.width
                 targetVisualHeight = (visualOriginalSize.height / visualOriginalSize.width) * targetVisualWidth
             } else { // 높이만 지정 (scale.height != -1)
                 targetVisualHeight = scale.height
                 targetVisualWidth = (visualOriginalSize.width / visualOriginalSize.height) * targetVisualHeight
             }
        }
        // 너비와 높이가 2의 배수가 되도록 조정 (많은 코덱에서 권장)
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
        targetVideoSettings: [String: Any], targetAudioSettings: [String: Any]?,
        trimmedDuration: CMTime // 트리밍된 실제 영상 길이
    ) async throws -> CompressionAnalytics {
        let originalFileSize = getFileSize(url: originalURL)
        let compressedFileSize = getFileSize(url: compressedURL)
        let ratio = (compressedFileSize > 0 && originalFileSize > 0) ? Float(originalFileSize) / Float(compressedFileSize) : 0 // 0으로 나누기 방지
        
        let compressedDimensions = CGSize(
            width: targetVideoSettings[AVVideoWidthKey] as? CGFloat ?? 0,
            height: targetVideoSettings[AVVideoHeightKey] as? CGFloat ?? 0
        )
        
        let compressedVideoBitrate: Float
        let durationSeconds = CMTimeGetSeconds(trimmedDuration) // totalSourceTime이 트리밍된 길이를 가짐
        if durationSeconds > 0 {
            if let props = targetVideoSettings[AVVideoCompressionPropertiesKey] as? [String: Any],
               let brKey = props[AVVideoAverageBitRateKey] as? NSNumber {
                compressedVideoBitrate = brKey.floatValue
            } else {
                // 비트레이트 키가 없는 경우 (예: 품질 기반 압축), 파일 크기와 길이로 추정
                compressedVideoBitrate = Float(compressedFileSize * 8) / Float(durationSeconds)
            }
        } else {
            compressedVideoBitrate = 0
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
        catch { print("Warning: Could not get file size for \(url.path). Error: \(error.localizedDescription)"); return 0 }
    }

    private func logCompressionStart(sourceURL: URL, outputURL: URL, config: CompressionConfig) {
       #if DEBUG
       print("-------------------------------------")
       print("JMVideoCompressor: Starting compression...")
       let sourceSizeMB = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.doubleValue ?? 0.0 / (1024.0*1024.0)
       print("  Source: \(sourceURL.lastPathComponent) (\(String(format: "%.2f MB", sourceSizeMB)))")
       print("  Output: \(outputURL.lastPathComponent)")
       print("  Config: \(config.description)") // config.description 사용
       if let startTime = config.trimStartTime, let endTime = config.trimEndTime {
           print("  Trimming from \(CMTimeGetSeconds(startTime))s to \(CMTimeGetSeconds(endTime))s")
       } else if let startTime = config.trimStartTime {
           print("  Trimming from \(CMTimeGetSeconds(startTime))s to end")
       } else if let endTime = config.trimEndTime {
           print("  Trimming from start to \(CMTimeGetSeconds(endTime))s")
       }
       print("-------------------------------------")
       #endif
    }

    private func logCompressionEnd(outputURL: URL, analytics: CompressionAnalytics) {
       #if DEBUG
       print("""
       -------------------------------------
       JMVideoCompressor: Compression finished ✅
        Output: \(outputURL.lastPathComponent)
        Original File Size: \(String(format: "%.2f MB", Double(analytics.originalFileSize) / (1024*1024)))
        Compressed File Size: \(String(format: "%.2f MB", Double(analytics.compressedFileSize) / (1024*1024)))
        Ratio: \(String(format: "%.2f : 1", analytics.compressionRatio))
        Time Elapsed: \(String(format: "%.2f seconds", analytics.processingTime))
        Original Visual Res: \(Int(analytics.originalDimensions.width))x\(Int(analytics.originalDimensions.height)) -> Compressed Encoded Res: \(Int(analytics.compressedDimensions.width))x\(Int(analytics.compressedDimensions.height))
        Original Video Bitrate (Full Track): \(String(format: "%.0f kbps", analytics.originalVideoBitrate / 1000)) -> Compressed Video Bitrate (Trimmed Segment): \(String(format: "%.0f kbps", analytics.compressedVideoBitrate / 1000))
        (Trimmed duration for compression: \(String(format: "%.2f seconds", CMTimeGetSeconds(self.totalSourceTime))))
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
