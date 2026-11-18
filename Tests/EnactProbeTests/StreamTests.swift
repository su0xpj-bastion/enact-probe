import EnactProbe
import EnactServer
import XCTest

/// One live session against an in-process server, then one XCTest per check, so Xcode,
/// Jenkins and Xcode Cloud list each by name. Server faults run in tools/fault_matrix.py
/// (each needs its own server process).
final class StreamTests: XCTestCase {
    static let report: Report = {
        let server = try! EnactServer(port: 0)
        let ready = DispatchSemaphore(value: 0)
        var port: UInt16 = 0
        server.onReady = { port = $0; ready.signal() }
        server.start()
        ready.wait()
        return SyntheticViewer.run(url: URL(string: "ws://127.0.0.1:\(port)")!)
    }()

    func check(_ name: String) {
        XCTAssertNil(Self.report.checks[name], "\(name): \(Self.report.checks[name] ?? "")")
    }

    func test_stream_complete() { check("stream.complete") }
    func test_stream_frames_readable() { check("stream.frames-readable") }
    func test_stream_frame_sequence() { check("stream.frame-sequence") }
    func test_stream_pts_continuous() { check("stream.pts-continuous") }
    func test_stream_no_stalls() { check("stream.no-stalls") }
    func test_input_cadence() { check("input.cadence") }
    func test_input_consumed_once() { check("input.consumed-once") }
    func test_input_latency() { check("input.latency") }
    func test_direction_barge_in() { check("direction.barge-in") }
    func test_av_sync() { check("av.sync") }
    func test_scene_anchor_hold() { check("scene.anchor-hold") }

    func testEveryCheckHasATest() {
        let methods = Set(Self.defaultTestSuite.tests.compactMap { $0.name.split(separator: " ").last.map { String($0.dropLast()) } })
        for n in Checks.names {
            XCTAssertTrue(methods.contains("test_" + n.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "-", with: "_")), n)
        }
    }
}

/// Pure units: the code and timing maths the checks rely on.
final class UnitTests: XCTestCase {
    func testFrameCodeRoundTripAndCRC() {
        for v in [0, 1, 4095, 0xABCDE, 0xFFFFFF] {
            XCTAssertEqual(FrameCode.decode(FrameCode.bits(v)), v)
            var b = FrameCode.bits(v)
            b[5].toggle()
            XCTAssertNil(FrameCode.decode(b), "one flipped block must fail the CRC")
        }
        let p = FrameCode.pack(seq: 1234, beat: 101)
        XCTAssertEqual(FrameCode.unpack(p).seq, 1234)
        XCTAssertEqual(FrameCode.unpack(p).beat, 101)
    }

    func testChunkLengthIsNotPointSevenOhEight() {
        // 17 frames at 24 fps is 17,000 ticks; the diagram's rounded 0.708 s is 16,992.
        XCTAssertEqual(Int64(Stream.framesPerChunk) * Stream.ticksPerFrame, 17000)
        XCTAssertEqual(Int64((0.708 * Double(Stream.timescale)).rounded()), 16992)
        XCTAssertEqual(Stream.samplesPerFrame * Stream.fps, Stream.sampleRate)
    }

    func testWireRoundTrip() throws {
        let h = ChunkHeader(chunk: 3, beat: 101, inputs: [7, 8, 9], startTicks: 51000)
        let (back, body) = try Wire.unpack(try Wire.pack(h, mp4: Data([1, 2, 3])))
        XCTAssertEqual(back, h)
        XCTAssertEqual(body, Data([1, 2, 3]))
        XCTAssertThrowsError(try Wire.unpack(Data([0, 0, 1])))
    }
}

/// Client cost of decoding a chunk (use case 5: device health), with XCTest metrics.
final class DecodePerformanceTests: XCTestCase {
    func testChunkDecodeCostOnThisDevice() throws {
        let plan = ChunkPlan(index: 0, frameIDs: Array(0..<17), startTicks: 0, inputSeq: 1, beat: 1, tint: (90, 60, 140),
                             cursor: (0.5, 0.5), audioDelaySamples: 0)
        let mp4 = try ChunkRenderer.render(plan)
        let header = ChunkHeader(chunk: 0, beat: 1, inputs: [], startTicks: 0)
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            _ = try? ChunkDecoder.decode(header, mp4: mp4)
        }
    }
}
