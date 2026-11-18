import EnactProbe
import Foundation

/// probe run [--url ws://127.0.0.1:8770] [--chunks 20] [--json]
/// probe list
let args = CommandLine.arguments
func opt(_ k: String, _ d: String) -> String { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? d }

switch args.dropFirst().first ?? "run" {
case "list":
    for n in Checks.names { print("\(n)\t\(Checks.useCases[n] ?? "")") }
case "run":
    let url = URL(string: opt("--url", "ws://127.0.0.1:8770"))!
    let r = SyntheticViewer.run(url: url, chunks: Int(opt("--chunks", "20")) ?? 20)
    if args.contains("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try! enc.encode(r), encoding: .utf8)!)
    } else {
        print(String(format: "chunks %d/%d  frames %d  latency p50 %.0f ms p95 %.0f ms  barge-in %@  A/V max %.1f ms  stalls %d  decode p95 %.0f ms",
                     r.chunksReceived, r.chunksExpected, r.frames, r.latencyP50 * 1000, r.latencyP95 * 1000,
                     r.bargeIn.map { String(format: "%.0f ms", $0 * 1000) } ?? "never", r.avOffsetMaxMs, r.stalls, r.decodeP95Ms))
        for n in Checks.names {
            print(r.checks[n] == nil ? "  PASS  \(n)" : "  FAIL  \(n)  \(r.checks[n]!)")
        }
        print("\(Checks.names.count - r.failing.count)/\(Checks.names.count) checks passed")
    }
    exit(r.failing.isEmpty ? 0 : 1)
default:
    print("usage: probe run [--url U] [--chunks N] [--json] | probe list"); exit(2)
}
