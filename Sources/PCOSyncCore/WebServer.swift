// A small HTTP/1.1 server on POSIX sockets: one request per connection,
// Connection: close. Enough for a local dashboard, with no dependencies, and
// it builds the same on macOS and Linux.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct WebRequest {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]  // lower-cased names
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }

    public func json() -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: body)) as? JSONObject
    }
}

public final class WebServer {
    public let port: Int
    public let bindAll: Bool
    private let handler: (WebRequest) -> HTTPResponse
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "pcosync-web", attributes: .concurrent)
    private var running = false

    public init(port: Int, bindAll: Bool, handler: @escaping (WebRequest) -> HTTPResponse) {
        self.port = port
        self.bindAll = bindAll
        self.handler = handler
    }

    public func start() throws {
        #if os(Linux)
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw ConfigError("socket() failed: errno \(errno)") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        #if os(macOS)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = bindAll ? in_addr_t(0) : inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if ok != 0 {
            let err = errno
            close(fd)
            throw ConfigError(err == EADDRINUSE ? "port \(port) is already in use (is PCOSync already running?)" : "bind() failed: errno \(err)")
        }
        guard listen(fd, 32) == 0 else {
            close(fd)
            throw ConfigError("listen() failed: errno \(errno)")
        }
        running = true
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "pcosync-web-accept"
        t.start()
    }

    public func stop() {
        running = false
        if fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
            close(fd)
            fd = -1
        }
    }

    private func acceptLoop() {
        while running {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if !running { return }
                continue
            }
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            #if os(macOS)
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            queue.async { [weak self] in
                self?.serve(client)
                close(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        guard let req = readRequest(client) else {
            writeResponse(client, HTTPResponse(status: 400, body: Data("bad request".utf8)))
            return
        }
        writeResponse(client, handler(req))
    }

    private func readRequest(_ client: Int32) -> WebRequest? {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        let sep = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = recv(client, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            buf.append(contentsOf: chunk[0..<n])
            headerEnd = buf.range(of: sep)
            if headerEnd == nil && buf.count > 64 * 1024 { return nil }
        }
        let head = String(decoding: buf[..<headerEnd!.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0 && length <= 1_000_000 else { return nil }
        var body = Data(buf[headerEnd!.upperBound...])
        while body.count < length {
            let n = recv(client, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            body.append(contentsOf: chunk[0..<n])
        }
        let target = String(requestLine[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        return WebRequest(method: String(requestLine[0]).uppercased(), path: comps?.path ?? target,
                          query: query, headers: headers, body: body.prefix(length))
    }

    private func writeResponse(_ client: Int32, _ resp: HTTPResponse) {
        var head = "HTTP/1.1 \(resp.status) \(Self.reason(resp.status))\r\n"
        var headers = resp.headers
        headers["Content-Length"] = String(resp.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = headers["Cache-Control"] ?? "no-store"
        headers["X-Content-Type-Options"] = "nosniff"
        headers["X-Frame-Options"] = "DENY"
        headers["Referrer-Policy"] = "no-referrer"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(resp.body)
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                #if os(Linux)
                let n = send(client, raw.baseAddress! + off, raw.count - off, Int32(MSG_NOSIGNAL))
                #else
                let n = send(client, raw.baseAddress! + off, raw.count - off, 0)
                #endif
                if n <= 0 { return }
                off += n
            }
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "Status"
        }
    }
}
