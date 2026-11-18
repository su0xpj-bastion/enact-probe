import EnactProbe
import SwiftUI

@main
struct EnactProbeApp: App {
    @StateObject private var model = SessionModel()
    var body: some Scene {
        WindowGroup { SessionView().environmentObject(model) }
    }
}

/// One live session from the phone: touches become (button, x, y, dx, dy) samples at 24 Hz,
/// the director button sends a note, and every chunk is decoded and measured as it lands.
final class SessionModel: ObservableObject {
    @Published var running = false
    @Published var chunks = 0
    @Published var preview: CGImage?
    @Published var report: Report?
    @Published var thermal = ""

    let args = ProcessInfo.processInfo.arguments
    func arg(_ k: String, _ d: String) -> String { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? d }
    var serverURL: URL { URL(string: arg("-server", "ws://127.0.0.1:8770"))! }
    var total: Int { Int(arg("-chunks", "20")) ?? 20 }

    private var client: StreamClient?
    private var timer: Timer?
    // Latest touch, sampled by the 24 Hz timer (touches arrive at 60-120 Hz).
    var touch = (button: 0, x: 0.5, y: 0.5)

    func start() {
        guard !running else { return }
        let c = StreamClient(url: serverURL)
        client = c
        report = nil
        chunks = 0
        running = true
        c.onArrival = { [weak self] a in DispatchQueue.main.async { self?.chunks += 1; self?.preview = a.chunk.preview } }
        c.onFinish = { [weak self] in DispatchQueue.main.async { self?.finish() } }
        c.start(chunks: total)
        // .common mode: a default-mode timer pauses while a touch is being tracked, which would
        // starve the stream of exactly the samples the viewer is producing (input.cadence catches it).
        let t = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.client?.sendInput(button: self.touch.button, x: self.touch.x, y: self.touch.y)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(total) * Stream.chunkSeconds + 20) { [weak self] in
            if self?.running == true { self?.finish() }
        }
    }

    func note() { client?.sendNote("Alice, your first line is…") }

    func finish() {
        guard running, let c = client else { return }
        timer?.invalidate()
        c.stop()
        report = Analyzer.report(c)
        running = false
        thermal = ["nominal", "fair", "serious", "critical"][ProcessInfo.processInfo.thermalState.rawValue]
    }
}
