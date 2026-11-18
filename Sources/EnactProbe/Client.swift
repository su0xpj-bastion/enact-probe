import Foundation

public struct Arrival {
    public let chunk: DecodedChunk
    /// Seconds since the client sent "start", when the bytes arrived and when they were decoded (ready to show).
    public let arrivedAt: Double
    public let readyAt: Double
}

/// The viewer side of the stream: sends input samples and notes, receives and decodes chunks.
/// Used by the iOS app (driven by touches) and by the CLI / XCTest (driven by a synthetic viewer).
public final class StreamClient {
    public let url: URL
    public private(set) var sent: [(seq: Int, at: Double)] = []
    public private(set) var notes: [Double] = []
    public private(set) var arrivals: [Arrival] = []
    public private(set) var errors: [String] = []
    public var onArrival: ((Arrival) -> Void)?
    public var onFinish: (() -> Void)?

    let task: URLSessionWebSocketTask
    let lock = NSLock()
    let decodeQ = DispatchQueue(label: "decode")
    var t0 = Date()
    var expected = 0
    var seq = 0
    var last = (x: 0.5, y: 0.5)

    public init(url: URL) {
        self.url = url
        task = URLSession(configuration: .ephemeral).webSocketTask(with: url)
    }

    public func now() -> Double { Date().timeIntervalSince(t0) }

    public func start(chunks: Int) {
        expected = chunks
        task.resume()
        t0 = Date()
        task.send(.string(ClientMessage.start(chunks: chunks))) { [weak self] e in if let e = e { self?.fail("start: \(e)") } }
        receive()
    }

    public func stop() { task.cancel(with: .goingAway, reason: nil) }

    /// One (button, x, y, dx, dy) sample; call at 24 Hz.
    public func sendInput(button: Int, x: Double, y: Double) {
        lock.lock()
        seq += 1
        let s = seq, dx = x - last.x, dy = y - last.y
        last = (x, y)
        sent.append((s, now()))
        lock.unlock()
        task.send(.string(ClientMessage.input(seq: s, button: button, x: x, y: y, dx: dx, dy: dy))) { _ in }
    }

    public func sendNote(_ text: String) {
        lock.lock(); notes.append(now()); lock.unlock()
        task.send(.string(ClientMessage.note(text))) { _ in }
    }

    public var finished: Bool { lock.lock(); defer { lock.unlock() }; return arrivals.count >= expected }

    func fail(_ s: String) { lock.lock(); errors.append(s); lock.unlock() }

    func receive() {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                if !self.finished { self.fail("receive: \(e)") }
                self.onFinish?()
            case .success(.data(let d)):
                let at = self.now()
                self.decodeQ.async {
                    do {
                        let (h, mp4) = try Wire.unpack(d)
                        let chunk = try ChunkDecoder.decode(h, mp4: mp4)
                        let a = Arrival(chunk: chunk, arrivedAt: at, readyAt: self.now())
                        self.lock.lock(); self.arrivals.append(a); let done = self.arrivals.count >= self.expected; self.lock.unlock()
                        self.onArrival?(a)
                        if done { self.onFinish?() }
                    } catch {
                        self.fail("chunk: \(error)")
                    }
                }
                self.receive()
            case .success:
                self.receive()
            }
        }
    }
}

/// A scripted viewer: drags in a circle at 24 Hz with the button held, gives one director's note.
public final class SyntheticViewer {
    public static func run(url: URL, chunks: Int = 20, noteAtChunk: Int = 7, timeout: Double = 60) -> Report {
        let client = StreamClient(url: url)
        let done = DispatchSemaphore(value: 0)
        client.onFinish = { done.signal() }
        client.start(chunks: chunks)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "viewer"))
        var tick = 0, noted = false
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(Stream.fps), leeway: .milliseconds(1))
        timer.setEventHandler {
            let a = Double(tick) / 24.0
            client.sendInput(button: 1, x: 0.5 + 0.4 * cos(a), y: 0.5 + 0.4 * sin(a))
            tick += 1
            if !noted && client.now() > Double(noteAtChunk) * Stream.chunkSeconds + 0.2 {
                noted = true
                client.sendNote("Alice, your first line is…")
            }
        }
        timer.resume()
        _ = done.wait(timeout: .now() + timeout)
        timer.cancel()
        client.stop()
        return Analyzer.report(client)
    }
}
