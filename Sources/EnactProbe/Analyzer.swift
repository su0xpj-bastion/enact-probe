import CoreMedia
import Foundation

/// Every measurement from one session, plus a verdict per named check.
public struct Report: Codable {
    public var chunksExpected = 0
    public var chunksReceived = 0
    public var frames = 0
    public var unreadableFrames = 0
    public var frameIDsInOrder = true
    public var firstBadFrame: String?
    public var ptsBreaks = 0
    public var firstPtsBreak: String?
    public var stalls = 0
    public var maxArrivalGap = 0.0
    public var inputsSent = 0
    public var inputRate = 0.0
    public var maxInputGap = 0.0
    public var inputGapP95 = 0.0
    public var inputsMissing: [Int] = []
    public var inputsDuplicated: [Int] = []
    public var latencyP50 = 0.0
    public var latencyP95 = 0.0
    public var bargeIn: Double?
    public var avOffsetMaxMs = 0.0
    public var clicksMissing = 0
    public var anchorMaxDelta = 0
    public var decodeP95Ms = 0.0
    public var renderP95Ms = 0.0
    public var errors: [String] = []
    /// check name -> nil (pass) or why it failed.
    public var checks: [String: String] = [:]
    public var failing: [String] { Checks.names.filter { checks[$0] != nil } }
}

public enum Checks {
    public static let D = Stream.chunkSeconds
    /// Budgets. An input can only condition the next chunk to start, so input-to-photon is between
    /// one and two chunk lengths plus transport and decode.
    /// p50: half a chunk of waiting + one chunk of generation + 0.3 s for transport and decode.
    /// p95: two chunks + 0.38 s. Faults that cost a chunk or more land far outside both.
    public static let latencyP50Budget = 1.5 * D + 0.3
    public static let latencyP95Budget = 2 * D + 0.38
    public static let bargeInBudget = 2 * D + 0.3
    public static let stallGap = D + 0.3
    public static let avBudgetMs = 5.0
    public static let anchorBudget = 6

    public static let names = [
        "stream.complete", "stream.frames-readable", "stream.frame-sequence", "stream.pts-continuous", "stream.no-stalls",
        "input.cadence", "input.consumed-once", "input.latency", "direction.barge-in", "av.sync", "scene.anchor-hold",
    ]

    /// Which use case each check covers (see README).
    public static let useCases: [String: String] = [
        "stream.complete": "4 streaming playback", "stream.frames-readable": "3 chunk seams", "stream.frame-sequence": "3 chunk seams",
        "stream.pts-continuous": "3 chunk seams", "stream.no-stalls": "4 streaming playback", "input.cadence": "2 input/latent alignment",
        "input.consumed-once": "2 input/latent alignment", "input.latency": "1 touch-to-photon latency", "direction.barge-in": "8 barge-in",
        "av.sync": "7 A/V sync", "scene.anchor-hold": "9 identity and scene hold",
    ]
}

