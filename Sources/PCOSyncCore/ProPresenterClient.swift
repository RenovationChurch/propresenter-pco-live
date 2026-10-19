// ProPresenter Network API client.
//
// Shapes are from Renewed Vision's OpenAPI spec (https://openapi.propresenter.com):
//
//   GET /v1/playlist/active
//     {"presentation": {"playlist": {"uuid", "name", "index"},
//                       "item":     {"uuid", "name", "index"}},
//      "announcements": {...same...}}
//   GET /v1/playlist/{id}
//     {"id": {...}, "items": [{"id": {"uuid", "name", "index"},
//                              "type": "presentation|placeholder|header|media|audio|livevideo",
//                              "is_hidden": bool, "is_pco": bool, ...}]}
//
// An index of 4294967295 (UINT32_MAX) means "nothing" / "not in a playlist".

import Foundation

let noIndex = 4_294_967_295

public struct ProPresenterError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct PPRef: Equatable {
    public let uuid: String
    public let name: String
    public let index: Int?

    public init(uuid: String, name: String, index: Int?) {
        self.uuid = uuid
        self.name = name
        self.index = index
    }
}

public struct PPActive: Equatable {
    public let playlist: PPRef?
    public let item: PPRef?
}

public struct PPPlaylistItem: Equatable {
    public let uuid: String
    public let name: String
    public let index: Int?
    public let type: String
    public let isPCO: Bool
    public let isHidden: Bool

    public init(uuid: String, name: String, index: Int?, type: String, isPCO: Bool, isHidden: Bool) {
        self.uuid = uuid
        self.name = name
        self.index = index
        self.type = type
        self.isPCO = isPCO
        self.isHidden = isHidden
    }
}

public final class ProPresenterClient {
    public let baseURL: String
    private let transport: HTTPTransport
    private let timeout: TimeInterval

    public init(host: String, port: Int, timeout: TimeInterval = 2.0, transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = "http://\(host):\(port)"
        self.transport = transport
        self.timeout = timeout
    }

    private func get(_ path: String) throws -> JSONObject {
        guard let url = URL(string: baseURL + path) else { throw ProPresenterError("bad ProPresenter address \(baseURL)") }
        let resp: HTTPResponse
        do {
            resp = try transport.send(HTTPRequest(method: "GET", url: url), timeout: timeout)
        } catch let e as TransportError {
            throw ProPresenterError("ProPresenter unreachable at \(baseURL) (\(e.kind))")
        }
        if resp.status == 404 { throw ProPresenterError("ProPresenter returned 404 for \(path) (is Network enabled?)") }
        if resp.status >= 400 { throw ProPresenterError("ProPresenter \(path): HTTP \(resp.status)") }
        guard let doc = resp.jsonObject() else { throw ProPresenterError("ProPresenter \(path): response was not JSON") }
        return doc
    }

    public func version() throws -> JSONObject {
        try get("/version")
    }

    public func active() throws -> PPActive {
        let pres = try get("/v1/playlist/active").obj("presentation") ?? [:]
        return PPActive(playlist: ref(pres["playlist"]), item: ref(pres["item"]))
    }

    public func playlistItems(_ playlist: PPRef) throws -> [PPPlaylistItem] {
        let key = !playlist.uuid.isEmpty ? playlist.uuid : (playlist.index.map(String.init) ?? "")
        if key.isEmpty { throw ProPresenterError("active playlist has no uuid or index") }
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let doc = try get("/v1/playlist/\(encoded)")
        return doc.arr("items").compactMap { raw in
            guard let r = ref(raw["id"]) else { return nil }
            return PPPlaylistItem(
                uuid: r.uuid, name: r.name, index: r.index,
                type: raw.str("type") ?? "", isPCO: raw.bool("is_pco"), isHidden: raw.bool("is_hidden")
            )
        }
    }
}

private func ref(_ raw: Any?) -> PPRef? {
    guard let d = raw as? JSONObject else { return nil }
    let uuid = d.str("uuid") ?? ""
    let name = d.str("name") ?? ""
    var index = d.int("index")
    if let i = index, i == noIndex || i < 0 { index = nil }
    if uuid.isEmpty && name.isEmpty && index == nil { return nil }
    return PPRef(uuid: uuid, name: name, index: index)
}
