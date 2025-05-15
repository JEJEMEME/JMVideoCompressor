//
//  CompressionConfig.swift
//  JMVideoCompressor
//
//  Created by raykim on 4/24/25.
//
import Foundation
import AVFoundation
import VideoToolbox // For codec check potentially

// MARK: - Top-Level Public Enums and Structs

/// Enum representing common audio codec types for configuration.
public enum AudioCodecType: UInt32 {
    case aac = 0x61616320      // kAudioFormatMPEG4AAC
    case aac_he_v1 = 0x61616368 // kAudioFormatMPEG4AAC_HE
    case aac_he_v2 = 0x61616370 // kAudioFormatMPEG4AAC_HE_V2

    public var formatID: FourCharCode { return self.rawValue }
}

/// Enum representing video codec choices.
public enum VideoCodec {
    case h264
    case hevc // H.265

    /// The corresponding AVFoundation video codec type.
    var avCodecType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc // Use .hevc (not .hevcWithAlpha unless alpha is needed)
        }
    }

    /// Checks if the codec (specifically hardware encoding) is likely supported on the current device/OS.
    /// Note: This is a heuristic check based on common presets. Actual support might vary.
    func isSupported() -> Bool {
        switch self {
        case .h264:
            return true // H.264 hardware encoding is widely supported.
        case .hevc:
            // Check if HEVC export presets exist, indicating likely hardware support.
            if #available(iOS 11.0, macOS 10.13, *) {
                let hevcPresets = [
                    AVAssetExportPresetHEVCHighestQuality,
                    AVAssetExportPresetHEVC1920x1080,
                    AVAssetExportPresetHEVC3840x2160
                ]
                let allPresets = AVAssetExportSession.allExportPresets()
                return !hevcPresets.filter { allPresets.contains($0) }.isEmpty
            } else {
                return false // HEVC support requires newer OS versions.
            }
        }
    }
}

/// Hints about the video content type to potentially optimize compression settings.
public enum VideoContentType {
    case standard      // General purpose video.
    case highMotion    // Content with lots of fast movement (e.g., sports, action).
    case lowMotion     // Content with little movement (e.g., interviews, presentations).
    case screencast    // Screen recordings, often with sharp text and graphics.
}

/// Options for video preprocessing (currently placeholders for future features).
public struct PreprocessingOptions {
    /// Level of noise reduction to apply before compression.
    public enum NoiseReductionLevel: Int {
        case none = 0
        case low = 1
        case medium = 2
        case high = 3
    }

    /// Noise reduction level. Higher values might improve compression but can soften details.
    public var noiseReduction: NoiseReductionLevel

    /// Placeholder for automatic brightness/contrast adjustment.
    public var autoLevels: Bool

    /// Default initializer.
    public init(noiseReduction: NoiseReductionLevel = .none, autoLevels: Bool = false) {
        self.noiseReduction = noiseReduction
        self.autoLevels = autoLevels
    }

    /// Flag indicating if any preprocessing is enabled.
    var isEnabled: Bool {
        return noiseReduction != .none || autoLevels
    }
}


/// Configuration for video and audio compression settings.
public struct CompressionConfig: CustomStringConvertible {
    // MARK: - Video Settings
    public var videoCodec: VideoCodec = .h264
    /// 비트레이트 계산 방식을 선택합니다. `true`면 `videoBitrate` 또는 `videoQuality`를 직접 사용하고, `false`면 `videoQuality`를 사용합니다.
    public var useExplicitBitrate: Bool = true
    /// 목표 비디오 비트레이트 (bps). `useExplicitBitrate`가 `true`일 때 사용됩니다. `useAdaptiveBitrate` 설정에 따라 최대값으로 사용될 수 있습니다.
    public var videoBitrate: Int = 2_000_000
    /// 목표 비디오 품질 (0.0 ~ 1.0). `useExplicitBitrate`가 `false`일 때 사용됩니다.
    public var videoQuality: Float = 0.7
    /// **(신규)** `true`로 설정하면, `videoBitrate`를 최대 한도로 사용하되, 원본 비디오 비트레이트가 더 낮으면 원본 비트레이트에 가깝게 압축합니다. `useExplicitBitrate`가 `true`일 때만 적용됩니다. (기본값: `false`)
    public var useAdaptiveBitrate: Bool = false
    public var maxKeyFrameInterval: Int = 30
    public var fps: Float = 30
    /// 구체적인 크기 조절 설정. `maxLongerDimension` 또는 `forceVisualEncodingDimensions`가 설정되면 영향을 받거나 무시될 수 있습니다.
    public var scale: CGSize? = nil
    /// 비디오의 긴 쪽(가로 또는 세로)의 최대 길이를 지정합니다. 설정되면 `scale` 값보다 우선 적용됩니다.
    public var maxLongerDimension: CGFloat? = nil
    /// `true`로 설정하면, 비디오를 시각적으로 보이는 방향과 크기로 직접 인코딩하고 회전 메타데이터를 제거합니다.
    public var forceVisualEncodingDimensions: Bool = false

