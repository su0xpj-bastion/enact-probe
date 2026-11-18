import EnactProbe
import SwiftUI

struct SessionView: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enact Probe").font(.title2).bold().accessibilityAddTraits(.isHeader)
            stage
            HStack {
                Button(model.running ? "Streaming…" : "Start") { model.start() }
                    .disabled(model.running)
                    .accessibilityIdentifier("startButton")
                Button("Give note") { model.note() }
                    .disabled(!model.running)
                    .accessibilityIdentifier("directButton")
            }
            .buttonStyle(.borderedProminent)
            Text("chunks \(model.chunks)/\(model.total)").accessibilityIdentifier("hud.chunks")
            if let r = model.report { hud(r) }
            Spacer()
        }
        .padding()
        .onAppear { if model.args.contains("-autostart") { model.start() } }
    }

    /// The stage: the latest chunk, and the surface the viewer drags on. Press, hold and release
    /// map to the diagram's button state; position is normalised to the stage.
    var stage: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(Color.black)
                if let p = model.preview {
                    Image(decorative: p, scale: 1).resizable().aspectRatio(16 / 9, contentMode: .fit)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let x = min(1, max(0, Double(v.location.x / max(1, geo.size.width))))
                    let y = min(1, max(0, Double(v.location.y / max(1, geo.size.height))))
                    model.touch = (1, x, y)
                }
                .onEnded { _ in model.touch.button = 0 })
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Stage")
        .accessibilityHint("Drag to move the scene")
        .accessibilityIdentifier("stage")
    }

    func hud(_ r: Report) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(r.failing.isEmpty ? "PASS \(Checks.names.count)/\(Checks.names.count)" : "FAIL " + r.failing.joined(separator: ", "))
                .bold().accessibilityIdentifier("hud.verdict")
            Text(String(format: "latency p50 %.0f ms · p95 %.0f ms", r.latencyP50 * 1000, r.latencyP95 * 1000)).accessibilityIdentifier("hud.latency")
            Text("barge-in " + (r.bargeIn.map { String(format: "%.0f ms", $0 * 1000) } ?? "none")).accessibilityIdentifier("hud.bargeIn")
            Text("stalls \(r.stalls) · frames \(r.frames) · sequence \(r.frameIDsInOrder ? "ok" : "broken")").accessibilityIdentifier("hud.stream")
            Text(String(format: "inputs %d at %.1f/s · A/V max %.1f ms", r.inputsSent, r.inputRate, r.avOffsetMaxMs)).accessibilityIdentifier("hud.inputs")
            Text("thermal \(model.thermal) · decode p95 \(Int(r.decodeP95Ms)) ms").accessibilityIdentifier("hud.device")
        }
        .font(.system(.footnote, design: .monospaced))
    }
}
