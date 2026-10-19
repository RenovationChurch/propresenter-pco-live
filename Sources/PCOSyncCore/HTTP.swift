// Minimal synchronous HTTP layer. The engine runs on its own thread and does
// one request at a time, so a blocking API keeps the sync logic linear.
// Tests swap in a ClosureTransport (the Swift twin of httpx.MockTransport).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public typealias JSONObject = [String: Any]

public struct HTTPRequest {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    public var path: String { url.path }

    public func queryValue(_ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

public struct HTTPResponse {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ obj: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        var h = headers
        h["Content-Type"] = "application/json"
        return HTTPResponse(status: status, headers: h, body: data)
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func jsonObject() -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: body)) as? JSONObject
    }
}

/// A request that never got an HTTP response (refused, timed out, DNS...).
public struct TransportError: Error, CustomStringConvertible {
    public let kind: String
    public init(_ kind: String) { self.kind = kind }
    public var description: String { kind }
}

public protocol HTTPTransport: AnyObject {
    func send(_ request: HTTPRequest, timeout: TimeInterval) throws -> HTTPResponse
}

public final class ClosureTransport: HTTPTransport {
    public var handler: (HTTPRequest) throws -> HTTPResponse

    public init(_ handler: @escaping (HTTPRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    public func send(_ request: HTTPRequest, timeout: TimeInterval) throws -> HTTPResponse {
        try handler(request)
    }
}

public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        session = URLSession(configuration: cfg)
    }

    public func send(_ request: HTTPRequest, timeout: TimeInterval) throws -> HTTPResponse {
        var req = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = request.method
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = request.body

        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = session.dataTask(with: req) { data, response, error in
            if let error = error {
                box.result = .failure(TransportError(Self.describe(error)))
            } else if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields { headers["\(k)"] = "\(v)" }
                box.result = .success(HTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
            } else {
                box.result = .failure(TransportError("non-HTTP response"))
            }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw TransportError("timed out")
        }
        return try box.result.get()
    }

    /// Written by the completion handler before `done.signal()`, read after the wait.
    private final class ResultBox: @unchecked Sendable {
        var result: Result<HTTPResponse, Error> = .failure(TransportError("no response"))
    }

    private static func describe(_ error: Error) -> String {
        guard let u = error as? URLError else { return "network error" }
        switch u.code {
        case .timedOut: return "timed out"
        case .cannotConnectToHost: return "connection refused"
        case .cannotFindHost, .dnsLookupFailed: return "host not found"
        case .notConnectedToInternet: return "not connected to the network"
        case .networkConnectionLost: return "connection lost"
        case .secureConnectionFailed, .serverCertificateUntrusted: return "TLS failure"
        default: return "network error \(u.code.rawValue)"
        }
    }
}

// MARK: - JSON helpers for loosely shaped API documents

extension Dictionary where Key == String, Value == Any {
    func obj(_ key: String) -> JSONObject? { self[key] as? JSONObject }
    func arr(_ key: String) -> [JSONObject] { (self[key] as? [Any])?.compactMap { $0 as? JSONObject } ?? [] }
    /// String value, also accepting numbers (PCO ids are strings, but be lenient).
    func str(_ key: String) -> String? {
        switch self[key] {
        case let s as String: return s
        case let i as Int: return String(i)
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
    func int(_ key: String) -> Int? {
        switch self[key] {
        case let i as Int: return i
        case let d as Double: return d.isFinite ? Int(d) : nil
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }
    func bool(_ key: String) -> Bool {
        switch self[key] {
        case let b as Bool: return b
        case let i as Int: return i != 0
        case let n as NSNumber: return n.boolValue
        default: return false
        }
    }
}

func jsonString(_ obj: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}