    // MARK: - Audio Settings
    public var audioCodec: AudioCodecType = .aac
    public var audioBitrate: Int = 128_000
    public var audioSampleRate: Int = 44100
    public var audioChannels: Int? = nil

     /// 비디오 트리밍 시작 시간 (원본 비디오 기준). `nil`이면 처음부터 시작.
    public var trimStartTime: CMTime? = nil
    /// 비디오 트리밍 종료 시간 (원본 비디오 기준). `nil`이면 끝까지.
    public var trimEndTime: CMTime? = nil

    // MARK: - Optimization Settings
    public var contentAwareOptimization: Bool = true
    public var preprocessing: PreprocessingOptions = PreprocessingOptions()

    // MARK: - Output Settings
    public var fileType: AVFileType = .mp4
    public var outputURL: URL? = nil
    public var outputDirectory: URL? = nil

    // MARK: - Static Default Configuration
    public static let `default` = CompressionConfig()

    // MARK: - Initialization
    public init() {}

    // MARK: - CustomStringConvertible
    public var description: String {
        var desc = "CompressionConfig:\n"
        desc += "  Video:\n"
        desc += "    Codec: \(videoCodec)\n"
        if useExplicitBitrate {
            desc += "    Bitrate Mode: Explicit\n"
            desc += "    Target Max Bitrate: \(videoBitrate) bps\n"
            desc += "    Use Adaptive Bitrate: \(useAdaptiveBitrate)\n"
        } else {
            desc += "    Bitrate Mode: Quality Based\n"
            desc += "    Target Quality: \(videoQuality)\n"
        }
        desc += "    Max Keyframe Interval: \(maxKeyFrameInterval)\n"
        desc += "    Target FPS: \(fps)\n"
        if forceVisualEncodingDimensions {
            desc += "    Encoding Mode: Force Visual Dimensions (Overrides scale/maxLongerDimension for encoding size)\n"
            if let maxDim = maxLongerDimension {
                 desc += "    Max Longer Dimension Constraint: \(maxDim) (Applied before encoding)\n"
            } else if let scaleDesc = scale {
                 desc += "    Scale Constraint: \(scaleDesc.debugDescription) (Applied before encoding)\n"
            } else {
                 desc += "    Scale Constraint: Original (Applied before encoding)\n"
            }
        } else {
            desc += "    Encoding Mode: Preserve Original Orientation\n"
            if let maxDim = maxLongerDimension {
                 desc += "    Max Longer Dimension: \(maxDim) (Overrides scale)\n"
            } else if let scaleDesc = scale {
                 desc += "    Scale: \(scaleDesc.debugDescription)\n"
            } else {
                 desc += "    Scale: Original\n"
            }
        }
        desc += "  Audio:\n"
        desc += "    Codec: \(audioCodec)\n"
        desc += "    Bitrate: \(audioBitrate) bps\n"
        desc += "    Sample Rate: \(audioSampleRate) Hz\n"
        desc += "    Channels: \(audioChannels?.description ?? "Source")\n"

        // 트리밍 설정 설명 추가
        desc += "  Trimming:\n"
        if let startTime = trimStartTime {
            desc += "    Start Time: \(CMTimeGetSeconds(startTime))s\n"
        } else {
            desc += "    Start Time: Beginning\n"
        }
        if let endTime = trimEndTime {
            desc += "    End Time: \(CMTimeGetSeconds(endTime))s\n"
        } else {
            desc += "    End Time: End of video\n"
        }

        desc += "  Optimization:\n"
        desc += "    Content Aware: \(contentAwareOptimization)\n"
        desc += "    Preprocessing Noise: \(preprocessing.noiseReduction), AutoLevels: \(preprocessing.autoLevels)\n"
        desc += "  Output:\n"
        desc += "    File Type: \(fileType.rawValue)\n"
        if let url = outputURL {
            desc += "    Output URL: \(url.path)\n"
        } else {
            desc += "    Output Directory: \(outputDirectory?.path ?? "System Temp")\n"
        }
        return desc
    }
}
