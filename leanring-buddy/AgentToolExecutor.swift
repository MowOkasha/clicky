//
//  AgentToolExecutor.swift
//  leanring-buddy
//
//  Executes agent tools by name when Ollama's model returns tool_calls.
//  Each tool takes a dictionary of arguments (from the model) and returns
//  a string result that is fed back to the model as a "tool" role message.
//

import AppKit
import Foundation
import ScreenCaptureKit

@MainActor
class AgentToolExecutor {

    // MARK: - Public Execution Entry Point

    /// Executes the named tool with the provided arguments and returns
    /// the result as a string to be fed back to the model.
    func execute(toolName: String, arguments: [String: Any]) async -> String {
        print("🔧 AgentToolExecutor: executing '\(toolName)' with args: \(arguments)")

        do {
            let result: String
            switch toolName {
            case "open_app":
                result = try await executeOpenApp(arguments: arguments)
            case "run_terminal_command":
                result = try await executeRunTerminalCommand(arguments: arguments)
            case "open_url":
                result = try await executeOpenURL(arguments: arguments)
            case "search_web":
                result = try await executeSearchWeb(arguments: arguments)
            case "read_webpage":
                result = try await executeReadWebpage(arguments: arguments)
            case "type_text":
                result = try await executeTypeText(arguments: arguments)
            case "take_screenshot":
                result = await executeTakeScreenshot()
            case "list_running_apps":
                result = executeListRunningApps()
            case "read_clipboard":
                result = executeReadClipboard()
            case "write_clipboard":
                result = try executeWriteClipboard(arguments: arguments)
            default:
                result = "Error: unknown tool '\(toolName)'"
            }

            print("🔧 AgentToolExecutor: '\(toolName)' result: \(result.prefix(200))")
            return result
        } catch {
            let errorMessage = "Error executing '\(toolName)': \(error.localizedDescription)"
            print("⚠️ AgentToolExecutor: \(errorMessage)")
            return errorMessage
        }
    }

    // MARK: - Tool Implementations

