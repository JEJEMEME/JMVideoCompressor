//
//  URL+FileSize.swift
//  JMVideoCompressor
//
//  Created by raykim on 4/24/25.
//

import Foundation

extension URL {
    /// Calculates the size of the file pointed to by the URL in megabytes (MB).
    /// Returns 0 if the URL is not a file URL or if the size cannot be determined.
    /// - Returns: File size in MB, or 0.0 on error.
    func sizePerMB() -> Double {
        guard isFileURL else {
            print("Warning: Attempted to get size for non-file URL: \(self)")
            return 0
        }
        do {
            // Get file attributes, specifically the size
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let size = attributes[.size] as? NSNumber {
                // Convert bytes to megabytes (using 1024*1024 for MiB)
                return size.doubleValue / (1024.0 * 1024.0)
            } else {
                print("Warning: Could not retrieve file size attribute for \(path)")
                return 0.0
            }
        } catch {
            // Log error if attributes cannot be retrieved
            print("Error getting file attributes for \(path): \(error)")
            return 0.0
        }
    }
}
