import Foundation

public struct SpeedPoint: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var time: Double
    public var speed: Double
    public init(id: UUID = UUID(), time: Double, speed: Double) {
        self.id = id
        self.time = time
        self.speed = min(10, max(1, speed))
    }
}

/// All editor positions are source seconds. Speed transitions use smoothstep so
/// the curve has no overshoot and joins every control point with a flat tangent.
public struct VideoEdit: Equatable, Sendable {
    public var duration: Double
    public var start: Double
    public var end: Double
    public var points: [SpeedPoint]

    public init(duration: Double) {
        self.duration = max(0, duration)
        start = 0
        end = max(0, duration)
        points = []
    }

    public func speed(at time: Double) -> Double {
        let sorted = points.sorted { $0.time < $1.time }
        guard let first = sorted.first, let last = sorted.last else { return 1 }
        if time <= first.time { return first.speed }
        if time >= last.time { return last.speed }
        for (a, b) in zip(sorted, sorted.dropFirst()) where time <= b.time {
            let t = min(1, max(0, (time - a.time) / max(0.000001, b.time - a.time)))
            return a.speed + (b.speed - a.speed) * t * t * (3 - 2 * t)
        }
        return 1
    }

    public struct Segment: Sendable {
        public let start: Double
        public let duration: Double
        public let outputDuration: Double
    }

    /// Midpoint integration is shared by the duration readout and media export.
    /// 100 ms source slices bound speed-ramp error without one cut per frame.
    public var segments: [Segment] {
        guard end > start else { return [] }
        var boundaries = [start, end]
        boundaries += points.map(\.time).filter { $0 > start && $0 < end }
        boundaries.sort()
        var result: [Segment] = []
        for (a, b) in zip(boundaries, boundaries.dropFirst()) where b > a {
            let count = max(1, Int(ceil((b - a) / 0.1)))
            let length = (b - a) / Double(count)
            for i in 0..<count {
                let position = a + Double(i) * length
                result.append(Segment(start: position, duration: length,
                                      outputDuration: length / speed(at: position + length / 2)))
            }
        }
        // Coalesce constant-rate runs, particularly the common unedited clip.
        var merged: [Segment] = []
        for segment in result {
            if let last = merged.last,
               abs(last.duration / last.outputDuration - segment.duration / segment.outputDuration) < 0.000001 {
                merged[merged.count - 1] = Segment(start: last.start, duration: last.duration + segment.duration,
                                                 outputDuration: last.outputDuration + segment.outputDuration)
            } else { merged.append(segment) }
        }
        return merged
    }

    public var outputDuration: Double { segments.reduce(0) { $0 + $1.outputDuration } }
}
