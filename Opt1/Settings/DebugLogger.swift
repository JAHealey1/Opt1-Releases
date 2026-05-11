import Foundation

// MARK: - DebugLogger

/// Writes log lines to a file inside the debug folder when debug mode is enabled.
/// Thread-safe via a dedicated serial queue. Truncates the log file in place
/// once it exceeds `maxFileSize` bytes so disk usage stays bounded to a single
/// file without accumulating rotated backups.
/// @unchecked Sendable: all mutable state is accessed exclusively on `queue`
/// (a serial DispatchQueue), which provides the required mutual exclusion.
final class DebugLogger: @unchecked Sendable {

    static let shared = DebugLogger()
    private init() {}

    private let queue = DispatchQueue(label: "com.opt1.debuglog", qos: .utility)
    private var fileHandle: FileHandle?

    /// Accessed only from `queue`; reused across writes to avoid rebuilding the
    /// formatter on every log line (formatter construction is expensive).
    private lazy var timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return f
    }()

    /// Reset the log in place once it crosses this threshold to keep disk
    /// usage bounded to a single file.
    private let maxFileSize: UInt64 = 10 * 1024 * 1024

    private var logURL: URL {
        AppSettings.debugFolder.appendingPathComponent("opt1.log")
    }

    /// Appends `message` to the on-disk log file if debug mode is currently enabled.
    /// Safe to call from any thread.
    func appendIfEnabled(_ message: String) {
        guard AppSettings.isDebugEnabled else { return }
        queue.async { [self] in write(message) }
    }

    private func write(_ message: String) {
        let timestamped = "[\(timestampFormatter.string(from: Date()))] \(message)\n"
        let data = Data(timestamped.utf8)

        if fileHandle == nil {
            openFileHandle()
        }

        fileHandle?.write(data)
        truncateIfNeeded()
    }

    private func openFileHandle() {
        let fm = FileManager.default
        let folder = AppSettings.debugFolder
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // Remove any legacy rotated backup left over from the old rotation
        // policy so the debug folder doesn't carry stale files forever.
        try? fm.removeItem(at: folder.appendingPathComponent("opt1.log.1"))

        let url = logURL
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()

        let header = Data("── Session started \(timestampFormatter.string(from: Date())) ──\n".utf8)
        fileHandle?.write(header)
    }

    private func truncateIfNeeded() {
        guard let fh = fileHandle,
              let size = try? fh.offset(),
              size >= maxFileSize else { return }

        // Reset the file to zero bytes and keep writing through the same
        // handle — no rotated backups, no reopen dance.
        try? fh.truncate(atOffset: 0)
        try? fh.seek(toOffset: 0)

        let mb = maxFileSize / (1024 * 1024)
        let header = Data("── Log truncated at \(mb)MB — restarted \(timestampFormatter.string(from: Date())) ──\n".utf8)
        fh.write(header)
    }

    func closeFile() {
        queue.sync { [self] in
            fileHandle?.closeFile()
            fileHandle = nil
        }
    }
}

// MARK: - Module-level print shadow
//
// Shadows Swift.print for the entire Opt1 module so that every existing
// print() call is automatically captured to the debug log file when debug
// mode is enabled. Console output is always preserved — callers don't need
// any changes. To reach the real Swift print, use Swift.print(...).

func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let output = items.map { "\($0)" }.joined(separator: separator)
    Swift.print(output, terminator: terminator)
    DebugLogger.shared.appendIfEnabled(output)
}
