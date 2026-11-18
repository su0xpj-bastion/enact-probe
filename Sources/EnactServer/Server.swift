import EnactProbe
import Foundation
import Network

/// A stand-in for the live pipeline in Pika's "Live staging" / "Live actor direction" diagrams:
/// input samples and director notes come in over a WebSocket; every 17/24 s one chunk goes out,
/// conditioned on the inputs that arrived before its generation started.
public final class EnactServer {
    let listener: NWListener
    let queue = DispatchQueue(label: "enactd")
    public var onReady: ((UInt16) -> Void)?

    public init(port: UInt16) throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 16 * 1024 * 1024
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
    }

    public func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let p = self?.listener.port?.rawValue { self?.onReady?(p) }
            if case .failed(let e) = state { FileHandle.standardError.write("listener failed: \(e)\n".data(using: .utf8)!); exit(1) }
        }
        listener.newConnectionHandler = { conn in Session(conn).start() }
        listener.start(queue: queue)
    }
}

final class Session {
    let conn: NWConnection
    let q = DispatchQueue(label: "session")
    let renderQ = DispatchQueue(label: "render")
    var t0: Date?
    var total = 0
    // Guarded by q.
    var pending: [(seq: Int, at: Double, x: Double, y: Double)] = []
    var lastSeq = 0
    var cursor = (x: 0.5, y: 0.5)
    var notes: [Double] = []
    var consumedNotes = 0

    init(_ c: NWConnection) { conn = c }

    func start() {
        conn.stateUpdateHandler = { s in if case .failed = s { self.conn.cancel() } }
        conn.start(queue: q)
        receive()
    }

    func now() -> Double { Date().timeIntervalSince(t0 ?? Date()) }

    func receive() {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if error != nil { self.conn.cancel(); return }
            if let d = data, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { self.handle(obj) }
            self.receive()
        }
    }

    func handle(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "start":
            guard t0 == nil else { return }
            total = m["chunks"] as? Int ?? 20
            t0 = Date()
            schedule(0)
        case "input":
            guard t0 != nil, let seq = m["seq"] as? Int else { return }
            pending.append((seq, now(), m["x"] as? Double ?? 0, m["y"] as? Double ?? 0))
        case "note":
            if t0 != nil { notes.append(now()) }
        default:
            break
        }
    }

    /// Chunk k's generation starts at k*D and its bytes are ready at (k+1)*D.
    func schedule(_ k: Int) {
        guard k < total else { return }
        let D = Stream.chunkSeconds
        q.asyncAfter(deadline: .now() + max(0, Double(k) * D - now())) { self.generate(k) }
    }

    func generate(_ k: Int) {
        let D = Stream.chunkSeconds, cut = Double(k) * D
        // Inputs that arrived before generation started condition this chunk.
        let lag = ServerFault.on(.inputLagExtraChunk) ? D : 0
        var take = pending.filter { $0.at <= cut - lag }
        if ServerFault.on(.inputDropAtBoundary) { take.removeAll { $0.at > cut - 0.1 } ; pending.removeAll { $0.at <= cut - lag && $0.at > cut - 0.1 } }
        pending.removeAll { p in take.contains { $0.seq == p.seq } }
        if let last = take.last { lastSeq = last.seq; cursor = (last.x, last.y) }

        let plan = ChunkPlan(index: k, frameIDs: frameIDs(k), startTicks: startTicks(k), inputSeq: lastSeq, beat: beat(k, cut: cut),
                             tint: tint(k), cursor: cursor, audioDelaySamples: ServerFault.on(.audioDrift) ? 48 * k : 0)
        let header = ChunkHeader(chunk: k, beat: plan.beat, inputs: take.map { $0.seq }, startTicks: plan.startTicks)
        schedule(k + 1)
        renderQ.async {
            do {
                let msg = try Wire.pack(header, mp4: ChunkRenderer.render(plan))
                // Ready at (k+1)*D, like a real-time generator; a late chunk misses that.
                let late = ServerFault.on(.lateChunk) && k % 8 == 7 ? 0.9 : 0
                self.q.asyncAfter(deadline: .now() + max(0, Double(k + 1) * D + late - self.now())) { self.send(msg) }
            } catch {
                FileHandle.standardError.write("render \(k): \(error)\n".data(using: .utf8)!)
            }
        }
    }

    func frameIDs(_ k: Int) -> [Int] {
        let first = k * Stream.framesPerChunk - (ServerFault.on(.seamDuplicate) && k > 0 ? 1 : 0)
        return Array(first..<(first + Stream.framesPerChunk))
    }

    func startTicks(_ k: Int) -> Int64 {
        // 0.708 s is 16,992 ticks; one chunk is really 17,000.
        ServerFault.on(.chunkClockDrift) ? Int64(k) * 16992 : Int64(k * Stream.framesPerChunk) * Stream.ticksPerFrame
    }

    /// Beat schedule: each beat lasts 3 chunks (ids 1, 2, ...). A director's note replaces every beat
    /// not yet started, so the first chunk generated after it carries the note's beat (100 + n).
    func beat(_ k: Int, cut: Double) -> Int {
        let base = 1 + k / 3
        guard let firstNote = notes.first else { return base }
        var effective = firstNote
        if ServerFault.on(.beatNotReplaced) {
            // The note waits for the current beat and the two queued after it.
            let noteChunk = Int(ceil(firstNote / Stream.chunkSeconds))
            effective = Double((noteChunk / 3 + 3) * 3) * Stream.chunkSeconds
        }
        return cut >= effective ? 100 + notes.filter { $0 <= cut }.count : base
    }

    func tint(_ k: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let d = ServerFault.on(.anchorDrift) ? UInt8(min(60, 2 * k)) : 0
        return (90 &+ d, 60, 140 &- d)
    }

    func send(_ data: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "chunk", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }
}
