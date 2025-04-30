//
//  VideoFrameReducer.swift
//  JMVideoCompressor
//
//  Created by raykim on 4/24/25.
//

import Foundation
import CoreMedia

/// A strategy protocol defining how to select frames when reducing the frame rate of a video.
public protocol VideoFrameReducer {
    /// Calculates the indices of the frames to keep from the original video sequence.
    func reduce(originalFPS: Float, to targetFPS: Float, with videoDuration: Float) -> [Int]?
}

/// Selects frames at evenly spaced intervals.
public struct ReduceFrameEvenlySpaced: VideoFrameReducer {
    public init() {}

    public func reduce(originalFPS: Float, to targetFPS: Float, with videoDuration: Float) -> [Int]? {
        guard targetFPS > 0, originalFPS > 0, videoDuration > 0 else { return nil }
        // 목표 FPS가 원본보다 높거나 같으면 모든 프레임 유지 (감소 필요 없음)
        guard targetFPS < originalFPS else {
            let totalOriginalFrames = Int(ceil(originalFPS * videoDuration))
            return totalOriginalFrames > 0 ? Array(0..<totalOriginalFrames) : []
        }

        let totalOriginalFrames = Int(ceil(originalFPS * videoDuration))
        let totalTargetFrames = Int(round(targetFPS * videoDuration)) // 목표로 하는 총 프레임 수
        guard totalTargetFrames > 0, totalOriginalFrames > 0 else { return [] }

        var keptFrameIndices = [Int]()
        keptFrameIndices.reserveCapacity(totalTargetFrames)

        // 각 목표 프레임(k)에 대해 가장 가까운 원본 프레임 인덱스를 계산
        // k / targetFPS ≈ idealOriginalIndex / originalFPS
        // idealOriginalIndex ≈ k * originalFPS / targetFPS
        for k in 0..<totalTargetFrames {
            let idealOriginalFrameIndex = Int(round(Double(k) * Double(originalFPS) / Double(targetFPS)))

            // 계산된 인덱스가 유효한 범위 내에 있는지 확인
            if idealOriginalFrameIndex < totalOriginalFrames {
                // 반올림으로 인해 같은 인덱스가 중복 추가되는 것을 방지
                if keptFrameIndices.isEmpty || keptFrameIndices.last! != idealOriginalFrameIndex {
                    keptFrameIndices.append(idealOriginalFrameIndex)
                } else {
                    // 중복된 경우, 다음 인덱스를 시도 (간단한 처리)
                    let nextIndex = idealOriginalFrameIndex + 1
                    if nextIndex < totalOriginalFrames && (keptFrameIndices.isEmpty || keptFrameIndices.last! != nextIndex) {
                        keptFrameIndices.append(nextIndex)
                    }
                }
            }
        }

        // 첫 번째 프레임(인덱스 0)이 항상 포함되도록 보장 (비디오 시작을 위해 중요)
        if totalTargetFrames > 0 && (keptFrameIndices.isEmpty || keptFrameIndices[0] != 0) {
            keptFrameIndices.insert(0, at: 0)
            // 0을 삽입하여 중복이 발생했는지 확인하고 제거
             if keptFrameIndices.count > 1 && keptFrameIndices[0] == keptFrameIndices[1] {
                  keptFrameIndices.remove(at: 1) // [0, 0, ...] -> [0, ...]
             }
             // 중복 추가 방지 로직으로 인해 불필요하게 [0, 2] 처럼 될 수 있는 경우 1 추가 시도
             else if keptFrameIndices.count > 1 && keptFrameIndices[0] == 0 && keptFrameIndices[1] > 1 {
                 // 이 부분은 더 복잡한 로직이 필요할 수 있으나, 우선순위는 낮음
             }
        }

        // 최종적으로 중복 제거 및 정렬 (안전을 위해)
        var uniqueIndices = [Int]()
        var seen = Set<Int>()
        for index in keptFrameIndices {
           if !seen.contains(index) {
               uniqueIndices.append(index)
               seen.insert(index)
           }
        }

        // 디버깅 출력 (필요시 활성화)
        // print("Original FPS: \(originalFPS), Target FPS: \(targetFPS)")
        // print("Total Original: \(totalOriginalFrames), Total Target: \(totalTargetFrames)")
        // print("Kept Indices (\(uniqueIndices.count)): \(uniqueIndices)")

        return uniqueIndices.sorted() // 최종 반환 전 정렬 확인
    }
}

/// Randomly selects one frame from each time segment.
public struct ReduceFrameRandomly: VideoFrameReducer {
    public init() {}
    public func reduce(originalFPS: Float, to targetFPS: Float, with videoDuration: Float) -> [Int]? {
        guard targetFPS > 0, originalFPS > 0, videoDuration > 0 else { return nil }
        guard targetFPS <= originalFPS else { return nil }
        let originalFramesCount = Int(originalFPS * videoDuration)
        let targetFramesCount = Int(targetFPS * videoDuration)
        guard targetFramesCount > 0, originalFramesCount > 0 else { return [] }

        var segmentEndFrames = [Int]()
        segmentEndFrames.reserveCapacity(targetFramesCount)
        for i in 1...targetFramesCount {
            segmentEndFrames.append(Int(ceil(Double(originalFramesCount) * Double(i) / Double(targetFramesCount))))
        }

        var randomFrames = [Int]()
        randomFrames.reserveCapacity(targetFramesCount)
        randomFrames.append(0)
        var previousBoundary = 0
        for i in 0..<targetFramesCount - 1 {
            let currentBoundary = segmentEndFrames[i]
            let lowerBound = previousBoundary + 1
            let upperBound = currentBoundary
            guard upperBound > lowerBound else {
                if lowerBound < originalFramesCount && !randomFrames.contains(lowerBound) { randomFrames.append(lowerBound) }
                else if upperBound > 0 && (upperBound - 1) < originalFramesCount && !randomFrames.contains(upperBound - 1) { randomFrames.append(upperBound - 1) }
                previousBoundary = currentBoundary
                continue
            }
            let randomIndex = Int.random(in: lowerBound..<upperBound)
            if !randomFrames.contains(randomIndex) { randomFrames.append(randomIndex) }
            else if lowerBound < originalFramesCount && !randomFrames.contains(lowerBound) { randomFrames.append(lowerBound) }
            previousBoundary = currentBoundary
        }
        return randomFrames.sorted()
    }
}

/// Placeholder for a scene-aware frame reduction strategy.
/// Currently falls back to `ReduceFrameEvenlySpaced`.
public struct SceneAwareReducer: VideoFrameReducer {
    public init() {}
    public func reduce(originalFPS: Float, to targetFPS: Float, with videoDuration: Float) -> [Int]? {
        // TODO: Implement actual scene change detection and frame selection logic.
        // For now, fallback to a simpler strategy.
        print("Warning: SceneAwareReducer not yet implemented, falling back to ReduceFrameEvenlySpaced.")
        return ReduceFrameEvenlySpaced().reduce(originalFPS: originalFPS, to: targetFPS, with: videoDuration)
    }
}
