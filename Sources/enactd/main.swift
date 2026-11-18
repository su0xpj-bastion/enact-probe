import EnactServer
import Foundation

/// enactd [--port N]   (0 = any free port; prints "LISTENING <port>")
var port: UInt16 = 8770
if let i = CommandLine.arguments.firstIndex(of: "--port"), i + 1 < CommandLine.arguments.count { port = UInt16(CommandLine.arguments[i + 1]) ?? 8770 }
let server = try EnactServer(port: port)
server.onReady = { p in
    print("LISTENING \(p)" + (ServerFault.active.isEmpty ? "" : " faults=\(ServerFault.active.map { $0.rawValue }.sorted().joined(separator: ","))"))
    fflush(stdout)
}
server.start()
dispatchMain()
