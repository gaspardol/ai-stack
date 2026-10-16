import Foundation

/// Tiny file logger: ~/Library/Logs/AIStack/aistack.log
enum Log {
    private static let queue = DispatchQueue(label: "aistack.log")
    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AIStack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("aistack.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size > 5_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String, _ category: String = "app") { write("INFO", category, message) }
    static func error(_ message: String, _ category: String = "app") { write("ERROR", category, message) }

    private static func write(_ level: String, _ category: String, _ message: String) {
        let date = Date()
        queue.async {
            let line = "\(formatter.string(from: date)) [\(level)] [\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
