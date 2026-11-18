import CoreMedia
import Foundation

/// Stream timing. 24 fps, 17-frame chunks (17/24 s = 0.70833 s, which the diagram rounds to 0.708),
/// 48 kHz audio = exactly 2,000 samples per frame. Media time uses timescale 24000 so every frame
/// boundary is an integer (1,000 ticks) and a rounded "0.708 s" chunk (16,992 ticks) is visibly wrong.
public enum Stream {
    public static let fps = 24
    public static let framesPerChunk = 17
    public static let timescale: CMTimeScale = 24000
    public static let ticksPerFrame: Int64 = 1000
    public static let sampleRate = 48_000
    public static let samplesPerFrame = 2000
    public static let chunkSeconds = Double(framesPerChunk) / Double(fps)
    public static let width = 640, height = 360

    public static func pts(frame n: Int) -> CMTime { CMTime(value: Int64(n) * ticksPerFrame, timescale: timescale) }
    /// A click on the first audio sample of every frame whose number is a multiple of 24 (once a second).
    public static func hasClick(frame n: Int) -> Bool { n % fps == 0 }
}

/// What the server says about a chunk, sent ahead of the MP4 bytes.
public struct ChunkHeader: Codable, Equatable {
    public var chunk: Int
    public var beat: Int
    /// Input sample sequence numbers the "model" consumed for this chunk.
    public var inputs: [Int]
    /// Media time of the chunk's first frame (Stream.timescale ticks). MP4 chunks restart at zero,
    /// so this is the stream timeline, as a fragmented MP4's base decode time would be.
    public var startTicks: Int64
    public init(chunk: Int, beat: Int, inputs: [Int], startTicks: Int64) {
        self.chunk = chunk; self.beat = beat; self.inputs = inputs; self.startTicks = startTicks
    }
}

/// Wire format, one WebSocket binary message per chunk: UInt32 big-endian header length, JSON header, MP4.
public enum Wire {
    public static func pack(_ h: ChunkHeader, mp4: Data) throws -> Data {
        let json = try JSONEncoder().encode(h)
        var len = UInt32(json.count).bigEndian
        return Data(bytes: &len, count: 4) + json + mp4
    }

    public static func unpack(_ d: Data) throws -> (ChunkHeader, Data) {
        guard d.count >= 4 else { throw ProbeError.protocolError("short message") }
        let n = Int(d.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard d.count >= 4 + n else { throw ProbeError.protocolError("header length \(n) > message") }
        let h = try JSONDecoder().decode(ChunkHeader.self, from: d.subdata(in: (d.startIndex + 4)..<(d.startIndex + 4 + n)))
        return (h, d.subdata(in: (d.startIndex + 4 + n)..<d.endIndex))
    }
}

/// Client -> server messages (JSON text).
public enum ClientMessage {
    public static func start(chunks: Int) -> String { #"{"type":"start","chunks":\#(chunks)}"# }
    /// (button, x, y, dx, dy) as in the diagram, plus a sequence number.
    public static func input(seq: Int, button: Int, x: Double, y: Double, dx: Double, dy: Double) -> String {
        String(format: #"{"type":"input","seq":%d,"button":%d,"x":%.4f,"y":%.4f,"dx":%.4f,"dy":%.4f}"#, seq, button, x, y, dx, dy)
    }
    public static func note(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"type":"note","text":"\#(escaped)"}"#
    }
}

public enum ProbeError: Error { case protocolError(String), decode(String), connection(String) }

/// Two block barcodes per frame: A = frame number, B = (latest input seq applied << 12) | beat id.
/// 8x4 blocks of 20 px, 24 bits + CRC-8, so a misread fails the CRC instead of lying.
public enum FrameCode {
    public static let cols = 8, rows = 4, block = 20, quiet = 8
    public static let originA = (x: 40, y: 40), originB = (x: 440, y: 40)
    /// Background probe: the scene tint (the "anchor" look) is read here.
    public static let tintProbe = (x: 30, y: 330)

    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for b in bytes {
            crc ^= b
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }

    static func bytes(_ v: Int) -> [UInt8] { [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    public static func bits(_ v: Int) -> [Bool] {
        let word = (UInt32(v & 0xFFFFFF) << 8) | UInt32(crc8(bytes(v)))
        return (0..<32).map { word & (1 << (31 - UInt32($0))) != 0 }
    }

    public static func decode(_ bits: [Bool]) -> Int? {
        let word = bits.reduce(UInt32(0)) { ($0 << 1) | ($1 ? 1 : 0) }
        let v = Int(word >> 8)
        return UInt8(word & 0xFF) == crc8(bytes(v)) ? v : nil
    }

    public static func pack(seq: Int, beat: Int) -> Int { ((seq & 0xFFF) << 12) | (beat & 0xFFF) }
    public static func unpack(_ v: Int) -> (seq: Int, beat: Int) { (v >> 12, v & 0xFFF) }

    /// BGRA buffer: draw one code with its white quiet zone.
    public static func draw(_ v: Int, at o: (x: Int, y: Int), into p: UnsafeMutablePointer<UInt8>, bytesPerRow: Int) {
        let b = bits(v), w = cols * block, h = rows * block
        for y in (o.y - quiet)..<(o.y + h + quiet) {
            for x in (o.x - quiet)..<(o.x + w + quiet) {
                let cx = x - o.x, cy = y - o.y
                var on = false
                if cx >= 0 && cx < w && cy >= 0 && cy < h { on = b[(cy / block) * cols + cx / block] }
                let c: UInt8 = on ? 16 : 235
                let i = y * bytesPerRow + x * 4
                p[i] = c; p[i + 1] = c; p[i + 2] = c; p[i + 3] = 255
            }
        }
    }

    public static func read(at o: (x: Int, y: Int), from p: UnsafePointer<UInt8>, bytesPerRow: Int) -> Int? {
        var bits: [Bool] = []
        for i in 0..<(cols * rows) {
            let bx = o.x + (i % cols) * block + block / 4, by = o.y + (i / cols) * block + block / 4
            var sum = 0, n = 0
            for y in by..<(by + block / 2) {
                for x in bx..<(bx + block / 2) {
                    let j = y * bytesPerRow + x * 4
                    sum += (Int(p[j + 2]) * 299 + Int(p[j + 1]) * 587 + Int(p[j]) * 114) / 1000
                    n += 1
                }
            }
            bits.append(sum / n < 128)
        }
        return decode(bits)
    }
}
