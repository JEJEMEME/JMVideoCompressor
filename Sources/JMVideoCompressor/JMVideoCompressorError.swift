//
//  JMVideoCompressorError.swift
//  JMVideoCompressor
//
//  Created by raykim on 4/24/25.
//

import Foundation

/// Errors that can occur during video compression.
public enum JMVideoCompressorError: Error, LocalizedError {
    case invalidSourceURL(URL)
    case codecNotSupported(VideoCodec)
    case missingVideoTrack
    case readerInitializationFailed(Error?)
    case writerInitializationFailed(Error?)
    case compressionFailed(Error?)
    case cancelled
    case invalidOutputPath(URL)
    case invalidTrimTimes(String) // 새로운 에러 케이스

    public var errorDescription: String? {
        switch self {
        case .invalidSourceURL(let url): return "Invalid source URL: \(url.path)"
        case .codecNotSupported(let codec): return "Video codec not supported: \(codec)"
        case .missingVideoTrack: return "Source asset is missing a video track."
        case .readerInitializationFailed(let err): return "Failed to initialize AVAssetReader. \(err?.localizedDescription ?? "")"
        case .writerInitializationFailed(let err): return "Failed to initialize AVAssetWriter. \(err?.localizedDescription ?? "")"
        case .compressionFailed(let err): return "Video compression failed. \(err?.localizedDescription ?? "")"
        case .cancelled: return "Video compression cancelled by user."
        case .invalidOutputPath(let url): return "Invalid output path or directory: \(url.path)"
        case .invalidTrimTimes(let message): return "Invalid trim times: \(message)"
        }
    }
}
