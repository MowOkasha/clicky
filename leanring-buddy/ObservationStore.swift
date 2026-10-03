//
//  ObservationStore.swift
//  leanring-buddy
//
//  External working memory for Clicky: stores large tool outputs (curl responses,
//  file reads, directory listings) on disk in ~/Library/Caches/Clicky/obs/.
//  The model receives a compact 1-line handle and preview in prompt action history,
//  keeping context window token usage bounded and deterministic.
//

import Foundation

class ObservationStore {
    static let shared = ObservationStore()

    private let cacheDirectory: URL
    private var counter: Int = 0
    private let lock = NSLock()

    init() {
        let fileManager = FileManager.default
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = cachesURL.appendingPathComponent("Clicky/obs", isDirectory: true)
        try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    /// Stores raw tool output to disk and returns a short handle (e.g. "obs_1")
    /// along with a compact 1-line preview for the prompt action history.
    func store(toolOutput: String) -> (handle: String, compactSummary: String, filePath: String) {
        lock.lock()
        defer { lock.unlock() }

        counter += 1
        let handle = "obs_\(counter)"
        let fileURL = cacheDirectory.appendingPathComponent("\(handle).txt")

        try? toolOutput.data(using: .utf8)?.write(to: fileURL)

        // Generate a clean single-line preview (max 90 chars, newlines collapsed)
        let singleLine = toolOutput
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let preview = singleLine.count > 90
            ? "\(singleLine.prefix(87))..."
            : singleLine

        let byteCount = toolOutput.utf8.count
        let sizeDescription = byteCount > 1024 ? "\(byteCount / 1024)KB" : "\(byteCount)B"
        let compactSummary = "[\(sizeDescription) -> \(handle)] \"\(preview)\""

        return (handle, compactSummary, fileURL.path)
    }

    /// Reads full output for a handle from disk if needed.
    func read(handle: String) -> String? {
        let fileURL = cacheDirectory.appendingPathComponent("\(handle).txt")
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    /// Resets the observation counter and clears cached files for a new task session.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        counter = 0
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}