public enum Analyzer {
    static func pct(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return .infinity }
        let s = xs.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
    }

    public static func report(_ c: StreamClient) -> Report {
        var r = Report()
        let arrivals = c.arrivals.sorted { $0.chunk.header.chunk < $1.chunk.header.chunk }
        r.chunksExpected = c.expected
        r.chunksReceived = arrivals.count
        r.errors = c.errors
        let D = Stream.chunkSeconds

        // Frames: identity, order, media time.
        var expectedID = 0, frameIndex = 0
        for a in arrivals {
            for (i, f) in a.chunk.frames.enumerated() {
                r.frames += 1
                if f.frameID == nil || f.inputSeq == nil { r.unreadableFrames += 1 }
                if f.frameID != expectedID && r.frameIDsInOrder {
                    r.frameIDsInOrder = false
                    r.firstBadFrame = "chunk \(a.chunk.header.chunk) frame \(i): shows \(f.frameID.map(String.init) ?? "unreadable"), expected \(expectedID)"
                }
                let ticks = a.chunk.header.startTicks + f.pts.convertScale(Stream.timescale, method: .roundHalfAwayFromZero).value
                if ticks != Int64(frameIndex) * Stream.ticksPerFrame {
                    r.ptsBreaks += 1
                    if r.firstPtsBreak == nil {
                        r.firstPtsBreak = "chunk \(a.chunk.header.chunk) frame \(i): t=\(ticks)/24000, expected \(Int64(frameIndex) * Stream.ticksPerFrame)"
                    }
                }
                expectedID += 1
                frameIndex += 1
            }
        }

        // Arrival cadence: a gap longer than a chunk plus slack is a visible stall.
        let times = c.arrivals.map { $0.arrivedAt }.sorted()
        for (a, b) in zip(times, times.dropFirst()) {
            r.maxArrivalGap = max(r.maxArrivalGap, b - a)
            if b - a > Checks.stallGap { r.stalls += 1 }
        }
        r.decodeP95Ms = pct(c.arrivals.map { ($0.readyAt - $0.arrivedAt) * 1000 }, 0.95)
        r.renderP95Ms = pct(c.arrivals.compactMap { $0.chunk.header.renderMs }, 0.95)
        if r.renderP95Ms > D * 1000 * 0.8 {
            r.errors.append(String(format: "generator too slow for real time on this machine: render p95 %.0f ms vs %.0f ms chunks", r.renderP95Ms, D * 1000))
        }

        // Inputs: rate, gaps, consumed exactly once.
        r.inputsSent = c.sent.count
        if let first = c.sent.first, let last = c.sent.last, last.at > first.at {
            r.inputRate = Double(c.sent.count - 1) / (last.at - first.at)
            let gaps = zip(c.sent, c.sent.dropFirst()).map { $1.at - $0.at }
            r.maxInputGap = gaps.max() ?? 0
            r.inputGapP95 = pct(gaps, 0.95)
        }
        // Only samples sent early enough that a later chunk could still carry them.
        let lastCut = Double(max(0, c.expected - 1)) * D
        let eligible = c.sent.filter { $0.at < lastCut - 0.25 }
        var counts: [Int: Int] = [:]
        for a in arrivals { for s in a.chunk.header.inputs { counts[s, default: 0] += 1 } }
        r.inputsMissing = eligible.map { $0.seq }.filter { counts[$0] == nil }
        r.inputsDuplicated = counts.filter { $0.value > 1 }.map { $0.key }.sorted()

        // Input-to-photon: when a frame showing this sample (or a later one) was ready to display.
        var latencies: [Double] = []
        for s in eligible {
            if let a = arrivals.first(where: { $0.chunk.frames.contains { ($0.inputSeq ?? 0) >= s.seq } }) {
                latencies.append(a.readyAt - s.at)
            }
        }
        r.latencyP50 = pct(latencies, 0.5)
        r.latencyP95 = pct(latencies, 0.95)

        // Barge-in: note sent -> first frame of the new beat ready.
        if let n = c.notes.first,
           let a = arrivals.first(where: { $0.chunk.frames.contains { ($0.beat ?? 0) >= 100 } }) {
            r.bargeIn = a.readyAt - n
        }

        // A/V: each once-a-second click must start on its frame's first sample.
        for a in arrivals {
            for (i, f) in a.chunk.frames.enumerated() {
                guard let id = f.frameID, Stream.hasClick(frame: id) else { continue }
                let want = Double(i) / Double(Stream.fps)
                if let got = a.chunk.clicks.min(by: { abs($0 - want) < abs($1 - want) }), abs(got - want) < 0.2 {
                    r.avOffsetMaxMs = max(r.avOffsetMaxMs, abs(got - want) * 1000)
                } else {
                    r.clicksMissing += 1
                }
            }
        }

        // Scene hold: the look of the first frame is the anchor.
        if let anchor = arrivals.first?.chunk.frames.first?.tint {
            for a in arrivals { for f in a.chunk.frames { r.anchorMaxDelta = max(r.anchorMaxDelta, zip(f.tint, anchor).map { abs($0 - $1) }.max() ?? 0) } }
        }

        func check(_ name: String, _ ok: Bool, _ why: String) { r.checks[name] = ok ? nil : why }
        let f = { (x: Double) in String(format: "%.3f s", x) }
        check("stream.complete", r.chunksReceived == r.chunksExpected && r.errors.isEmpty,
              "\(r.chunksReceived)/\(r.chunksExpected) chunks, errors: \(r.errors.prefix(2))")
        check("stream.frames-readable", r.unreadableFrames == 0 && r.frames > 0, "\(r.unreadableFrames)/\(r.frames) frames unreadable")
        check("stream.frame-sequence", r.frameIDsInOrder, r.firstBadFrame ?? "")
        check("stream.pts-continuous", r.ptsBreaks == 0, "\(r.ptsBreaks) breaks; first: \(r.firstPtsBreak ?? "")")
        check("stream.no-stalls", r.stalls == 0, "\(r.stalls) stalls, longest gap \(f(r.maxArrivalGap))")
        // Rate within 2 of 24/s, 95% of gaps under 2 frame intervals (83 ms), none over 350 ms.
        // CI VMs pause whole processes for ~250 ms now and then; the bug this guards (a timer starved
        // while a touch is tracked) drops the rate and opens gaps of seconds, and still fails.
        let frame = 1.0 / Double(Stream.fps)
        check("input.cadence", abs(r.inputRate - 24) < 2 && r.inputGapP95 < 2 * frame && r.maxInputGap < 0.35,
              String(format: "%.1f samples/s, p95 gap %.0f ms, max gap %.0f ms", r.inputRate, r.inputGapP95 * 1000, r.maxInputGap * 1000))
        check("input.consumed-once", r.inputsMissing.isEmpty && r.inputsDuplicated.isEmpty,
              "missing \(r.inputsMissing.count) (first \(r.inputsMissing.prefix(5))), duplicated \(r.inputsDuplicated.prefix(5))")
        check("input.latency", r.latencyP50 <= Checks.latencyP50Budget && r.latencyP95 <= Checks.latencyP95Budget,
              "p50 \(f(r.latencyP50)) (budget \(f(Checks.latencyP50Budget))), p95 \(f(r.latencyP95)) (budget \(f(Checks.latencyP95Budget)))")
        check("direction.barge-in", (r.bargeIn ?? .infinity) <= Checks.bargeInBudget,
              "note to new beat \(r.bargeIn.map(f) ?? "never"), budget \(f(Checks.bargeInBudget))")
        check("av.sync", r.avOffsetMaxMs <= Checks.avBudgetMs && r.clicksMissing == 0,
              String(format: "max offset %.1f ms, %d clicks missing", r.avOffsetMaxMs, r.clicksMissing))
        check("scene.anchor-hold", r.anchorMaxDelta <= Checks.anchorBudget, "tint drifted \(r.anchorMaxDelta)/255 from the first frame")
        return r
    }
}
