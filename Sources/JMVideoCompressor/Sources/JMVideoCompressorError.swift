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
    case invalidOutputPath(URL)
    case missingVideoTrack
    case readerInitializationFailed(Error?)
    case writerInitializationFailed(Error?)
    case compressionFailed(Error)
    case cancelled
    case underlyingError(Error)
    /// The selected video codec is not supported on the current device/OS.
    case codecNotSupported(VideoCodec) // Use the VideoCodec enum

    public var errorDescription: String? {
        switch self {
        case .invalidSourceURL(let url):
            return "Invalid source video URL: \(url.path)"
        case .invalidOutputPath(let url):
            return "Output path is not a valid directory or cannot be created: \(url.path)"
        case .missingVideoTrack:
            return "The source asset does not contain a video track."
        case .readerInitializationFailed(let underlyingError):
            let reason = underlyingError?.localizedDescription ?? "Unknown reason"
            return "Failed to initialize AVAssetReader. Reason: \(reason)"
        case .writerInitializationFailed(let underlyingError):
            let reason = underlyingError?.localizedDescription ?? "Unknown reason"
            return "Failed to initialize AVAssetWriter. Reason: \(reason)"
        case .compressionFailed(let error):
            return "Video compression failed: \(error.localizedDescription)"
        case .cancelled:
            return "Compression operation was cancelled."
        case .underlyingError(let error):
            return "An underlying system error occurred: \(error.localizedDescription)"
        case .codecNotSupported(let codec):
            return "Video codec \(codec) is not supported on this device/OS."
        }
    }
}
