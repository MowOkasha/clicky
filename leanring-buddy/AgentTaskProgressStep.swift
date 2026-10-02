//
//  AgentTaskProgressStep.swift
//  leanring-buddy
//
//  Data model representing an individual execution step within an agentic task.
//  Used by the task progress dock to show live status of tools running.
//

import Foundation

public struct AgentTaskProgressStep: Identifiable, Sendable {
    public let id: UUID
    public let toolName: String
    public let summary: String
    public var isComplete: Bool
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        toolName: String,
        summary: String,
        isComplete: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.isComplete = isComplete
        self.timestamp = timestamp
    }

    /// Formats a human-readable summary for a tool call based on its name and arguments.
    public static func createSummary(toolName: String, arguments: [String: Any]) -> String {
        switch toolName {
        case "open_app":
            if let appName = arguments["app_name"] as? String, !appName.isEmpty {
                return "Opening \(appName)"
            }
            return "Opening app"

        case "run_terminal_command":
            if let command = arguments["command"] as? String, !command.isEmpty {
                let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                let singleLine = trimmed.replacingOccurrences(of: "\n", with: " ")
                let displayCommand = singleLine.count > 35 ? "\(singleLine.prefix(32))..." : singleLine
                return "Running: \(displayCommand)"
            }
            return "Running terminal command"

        case "open_url":
            if let urlString = arguments["url"] as? String, !urlString.isEmpty {
                if let url = URL(string: urlString), let host = url.host {
                    return "Opening \(host)"
                }
                let display = urlString.count > 35 ? "\(urlString.prefix(32))..." : urlString
                return "Opening \(display)"
            }
            return "Opening URL"

        case "search_web":
            if let query = arguments["query"] as? String, !query.isEmpty {
                let display = query.count > 30 ? "\(query.prefix(27))..." : query
                return "Searching: \"\(display)\""
            }
            return "Searching the web"

        case "read_webpage":
            if let urlString = arguments["url"] as? String, !urlString.isEmpty {
                if let url = URL(string: urlString), let host = url.host {
                    return "Reading \(host)"
                }
                return "Reading webpage"
            }
            return "Reading webpage"

        case "type_text":
            if let text = arguments["text"] as? String, !text.isEmpty {
                let display = text.count > 25 ? "\(text.prefix(22))..." : text
                return "Typing: \"\(display)\""
            }
            return "Typing text"

        case "take_screenshot":
            return "Analyzing screen"

        case "list_running_apps":
            return "Checking running apps"

        case "read_clipboard":
            return "Reading clipboard"

        case "write_clipboard":
            return "Copying to clipboard"

        default:
            let friendlyName = toolName
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return friendlyName
        }
    }
}
