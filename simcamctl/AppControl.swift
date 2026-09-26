//
//  AppControl.swift
//  simcamctl
//
//  Client for the container app's ControlServer (127.0.0.1:kSimCamControlPort).
//  Going through the app means a source set here reaches iOS Simulator apps
//  too, not only the CMIO extension.
//

import Foundation

enum AppControl {

    /// Send one request; nil when the app is not running (nothing listening).
    static func request(_ body: [String: Any], timeout: TimeInterval = 30) -> [String: Any]? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = kSimCamControlPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected, var line = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        line.append(UInt8(ascii: "\n"))
        let sent = line.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == line.count else { return nil }

        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !reply.contains(UInt8(ascii: "\n")) {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            reply.append(contentsOf: chunk[0..<n])
        }
        guard let end = reply.firstIndex(of: UInt8(ascii: "\n")) else {
            return ["ok": false, "error": "no reply from SimulatorCamera.app (timed out)"]
        }
        return (try? JSONSerialization.jsonObject(with: reply[..<end])) as? [String: Any]
            ?? ["ok": false, "error": "unreadable reply from SimulatorCamera.app"]
    }

    /// Print the outcome of a command reply and exit.
    static func finish(_ reply: [String: Any], success: String) -> Never {
        if reply["ok"] as? Bool == true {
            print(success)
            exit(0)
        }
        FileHandle.standardError.write(Data("error: \(reply["error"] as? String ?? "failed")\n".utf8))
        exit(1)
    }
}
