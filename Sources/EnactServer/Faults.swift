import Foundation

/// Server bugs, switched on with ENACT_FAULTS=a,b. Each is a way a live generative-video stream
/// really breaks; the matrix pins which client checks must catch it.
public enum ServerFault: String, CaseIterable {
    case chunkClockDrift        // chunk start stamped at k * 0.708 s instead of k * 17/24 s
    case seamDuplicate          // chunk k repeats chunk k-1's last frame (and drops one)
    case lateChunk              // every 8th chunk ships 0.9 s late: the player stalls
    case inputDropAtBoundary    // samples arriving in the last 100 ms before a chunk starts are lost
    case inputLagExtraChunk     // samples applied one chunk later than they could be
    case beatNotReplaced        // a new note waits behind beats already queued instead of replacing them
    case audioDrift             // audio slips 1 ms later every chunk
    case anchorDrift            // scene tint creeps every chunk: the look drifts from the first frame

    public static var active: Set<ServerFault> = {
        Set((ProcessInfo.processInfo.environment["ENACT_FAULTS"] ?? "").split(separator: ",").compactMap { ServerFault(rawValue: String($0)) })
    }()
    public static func on(_ f: ServerFault) -> Bool { active.contains(f) }
}
