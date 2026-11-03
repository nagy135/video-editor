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

/// A source-time range omitted from playback and export.
public struct VideoCut: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var start: Double
    public var end: Double
    public var split: Double

    public init(id: UUID = UUID(), start: Double, end: Double) {
        self.id = id
        self.start = start
        self.end = end
        split = (start + end) / 2
    }

    public mutating func trimLeft(to time: Double, duration: Double) {
        start = min(split, max(0, min(duration, time)))
    }

    public mutating func trimRight(to time: Double, duration: Double) {
        end = max(split, min(duration, max(0, time)))
    }
}

/// All editor positions are source seconds. Speed transitions use smoothstep so
/// the curve has no overshoot and joins every control point with a flat tangent.
public struct VideoEdit: Equatable, Sendable {
    public var duration: Double
    public var start: Double
    public var end: Double
    public var points: [SpeedPoint]
    public var cuts: [VideoCut]

    public init(duration: Double) {
        self.duration = max(0, duration)
        start = 0
        end = max(0, duration)
        points = []
        cuts = []
    }

    /// Merge exclusions so overlaps are removed once, even when cuts are
    /// individually moved, resized, or undone.
    public var retainedRanges: [Range<Double>] {
        guard end > start else { return [] }
        var cursor = start
        var ranges: [Range<Double>] = []
        for cut in cuts.sorted(by: { $0.start < $1.start }) where cut.end >= cut.start {
            let a = max(start, cut.start)
            let b = min(end, cut.end)
            guard b >= a else { continue }
            if a > cursor { ranges.append(cursor..<a) }
            cursor = max(cursor, b)
        }
        if cursor < end { ranges.append(cursor..<end) }
        return ranges
    }

    public func nextPlayableTime(at time: Double) -> Double? {
        for range in retainedRanges where time < range.upperBound {
            return max(time, range.lowerBound)
        }
        return nil
    }

    /// Preview composition time excludes cuts but is not speed-retimed; the
    /// player applies the speed curve live using the corresponding source time.
    public func playbackTime(atSourceTime time: Double) -> Double {
        var elapsed = 0.0
        for range in retainedRanges {
            if time <= range.lowerBound { return elapsed }
            if time < range.upperBound { return elapsed + time - range.lowerBound }
            elapsed += range.upperBound - range.lowerBound
        }
        return elapsed
    }

    public func sourceTime(atPlaybackTime time: Double) -> Double {
        var remaining = max(0, time)
        let ranges = retainedRanges
        for range in ranges {
            let length = range.upperBound - range.lowerBound
            if remaining < length { return range.lowerBound + remaining }
            remaining -= length
        }
        return ranges.last?.upperBound ?? end
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
        var result: [Segment] = []
        for range in retainedRanges {
            var boundaries = [range.lowerBound, range.upperBound]
            boundaries += points.map(\.time).filter { range.contains($0) }
            boundaries.sort()
            for (a, b) in zip(boundaries, boundaries.dropFirst()) where b > a {
                let count = max(1, Int(ceil((b - a) / 0.1)))
                let length = (b - a) / Double(count)
                for i in 0..<count {
                    let position = a + Double(i) * length
                    result.append(Segment(start: position, duration: length,
                                          outputDuration: length / speed(at: position + length / 2)))
                }
            }
        }
        // Coalesce constant-rate runs, particularly the common unedited clip.
        var merged: [Segment] = []
        for segment in result {
            if let last = merged.last,
               abs(last.start + last.duration - segment.start) < 0.000001,
               abs(last.duration / last.outputDuration - segment.duration / segment.outputDuration) < 0.000001 {
                merged[merged.count - 1] = Segment(start: last.start, duration: last.duration + segment.duration,
                                                 outputDuration: last.outputDuration + segment.outputDuration)
            } else { merged.append(segment) }
        }
        return merged
    }

    public var outputDuration: Double { segments.reduce(0) { $0 + $1.outputDuration } }
}
