import CoreGraphics
import Foundation

// §6.2 — 8-이웃 flood fill. 색상 키별 마스크에서 클러스터(Blip 원료)를 뽑는다.
// FlashDetector의 토글 셀 클러스터링에도 재사용된다.
public enum Clustering {

    public struct Cluster: Equatable {
        public let center: CGPoint     // 그리드 좌표 (호출자가 정규화)
        public let pixels: Int
    }

    /// mask[y*width+x] == key 인 픽셀들의 8-이웃 연결 성분
    public static func clusters(mask: [Int], width: Int, height: Int,
                                key: Int, minPixels: Int = 1) -> [Cluster] {
        precondition(mask.count == width * height)
        var visited = [Bool](repeating: false, count: mask.count)
        var result: [Cluster] = []
        var stack: [Int] = []

        for start in 0..<mask.count where mask[start] == key && !visited[start] {
            visited[start] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            var count = 0
            var sumX = 0, sumY = 0
            while let idx = stack.popLast() {
                count += 1
                let x = idx % width, y = idx / width
                sumX += x; sumY += y
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let n = ny * width + nx
                        if mask[n] == key && !visited[n] {
                            visited[n] = true
                            stack.append(n)
                        }
                    }
                }
            }
            if count >= minPixels {
                result.append(Cluster(
                    center: CGPoint(x: Double(sumX) / Double(count),
                                    y: Double(sumY) / Double(count)),
                    pixels: count))
            }
        }
        return result
    }
}
