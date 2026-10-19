// Timestamped log to stderr, a rotating file and an in-memory ring the web UI
// reads. Secrets are redacted from every line before it goes anywhere.

import Foundation

public enum LogLevel: Int, Comparable, CaseIterable {
    case debug = 10, info = 20, warning = 30, error = 40

    public var name: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        }
    }

    public init(name: String) {
        self = LogLevel.allCases.first { $0.name == name.uppercased() } ?? .info
    }

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct LogEntry {
    public let seq: Int
    public let time: Date
    public let level: LogLevel
    public let message: String
}

public final class Logger {
    public var level: LogLevel
    public var echoToStderr: Bool
    private let lock = NSLock()
    private var ring: [LogEntry] = []
    private var seq = 0
    private let ringSize: Int
    private var secrets: [String] = []
    private let fileURL: URL?
    private var file: FileHandle?
    private var fileBytes: UInt64 = 0
    private let maxBytes: UInt64 = 2_000_000
    private let keep = 5
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        return f
    }()

    public init(level: LogLevel = .info, fileURL: URL? = nil, echoToStderr: Bool = true, ringSize: Int = 1000) {
        self.level = level
        self.fileURL = fileURL
        self.echoToStderr = echoToStderr
        self.ringSize = ringSize
        openFile()
    }

    /// Strings (6+ chars) to replace with *** in every line.
    public func setSecrets(_ values: [String?]) {
        lock.lock()
        secrets = values.compactMap { $0 }.filter { $0.count >= 6 }
        lock.unlock()
    }

    public func debug(_ msg: @autoclosure () -> String) { log(.debug, msg()) }
    public func info(_ msg: @autoclosure () -> String) { log(.info, msg()) }
    public func warning(_ msg: @autoclosure () -> String) { log(.warning, msg()) }
    public func error(_ msg: @autoclosure () -> String) { log(.error, msg()) }

    public func log(_ lvl: LogLevel, _ message: String) {
        guard lvl >= level else { return }
        lock.lock()
        defer { lock.unlock() }
        var msg = message
        for s in secrets { msg = msg.replacingOccurrences(of: s, with: "***") }
        seq += 1
        let entry = LogEntry(seq: seq, time: Date(), level: lvl, message: msg)
        ring.append(entry)
        if ring.count > ringSize { ring.removeFirst(ring.count - ringSize) }
        let line = "\(Self.stamp.string(from: entry.time)) \(lvl.name.padding(toLength: 7, withPad: " ", startingAt: 0)) pcosync: \(msg)\n"
        if echoToStderr { FileHandle.standardError.write(Data(line.utf8)) }
        writeFile(line)
    }

    public func entries(after: Int = 0, limit: Int = 500) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(ring.filter { $0.seq > after }.suffix(limit))
    }

    public var logFilePath: String? { fileURL?.path }

    // MARK: rotating file

    private func openFile() {
        guard let url = fileURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        file = try? FileHandle(forWritingTo: url)
        fileBytes = (try? file?.seekToEnd()) ?? 0
    }

    private func writeFile(_ line: String) {
        guard let file = file, let url = fileURL else { return }
        let data = Data(line.utf8)
        if fileBytes + UInt64(data.count) > maxBytes {
            try? file.close()
            let fm = FileManager.default
            let base = url.path
            try? fm.removeItem(atPath: "\(base).\(keep)")
            for n in stride(from: keep - 1, through: 1, by: -1) {
                try? fm.moveItem(atPath: "\(base).\(n)", toPath: "\(base).\(n + 1)")
            }
            try? fm.moveItem(atPath: base, toPath: "\(base).1")
            openFile()
        }
        self.file?.write(data)
        fileBytes += UInt64(data.count)
    }
}
