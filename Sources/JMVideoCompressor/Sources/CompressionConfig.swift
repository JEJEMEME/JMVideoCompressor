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
    case aac = 0x61616320       // kAudioFormatMPEG4AAC
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
                // A more robust check might involve trying to create a VTCompressionSession.
                // For simplicity, we check common export presets.
                let hevcPresets = [
                    AVAssetExportPresetHEVCHighestQuality,
                    AVAssetExportPresetHEVC1920x1080,
                    AVAssetExportPresetHEVC3840x2160
                ]
                // Check if *any* HEVC preset is available in the list of all presets.
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
    case standard       // General purpose video.
    case highMotion     // Content with lots of fast movement (e.g., sports, action).
    case lowMotion      // Content with little movement (e.g., interviews, presentations).
    case screencast     // Screen recordings, often with sharp text and graphics.
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
    public var videoCodec: VideoCodec = .h264 // Use the dedicated enum
    public var useExplicitBitrate: Bool = true
    public var videoBitrate: Int = 2_000_000
    public var videoQuality: Float = 0.7
    public var maxKeyFrameInterval: Int = 30
    public var fps: Float = 30
    public var scale: CGSize? = nil

    // MARK: - Audio Settings
    public var audioCodec: AudioCodecType = .aac
    public var audioBitrate: Int = 128_000
    public var audioSampleRate: Int = 44100
    public var audioChannels: Int? = nil

    // MARK: - Optimization Settings
    /// If `true`, attempts to detect video content type to adjust settings (e.g., keyframe interval). Default is `true`.
    public var contentAwareOptimization: Bool = true
    /// Preprocessing options to apply before encoding (currently placeholder).
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
        desc += "    Codec: \(videoCodec)\n" // Use enum description
        if useExplicitBitrate {
            desc += "    Bitrate: \(videoBitrate) bps\n"
        } else {
            desc += "    Quality: \(videoQuality)\n"
        }
        desc += "    Max Keyframe Interval: \(maxKeyFrameInterval)\n"
        desc += "    Target FPS: \(fps)\n"
        desc += "    Scale: \(scale?.debugDescription ?? "Original")\n"
        desc += "  Audio:\n"
        desc += "    Codec: \(audioCodec)\n"
        desc += "    Bitrate: \(audioBitrate) bps\n"
        desc += "    Sample Rate: \(audioSampleRate) Hz\n"
        desc += "    Channels: \(audioChannels?.description ?? "Source")\n"
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
