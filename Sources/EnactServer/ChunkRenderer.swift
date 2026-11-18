import AVFoundation
import EnactProbe
import Foundation

/// What one chunk must show: which frame numbers, at which media times, with which payload.
public struct ChunkPlan {
    public var index: Int
    public var frameIDs: [Int]
    /// Media time of the chunk's first frame, in Stream.timescale ticks.
    public var startTicks: Int64
    public var inputSeq: Int
    public var beat: Int
    public var tint: (r: UInt8, g: UInt8, b: UInt8)
    /// Last input position (0...1), drawn as the cursor.
    public var cursor: (x: Double, y: Double)
    /// Extra audio delay for this chunk, in samples.
    public var audioDelaySamples: Int

    public init(index: Int, frameIDs: [Int], startTicks: Int64, inputSeq: Int, beat: Int, tint: (r: UInt8, g: UInt8, b: UInt8),
                cursor: (x: Double, y: Double), audioDelaySamples: Int) {
        self.index = index; self.frameIDs = frameIDs; self.startTicks = startTicks; self.inputSeq = inputSeq; self.beat = beat
        self.tint = tint; self.cursor = cursor; self.audioDelaySamples = audioDelaySamples
    }
}

public enum RenderError: Error { case writer(String) }

/// Stand-in for "causal DiT + streaming VAE decoder": renders a chunk's frames and audio and encodes
/// H.264 + AAC into a standalone MP4, timestamped on the stream's media timeline.
public enum ChunkRenderer {
    public static func render(_ plan: ChunkPlan, scratch: URL = FileManager.default.temporaryDirectory) throws -> Data {
        let url = scratch.appendingPathComponent("render-\(plan.index)-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Stream.width, AVVideoHeightKey: Stream.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000, AVVideoMaxKeyFrameIntervalKey: Stream.framesPerChunk],
        ])
        video.expectsMediaDataInRealTime = true
        video.mediaTimeScale = Stream.timescale
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Stream.width, kCVPixelBufferHeightKey as String: Stream.height,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Stream.sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
        ])
        audio.expectsMediaDataInRealTime = true
        writer.add(video)
        writer.add(audio)
        let start = CMTime(value: plan.startTicks, timescale: Stream.timescale)
        guard writer.startWriting() else { throw RenderError.writer("\(String(describing: writer.error))") }
        writer.startSession(atSourceTime: start)

        for (i, id) in plan.frameIDs.enumerated() {
            while !video.isReadyForMoreMediaData { usleep(200) }
            var buf: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buf)
            guard let pb = buf else { throw RenderError.writer("no pixel buffer") }
            CVPixelBufferLockBaseAddress(pb, [])
            draw(id: id, plan: plan, into: CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), row: CVPixelBufferGetBytesPerRow(pb))
            CVPixelBufferUnlockBaseAddress(pb, [])
            let t = CMTime(value: plan.startTicks + Int64(i) * Stream.ticksPerFrame, timescale: Stream.timescale)
            guard adaptor.append(pb, withPresentationTime: t) else { throw RenderError.writer("frame \(id): \(String(describing: writer.error))") }
        }
        video.markAsFinished()

        // Audio: silence with a click on the first sample of every frame whose number is a multiple of 24.
        let n = plan.frameIDs.count * Stream.samplesPerFrame
        var samples = [Float](repeating: 0, count: n)
        for (i, id) in plan.frameIDs.enumerated() where Stream.hasClick(frame: id) {
            let s = i * Stream.samplesPerFrame + plan.audioDelaySamples
            for k in 0..<96 where s + k < n {
                samples[s + k] = 0.8 * Float(sin(2 * Double.pi * 3000 * Double(k) / Double(Stream.sampleRate) + Double.pi / 2))
            }
        }
        let audioStart = CMTime(value: Int64(Double(plan.startTicks) / Double(Stream.timescale) * Double(Stream.sampleRate)), timescale: CMTimeScale(Stream.sampleRate))
        let per = 1024
        var off = 0
        while off < n {
            while !audio.isReadyForMoreMediaData { usleep(200) }
            let slice = Array(samples[off..<min(n, off + per)])
            let pts = CMTimeAdd(audioStart, CMTime(value: Int64(off), timescale: CMTimeScale(Stream.sampleRate)))
            guard audio.append(try pcmBuffer(slice, pts: pts)) else { throw RenderError.writer("audio: \(String(describing: writer.error))") }
            off += per
        }
        audio.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw RenderError.writer("\(String(describing: writer.error))") }
        return try Data(contentsOf: url)
    }

    static func draw(id: Int, plan: ChunkPlan, into p: UnsafeMutablePointer<UInt8>, row: Int) {
        // Fill one row, then copy it: per-pixel loops are ~50x slower in a debug build,
        // enough to make the stand-in generator miss real time on a CI VM.
        let t = plan.tint
        var line = [UInt8](repeating: 255, count: Stream.width * 4)
        for x in 0..<Stream.width { line[x * 4] = t.b; line[x * 4 + 1] = t.g; line[x * 4 + 2] = t.r }
        line.withUnsafeBytes { src in
            for y in 0..<Stream.height { memcpy(p + y * row, src.baseAddress!, Stream.width * 4) }
        }
        // Cursor: where the viewer's last input put it.
        let cx = Int(plan.cursor.x * 600) + 10, cy = Int(plan.cursor.y * 150) + 160
        for y in cy..<(cy + 16) { for x in cx..<(cx + 16) { let i = y * row + x * 4; p[i] = 255; p[i + 1] = 255; p[i + 2] = 255 } }
        FrameCode.draw(id, at: FrameCode.originA, into: p, bytesPerRow: row)
        FrameCode.draw(FrameCode.pack(seq: plan.inputSeq, beat: plan.beat), at: FrameCode.originB, into: p, bytesPerRow: row)
    }

    static func pcmBuffer(_ samples: [Float], pts: CMTime) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(Stream.sampleRate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
                                               mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &fmt)
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard let bb = block, let f = fmt else { throw RenderError.writer("audio buffer") }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb, formatDescription: f, sampleCount: samples.count,
                                                             presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb)
        guard let s = sb else { throw RenderError.writer("sample buffer") }
        return s
    }
}