    /// Opens a macOS application by name using NSWorkspace.
    private func executeOpenApp(arguments: [String: Any]) async throws -> String {
        guard let appName = arguments["app_name"] as? String else {
            return "Error: missing 'app_name' argument"
        }

        // Try NSWorkspace first — looks in /Applications and other standard locations
        if NSWorkspace.shared.launchApplication(appName) {
            return "Successfully opened \(appName)"
        }

        // Fallback: use 'open -a' shell command for apps not found by NSWorkspace
        let result = try await runShellCommand("open -a \"\(appName)\"")
        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Successfully opened \(appName)"
        }
        return result
    }

    /// Executes a shell command via /bin/zsh and returns stdout+stderr.
    private func executeRunTerminalCommand(arguments: [String: Any]) async throws -> String {
        guard let command = arguments["command"] as? String else {
            return "Error: missing 'command' argument"
        }
        let output = try await runShellCommand(command)
        return output.isEmpty ? "(command produced no output)" : output
    }

    /// Opens a URL in the default browser.
    private func executeOpenURL(arguments: [String: Any]) async throws -> String {
        guard let urlString = arguments["url"] as? String,
              let url = URL(string: urlString) else {
            return "Error: missing or invalid 'url' argument"
        }
        NSWorkspace.shared.open(url)
        return "Opened \(urlString) in the default browser"
    }

    /// Searches DuckDuckGo and returns a plain-text summary of results.
    private func executeSearchWeb(arguments: [String: Any]) async throws -> String {
        guard let query = arguments["query"] as? String else {
            return "Error: missing 'query' argument"
        }

        // Encode query for URL
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return "Error: could not encode query"
        }

        // Use DuckDuckGo's JSON API for search results
        let searchURLString = "https://api.duckduckgo.com/?q=\(encodedQuery)&format=json&no_redirect=1&no_html=1&skip_disambig=1"
        guard let searchURL = URL(string: searchURLString) else {
            return "Error: could not construct search URL"
        }

        let (data, _) = try await URLSession.shared.data(from: searchURL)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Error: could not parse search results"
        }

        var resultLines: [String] = []

        // Extract the abstract (top-level summary, e.g. from Wikipedia)
        if let abstract = json["Abstract"] as? String, !abstract.isEmpty {
            resultLines.append("Summary: \(abstract)")
            if let abstractURL = json["AbstractURL"] as? String, !abstractURL.isEmpty {
                resultLines.append("Source: \(abstractURL)")
            }
        }

        // Extract related topics (search result snippets)
        if let relatedTopics = json["RelatedTopics"] as? [[String: Any]] {
            let snippets = relatedTopics.prefix(5).compactMap { topic -> String? in
                guard let text = topic["Text"] as? String else { return nil }
                let url = (topic["FirstURL"] as? String).map { " (\($0))" } ?? ""
                return "- \(text)\(url)"
            }
            if !snippets.isEmpty {
                resultLines.append("\nResults:")
                resultLines.append(contentsOf: snippets)
            }
        }

        if resultLines.isEmpty {
            // Fall back to a web search URL for the model to read
            return "No instant results found for '\(query)'. Try read_webpage with: https://duckduckgo.com/?q=\(encodedQuery)"
        }

        return resultLines.joined(separator: "\n")
    }

    /// Fetches a webpage and returns its text content, stripping HTML tags.
    private func executeReadWebpage(arguments: [String: Any]) async throws -> String {
        guard let urlString = arguments["url"] as? String,
              let url = URL(string: urlString) else {
            return "Error: missing or invalid 'url' argument"
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        urlRequest.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return "Error: could not fetch \(urlString)"
        }

        guard let htmlString = String(data: data, encoding: .utf8) ??
                               String(data: data, encoding: .isoLatin1) else {
            return "Error: could not decode page content"
        }

        // Strip HTML tags with a simple regex for readable text
        let strippedText = stripHTML(from: htmlString)

        // Truncate to avoid overwhelming the model context
        let maxCharacters = 8000
        if strippedText.count > maxCharacters {
            return String(strippedText.prefix(maxCharacters)) + "\n\n[Page truncated — \(strippedText.count) total characters]"
        }

        return strippedText.isEmpty ? "Page loaded but appears empty" : strippedText
    }

    /// Types text into the currently focused application using CGEvent keyboard simulation.
    private func executeTypeText(arguments: [String: Any]) async throws -> String {
        guard let text = arguments["text"] as? String else {
            return "Error: missing 'text' argument"
        }

        // Use AppleScript to type text — more reliable than CGEvent for unicode
        let escapedText = text.replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "tell application \"System Events\" to keystroke \"\(escapedText)\""
        let result = try await runShellCommand("osascript -e '\(appleScript)'")
        _ = result  // osascript returns empty on success

        return "Typed text: \(text.prefix(100))\(text.count > 100 ? "..." : "")"
    }

    /// Captures a fresh screenshot of all screens and returns a plain text
    /// description by re-running the model's built-in vision on the new capture.
    /// The actual image data is returned as a side channel via the stored property
    /// so the AgentLoop can attach it to the next model call.
    private func executeTakeScreenshot() async -> String {
        do {
            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            if captures.isEmpty {
                return "Error: could not capture any screens"
            }

            let screenList = captures.enumerated().map { index, capture in
                "Screen \(index + 1): \(capture.label) (\(capture.screenshotWidthInPixels)×\(capture.screenshotHeightInPixels)px)"
            }.joined(separator: "\n")

            // Signal to the AgentLoop that fresh screenshots are available.
            // The loop will attach these as images on the next model call so
            // the model can visually inspect the new state.
            self.lastCapturedScreenshots = captures

            return "Screenshot captured. Screens:\n\(screenList)\n\nI can now see the current state of your screen in the next message."
        } catch {
            return "Error capturing screenshot: \(error.localizedDescription)"
        }
    }

    /// Returns a list of currently running applications.
    private func executeListRunningApps() -> String {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }  // Only visible apps
            .compactMap { $0.localizedName }
            .sorted()

        if runningApps.isEmpty {
            return "No running applications found"
        }

        return "Running applications:\n" + runningApps.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Reads text content from the clipboard.
    private func executeReadClipboard() -> String {
        guard let clipboardText = NSPasteboard.general.string(forType: .string) else {
            return "Clipboard is empty or contains non-text content"
        }
        return "Clipboard contents:\n\(clipboardText)"
    }

    /// Writes text to the clipboard.
    private func executeWriteClipboard(arguments: [String: Any]) throws -> String {
        guard let text = arguments["text"] as? String else {
            return "Error: missing 'text' argument"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return "Copied to clipboard: \(text.prefix(100))\(text.count > 100 ? "..." : "")"
    }

    // MARK: - Screenshot Side Channel

    /// The most recently captured screenshots from a take_screenshot tool call.
    /// AgentLoop checks this after executing take_screenshot and includes the
    /// images in the next model call so the model can visually verify the result.
    var lastCapturedScreenshots: [CompanionScreenCapture] = []

    // MARK: - Private Helpers

    /// Runs a shell command via /bin/zsh and returns combined stdout + stderr.
    private func runShellCommand(_ command: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            // Run on a background thread so we don't block the main actor
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                    var combined = stdout
                    if !stderr.isEmpty {
                        combined += stderr.isEmpty ? "" : (combined.isEmpty ? stderr : "\n[stderr]: \(stderr)")
                    }

                    continuation.resume(returning: combined.trimmingCharacters(in: .newlines))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Strips HTML tags from a string, returning readable plain text.
    private func stripHTML(from html: String) -> String {
        // Remove script and style blocks entirely
        var text = html
        let scriptPattern = try? NSRegularExpression(pattern: "<(script|style)[^>]*>[\\s\\S]*?</(script|style)>", options: .caseInsensitive)
        if let regex = scriptPattern {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }

        // Replace block-level tags with newlines for readability
        let blockTagPattern = try? NSRegularExpression(pattern: "</(p|div|h[1-6]|li|br|tr)>", options: .caseInsensitive)
        if let regex = blockTagPattern {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n")
        }

        // Strip all remaining HTML tags
        let tagPattern = try? NSRegularExpression(pattern: "<[^>]+>")
        if let regex = tagPattern {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }

        // Decode common HTML entities
        text = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        // Collapse excessive whitespace
        let whitespacePattern = try? NSRegularExpression(pattern: "\n{3,}")
        if let regex = whitespacePattern {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n\n")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
