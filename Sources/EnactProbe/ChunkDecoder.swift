import AVFoundation
import CoreImage
import Foundation

public struct DecodedFrame: Equatable {
    public let pts: CMTime
    public let frameID: Int?
    public let inputSeq: Int?
    public let beat: Int?
    /// Scene tint at the probe, 0...255 (R, G, B).
    public let tint: [Int]
}

public struct DecodedChunk {
    public let header: ChunkHeader
    public let frames: [DecodedFrame]
    /// Audio click onsets as media times (seconds), using the audio track's own timestamps.
    public let clicks: [Double]
    public let audioStart: Double
    /// The chunk's last frame, for display.
    public let preview: CGImage?
}

/// Decodes one MP4 chunk the way a player would: every video frame and every audio sample.
public enum ChunkDecoder {
    static let bgra: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    static let pcm: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Stream.sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
    ]

    public static func decode(_ header: ChunkHeader, mp4: Data, scratch: URL = FileManager.default.temporaryDirectory) throws -> DecodedChunk {
        let url = scratch.appendingPathComponent("chunk-\(UUID().uuidString).mp4")
        try mp4.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        guard let v = asset.tracks(withMediaType: .video).first else { throw ProbeError.decode("no video in chunk \(header.chunk)") }
        var preview: CGImage?
        let frames = try readFrames(asset, v, preview: &preview)
        var clicks: [Double] = [], start = 0.0
        if let a = asset.tracks(withMediaType: .audio).first { (clicks, start) = try readClicks(asset, a) }
        return DecodedChunk(header: header, frames: frames, clicks: clicks, audioStart: start, preview: preview)
    }

    static let ci = CIContext()

    static func readFrames(_ asset: AVAsset, _ track: AVAssetTrack, preview: inout CGImage?) throws -> [DecodedFrame] {
        var last: CVPixelBuffer?
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: bgra)
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw ProbeError.decode("\(String(describing: reader.error))") }
        var result: [DecodedFrame] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(pb)
            let a = FrameCode.read(at: FrameCode.originA, from: p, bytesPerRow: row)
            let b = FrameCode.read(at: FrameCode.originB, from: p, bytesPerRow: row).map(FrameCode.unpack)
            var tint = [0, 0, 0]
            let t = FrameCode.tintProbe
            for y in (t.y - 4)...(t.y + 4) {
                for x in (t.x - 4)...(t.x + 4) {
                    let i = y * row + x * 4
                    tint[0] += Int(p[i + 2]); tint[1] += Int(p[i + 1]); tint[2] += Int(p[i])
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            last = pb
            result.append(DecodedFrame(pts: CMSampleBufferGetPresentationTimeStamp(sb), frameID: a, inputSeq: b?.seq, beat: b?.beat,
                                       tint: tint.map { $0 / 81 }))
        }
        guard reader.status == .completed else { throw ProbeError.decode("\(String(describing: reader.error))") }
        if let pb = last {
            let img = CIImage(cvPixelBuffer: pb)
            preview = ci.createCGImage(img, from: img.extent)
        }
        return result
    }

    /// Click onsets: |x| > 0.1 after at least 1,000 quiet samples, timed from the buffer's own PTS.
    static func readClicks(_ asset: AVAsset, _ track: AVAssetTrack) throws -> ([Double], Double) {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        reader.add(out)
        guard reader.startReading() else { throw ProbeError.decode("\(String(describing: reader.error))") }
        var clicks: [Double] = [], quiet = 1000
        var first: Double?
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let base = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if first == nil { first = base }
            let n = CMBlockBufferGetDataLength(bb) / 4
            var chunk = [Float](repeating: 0, count: n)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            for (i, x) in chunk.enumerated() {
                if abs(x) > 0.1 {
                    if quiet >= 1000 { clicks.append(base + Double(i) / Double(Stream.sampleRate)) }
                    quiet = 0
                } else {
                    quiet += 1
                }
            }
        }
        return (clicks, first ?? 0)
    }
}
