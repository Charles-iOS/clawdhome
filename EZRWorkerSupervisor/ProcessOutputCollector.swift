import Foundation

final class ProcessOutputCollector {
    private let lock = NSLock()
    private var data = Data()
    private var logHandle: FileHandle?

    func attach(to pipe: Pipe, teeTo logURL: URL? = nil) {
        if let logURL {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: logURL)
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.append(chunk)
        }
    }

    func finishReading(from pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = nil
        let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
        append(remaining)
        closeLogFile()
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        logHandle?.write(chunk)
        lock.unlock()
    }

    private func closeLogFile() {
        lock.lock()
        let handle = logHandle
        logHandle = nil
        lock.unlock()
        try? handle?.close()
    }
}
