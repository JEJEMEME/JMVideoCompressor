# JMVideoCompressor

[![Swift Package Manager](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
A Swift library designed for efficient video compression on iOS and macOS using AVFoundation. It offers both simple presets and granular custom configurations.

## Features

* **Easy Presets:** Compress videos using predefined quality settings (`.lowQuality`, `.mediumQuality`, `.highQuality`, `.socialMedia`, `.messaging`).
* **Custom Configuration:** Fine-tune compression with `CompressionConfig`, controlling codecs (H.264, HEVC), bitrate/quality, resolution scaling, frame rate, audio settings, and more.
* **Codec Support:** Compress using H.264 or HEVC (H.265), with checks for HEVC hardware support.
* **HDR Support:** Aims to preserve High Dynamic Range (HDR) metadata (like HLG, PQ) when compressing to HEVC. Automatic HDR metadata insertion is supported on iOS 16+/macOS 13+. (See Requirements 섹션의 iOS 버전 관련 참고 사항).
* **Frame Rate Reduction:** Reduce video frame rate using different strategies (e.g., evenly spaced, random selection).
* **Asynchronous API:** Modern `async/await` syntax for non-blocking compression tasks.
* **Progress Reporting:** Monitor compression progress via a closure.
* **Cancellation:** Support for cancelling ongoing compression operations.
* **Detailed Analytics:** Get insights into the compression results, including file sizes, compression ratio, processing time, dimensions, and bitrates.
* **Output Control:** Specify a target output directory or a precise output file URL.

## Requirements

* iOS 15.0+ (Note: HEVC HDR metadata insertion is automatically handled on iOS 16.0+ and macOS 13.0+. On older versions, HEVC compression is available, but HDR metadata might not be preserved correctly.)
* macOS 13.0+
* Xcode 14.0+ (or a version compatible with Swift 5.7+)
* Swift 5.7+

## Installation

You can add `JMVideoCompressor` to your project using the Swift Package Manager.

**Using Xcode:**

1.  Go to **File** > **Swift Packages** > **Add Package Dependency...**
2.  Enter the repository URL: `https://github.com/JEJEMEME/JMVideoCompressor.git`
3.  Choose the version rules (e.g., "Up to Next Major" starting from `1.0.0`).
4.  Select the `JMVideoCompressor` library for your target.

**Using `Package.swift`:**

Add the following dependency to your `Package.swift` file:

```swift
// swift-tools-version:5.7
import PackageDescription

let package = Package(
    // ... other package configurations
    dependencies: [
        .package(url: "[https://github.com/JEJEMEME/JMVideoCompressor.git](https://github.com/JEJEMEME/JMVideoCompressor.git)", from: "1.0.0") // Replace "1.0.0" with the desired version
    ],
    targets: [
        .target(
            name: "YourTargetName",
            dependencies: ["JMVideoCompressor"]
            // ... other target configurations
        ),
        // ... other targets
    ]
)
```

Then, import the module in your Swift files:
`import JMVideoCompressor`

## Usage

Here's how to use `JMVideoCompressor`:

**1. Import the Library**

```swift
import JMVideoCompressor
import AVFoundation // Often needed for URLs
```

**2. Initialize the Compressor**

```swift
let compressor = JMVideoCompressor()
let sourceVideoURL = URL(fileURLWithPath: "/path/to/your/input/video.mp4") // Replace with your video URL
```

**3. Basic Compression using Presets**

Use predefined `VideoQuality` presets for quick compression. The output file will be placed in a temporary directory by default. To specify an output location, modify the `CompressionConfig` obtained from the preset.

```swift
do {
    // Get the default config for the desired quality
    var config = VideoQuality.mediumQuality.defaultConfig

    // Define where the compressed file should go
    let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CompressedVideos")
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    config.outputDirectory = outputDirectory // Set output directory in the config

    // Alternatively, set a specific output URL
    // let specificOutputURL = outputDirectory.appendingPathComponent("my_medium_video.mp4")
    // config.outputURL = specificOutputURL // If outputURL is set, outputDirectory is ignored

    print("Starting compression with medium quality preset...")

    // Compress with progress reporting using the modified config
    let result = try await compressor.compressVideo(
        sourceVideoURL,
        // Note: The 'quality' parameter provides the initial config,
        // but we pass our modified 'config' object for compression.
        config: config, // Pass the config with the output path set
        progressHandler: { progress in
            DispatchQueue.main.async {
                 print("Compression Progress: \(String(format: "%.0f%%", progress * 100))")
            }
        }
    )

    print("Compression successful!")
    print("Output URL: \(result.url.path)")
    print("Original Size: \(String(format: "%.2f MB", Double(result.analytics.originalFileSize) / (1024*1024)))")
    print("Compressed Size: \(String(format: "%.2f MB", Double(result.analytics.compressedFileSize) / (1024*1024)))")
    print("Ratio: \(String(format: "%.2f : 1", result.analytics.compressionRatio))")
    print("Time: \(String(format: "%.2f s", result.analytics.processingTime))")

} catch let error as JMVideoCompressorError {
    print("Compression failed with error: \(error.localizedDescription)")
    // Handle specific JMVideoCompressorError cases if needed
} catch {
    print("An unexpected error occurred: \(error.localizedDescription)")
}
```

**4. Compression with Custom Configuration**

For more control, use `CompressionConfig`. Set the output path *within* the config object (`outputURL` for a specific file or `outputDirectory` for a directory).

```swift
do {
    var customConfig = CompressionConfig.default // Start with default settings

    // --- Video Settings ---
    customConfig.videoCodec = .hevc // Use HEVC if supported
    customConfig.useExplicitBitrate = true // Use bitrate instead of quality factor
    customConfig.videoBitrate = 1_500_000 // 1.5 Mbps
    customConfig.useAdaptiveBitrate = true // Optional: Cap bitrate near source if source is lower
    customConfig.maxLongerDimension = 1280 // Set max length of the longer side to 1280p, maintain aspect ratio
    customConfig.fps = 24 // Target 24 FPS (will use frame reduction if source > 24)
    customConfig.forceVisualEncodingDimensions = true // Optional: Encode rotated videos with visual dimensions (e.g., 1080x1920)

    // --- Audio Settings ---
    customConfig.audioCodec = .aac_he_v1 // High-Efficiency AAC
    customConfig.audioBitrate = 64_000 // 64 kbps
    customConfig.audioChannels = 1 // Mono audio

    // --- Output Settings ---
    let customOutputURL = FileManager.default.temporaryDirectory.appendingPathComponent("custom_compressed_\(UUID().uuidString).mp4")
    customConfig.outputURL = customOutputURL // Specify the exact output file URL
    // Note: If outputURL is set, outputDirectory is ignored.

    print("Starting compression with custom configuration...")
    let result = try await compressor.compressVideo(
        sourceVideoURL,
        config: customConfig,
        // Optional: Provide a frame reducer strategy
        // frameReducer: ReduceFrameRandomly(),
        progressHandler: { progress in
            DispatchQueue.main.async {
                print("Custom Compression Progress: \(String(format: "%.0f%%", progress * 100))")
            }
        }
    )

    print("Custom compression successful!")
    print("Output URL: \(result.url.path)")
    // Access analytics as in the previous example...
    print("Analytics: \(result.analytics)")

} catch JMVideoCompressorError.codecNotSupported(let codec) {
     print("Error: The selected codec (\(codec)) is not supported on this device.")
} catch let error as JMVideoCompressorError {
     print("Compression failed with error: \(error.localizedDescription)")
} catch {
     print("An unexpected error occurred: \(error.localizedDescription)")
}
```

**5. Cancelling Compression**

You can cancel an ongoing compression task by calling the `cancel()` method on the `JMVideoCompressor` instance. This is typically done from a different task or thread (e.g., user tapping a cancel button).

```swift
// Somewhere in your code where compression is running:
let compressionTask = Task {
    do {
        let result = try await compressor.compressVideo(sourceVideoURL, quality: .mediumQuality)
        // Handle success...
    } catch JMVideoCompressorError.cancelled {
        print("Compression was cancelled by the user.")
    } catch {
        // Handle other errors...
    }
}

// Elsewhere (e.g., button action):
func userTappedCancelButton() {
    compressor.cancel() // Request cancellation
    // Optionally: compressionTask.cancel() // If you need to cancel the Swift Task itself
}
```

## Configuration (`CompressionConfig`)

The `CompressionConfig` struct provides detailed control over the compression process:

**Video Settings:**

* `videoCodec`: `VideoCodec` (`.h264` or `.hevc`). Use `codec.isSupported()` to check for HEVC hardware encoding availability. Select `.hevc` for HDR video to preserve metadata (requires iOS 16+/macOS 13+ for automatic insertion).
* `useExplicitBitrate`: `Bool`. If `true`, uses `videoBitrate`. If `false`, uses `videoQuality`. Default is `true`.
* `videoBitrate`: `Int`. Target average video bitrate in bits per second (e.g., `2_000_000` for 2 Mbps). Effective only if `useExplicitBitrate` is `true`. See also `useAdaptiveBitrate`.
* `videoQuality`: `Float`. Target quality between 0.0 (lowest) and 1.0 (highest). Effective only if `useExplicitBitrate` is `false`. This is a hint to the encoder; the resulting bitrate varies.
* `useAdaptiveBitrate`: `Bool`. Default is `false`. If `true` and `useExplicitBitrate` is `true`, the target `videoBitrate` will be capped closer to the source video's bitrate if the source bitrate is lower than the target `videoBitrate`. This prevents unnecessarily increasing the bitrate for already low-bitrate videos.
* `maxKeyFrameInterval`: `Int`. Maximum interval between keyframes (e.g., `30`). Lower values can improve seeking but may increase file size.
* `fps`: `Float`. Target frame rate (e.g., `30`). If lower than the source FPS, a `VideoFrameReducer` strategy is used.
* `maxLongerDimension`: `CGFloat?`. Target maximum length for the longer side of the video (width or height). Aspect ratio is maintained.
    * `nil`: Keep original dimensions.
    * Value > 0: Sets the maximum size for the longer dimension. For example, `1920` means the longer side (width for landscape, height for portrait) will be scaled down to 1920 pixels, and the other side will be scaled proportionally.
    * Dimensions are rounded down to the nearest even number. This replaces the previous `scale` property.
* `forceVisualEncodingDimensions`: `Bool`. Default is `false`.
    * `false`: Rotated videos (e.g., portrait videos shot on iPhone) maintain their original encoding dimensions (e.g., 1920x1080) and the rotation is preserved via transform metadata in the output file. The `maxLongerDimension` scaling is applied to the visual size before determining encoding size.
    * `true`: Rotated videos are encoded using their visual dimensions (e.g., 1080x1920). The transform metadata is removed (`.identity`). This can improve compatibility with players that don't respect transform metadata, but might slightly affect quality or compression efficiency.
* `trimStartTime`: `CMTime?`. Start time for trimming the video (based on the original video's timeline). If `nil`, compression starts from the beginning of the video. Default is `nil`.
* `trimEndTime`: `CMTime?`. End time for trimming the video (based on the original video's timeline). If `nil`, compression goes to the end of the video. Default is `nil`.

**Audio Settings:**

* `audioCodec`: `AudioCodecType` (`.aac`, `.aac_he_v1`, `.aac_he_v2`).
* `audioBitrate`: `Int`. Target audio bitrate in bits per second (e.g., `128_000` for 128 kbps).
* `audioSampleRate`: `Int`. Target audio sample rate in Hz (e.g., `44100`).
* `audioChannels`: `Int?`. Target number of audio channels (e.g., `1` for mono, `2` for stereo). If `nil`, uses the source number of channels (up to 2).

**Optimization Settings:**

* `contentAwareOptimization`: `Bool`. If `true` (default), analyzes content (motion, screencast) to potentially adjust `maxKeyFrameInterval` and quality/bitrate settings slightly.
* `preprocessing`: `PreprocessingOptions`. Contains options for preprocessing steps. `noiseReduction` can be applied (used in some quality presets like `.lowQuality`). `autoLevels` is currently a placeholder.

**Output Settings:**

* `fileType`: `AVFileType`. Container format for the output file (e.g., `.mp4`, `.mov`). Default is `.mp4`.
* `outputURL`: `URL?`. If set, specifies the *exact* path and filename for the output video. Overrides `outputDirectory`. The parent directory will be created if it doesn't exist.
* `outputDirectory`: `URL?`. If `outputURL` is `nil`, this specifies the directory where the compressed file (with a unique name) will be saved. If both `outputURL` and `outputDirectory` are `nil`, the system's temporary directory is used.

## Frame Rate Reduction (`VideoFrameReducer`)

When the target `fps` in `CompressionConfig` is lower than the source video's frame rate, a `VideoFrameReducer` strategy determines which frames to keep. You can pass an instance of a type conforming to this protocol to the `compressVideo` method.

* **`ReduceFrameEvenlySpaced` (Default):** Selects frames that are closest to evenly spaced time intervals corresponding to the target frame rate. Ensures the first frame is always kept.
* **`ReduceFrameRandomly`:** Divides the video into segments based on the target frame rate and randomly picks one frame from each segment.
* **`SceneAwareReducer`:** (Placeholder) Intended for future implementation to detect scene changes and prioritize keeping frames around cuts. Currently falls back to `ReduceFrameEvenlySpaced`.

**Example:**

```swift
let result = try await compressor.compressVideo(
    sourceVideoURL,
    config: myLowFPSConfig, // A config with config.fps = 15
    frameReducer: ReduceFrameRandomly() // Use the random reducer
)
```

## Error Handling (`JMVideoCompressorError`)

The `compressVideo` methods can throw errors defined in the `JMVideoCompressorError` enum:

* `.invalidSourceURL(URL)`: The provided source URL is invalid or the file doesn't exist.
* `.invalidOutputPath(URL)`: The specified `outputDirectory` or the parent directory of `outputURL` is invalid or cannot be created.
* `.missingVideoTrack`: The source asset does not contain any video tracks.
* `.readerInitializationFailed(Error?)`: Failed to create the `AVAssetReader`.
* `.writerInitializationFailed(Error?)`: Failed to create the `AVAssetWriter`.
* `.compressionFailed(Error)`: An error occurred during the sample writing process.
* `.cancelled`: The operation was cancelled via the `cancel()` method.
* `.codecNotSupported(VideoCodec)`: The chosen `videoCodec` (especially HEVC) is not supported by the hardware/OS.
* `.underlyingError(Error)`: Wraps another system-level error encountered during processing.

Use a `do-catch` block to handle these errors gracefully.

## Compression Analytics (`CompressionAnalytics`)

The successful result of `compressVideo` includes a `CompressionAnalytics` struct containing:

* `originalFileSize`: `Int64` - Size of the source file in bytes.
* `compressedFileSize`: `Int64` - Size of the output file in bytes.
* `compressionRatio`: `Float` - `originalFileSize / compressedFileSize`. Higher is better.
* `processingTime`: `TimeInterval` - Time taken for compression in seconds.
* `originalDimensions`: `CGSize` - **Visual** dimensions (width, height) of the original video, considering rotation metadata.
* `compressedDimensions`: `CGSize` - **Encoded** dimensions (width, height) of the compressed video track. This might differ from the visual dimensions if `forceVisualEncodingDimensions` is `false` and the video was rotated.
* `originalVideoBitrate`: `Float` - Estimated bitrate of the source video track (bps).
* `compressedVideoBitrate`: `Float` - Target or estimated bitrate of the compressed video track (bps).
* `originalAudioBitrate`: `Float?` - Estimated bitrate of the source audio track (bps), if present.
* `compressedAudioBitrate`: `Float?` - Target or estimated bitrate of the compressed audio track (bps), if present.

## Testing

The package includes a suite of unit tests in the `JMVideoCompressorTests` target.

* **Sample Video:** Tests require a `sample.mp4` video file located in the `Tests/JMVideoCompressorTests/Resources/` directory. This resource is automatically copied for the test target as defined in `Package.swift`.
* **Running Tests:**
    * **Xcode:** Open the package in Xcode, select a simulator or device, and press `Cmd+U` (Product > Test).
    * **Command Line:** Navigate to the package's root directory in Terminal and run `swift test`.

The tests cover:
* Compression with different quality presets.
* Compression with various custom configurations (codecs, bitrate, scaling, FPS, audio settings).
* Usage of frame reducers.
* Specifying output paths.
* Error handling scenarios (invalid input/output, unsupported codecs).

## Acknowledgements

This project was inspired by and references concepts from [T2Je/FYVideoCompressor](https://github.com/T2Je/FYVideoCompressor).

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests on GitHub.

## License

`JMVideoCompressor` is available under the MIT license. See the [LICENSE](LICENSE) file for more information.
