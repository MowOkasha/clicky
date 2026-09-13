//
//  AgentToolDefinition.swift
//  leanring-buddy
//
//  Defines the schema for each tool that Clicky's agent can call.
//  These definitions are sent to Ollama in the `tools` field so the model
//  knows what tools are available and what arguments they accept.
//

import Foundation

/// A single tool available to Clicky's agent, with its name, description,
/// and JSON Schema for its parameters. These are sent directly to Ollama's
/// /api/chat endpoint in the `tools` array.
struct AgentToolDefinition {
    let name: String
    let description: String
    /// JSON Schema for this tool's parameters, in the format Ollama expects.
    let parameters: [String: Any]

    /// Converts this definition to the JSON dictionary format expected by
    /// Ollama's tool calling API.
    func toOllamaToolFormat() -> [String: Any] {
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters
            ] as [String: Any]
        ]
    }
}

// MARK: - All Available Tools

extension AgentToolDefinition {
    /// The complete set of tools available to Clicky's agent.
    static let allTools: [AgentToolDefinition] = [
        openApp,
        runTerminalCommand,
        openURL,
        searchWeb,
        readWebpage,
        typeText,
        takeScreenshot,
        listRunningApps,
        readClipboard,
        writeClipboard
    ]

    /// Returns all tool definitions in Ollama's JSON format, ready to embed in an API request.
    static func allToolsAsOllamaFormat() -> [[String: Any]] {
        return allTools.map { $0.toOllamaToolFormat() }
    }

    // MARK: - Individual Tool Definitions

    static let openApp = AgentToolDefinition(
        name: "open_app",
        description: "Opens a macOS application by name. Use this when the user wants to open or switch to an app like Safari, Finder, Xcode, Terminal, etc.",
        parameters: [
            "type": "object",
            "properties": [
                "app_name": [
                    "type": "string",
                    "description": "The name of the app to open, exactly as it appears in /Applications (e.g. 'Safari', 'Finder', 'Xcode', 'Terminal', 'Google Chrome')"
                ] as [String: Any]
            ] as [String: Any],
            "required": ["app_name"]
        ]
    )

    static let runTerminalCommand = AgentToolDefinition(
        name: "run_terminal_command",
        description: "Executes a shell command in /bin/zsh and returns the combined stdout and stderr output. Use for file operations, git commands, package management, searching the filesystem, or any other shell task. Do NOT use for opening apps (use open_app instead).",
        parameters: [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "description": "The shell command to run. Must be safe and reversible where possible. Example: 'ls ~/Desktop' or 'git status' or 'cat ~/.zshrc'"
                ] as [String: Any]
            ] as [String: Any],
            "required": ["command"]
        ]
    )

    static let openURL = AgentToolDefinition(
        name: "open_url",
        description: "Opens a URL in the default web browser. Use when the user wants to visit a specific website.",
        parameters: [
            "type": "object",
            "properties": [
                "url": [
                    "type": "string",
                    "description": "The full URL to open, including the scheme (e.g. 'https://google.com', 'https://github.com/ollama/ollama')"
                ] as [String: Any]
            ] as [String: Any],
            "required": ["url"]
        ]
    )

    static let searchWeb = AgentToolDefinition(
        name: "search_web",
        description: "Searches the web using DuckDuckGo and returns a summary of the top results. Use this to find current information, news, documentation, or answers to questions you don't know.",
        parameters: [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "The search query to look up (e.g. 'ollama tool calling swift', 'weather in Amman today')"
                ] as [String: Any]
            ] as [String: Any],
            "required": ["query"]
        ]
    )

    static let readWebpage = AgentToolDefinition(
        name: "read_webpage",
        description: "Fetches the text content of a webpage at a given URL. Use after search_web to read the full content of a result, or to read documentation, articles, or any webpage.",
        parameters: [
            "type": "object",
            "properties": [
                "url": [
                    "type": "string",
                    "description": "The full URL of the webpage to read (e.g. 'https://docs.ollama.com/api')"
                ] as [String: Any]
            ] as [String: Any],
            "required": ["url"]
        ]
    )

    static let typeText = AgentToolDefinition(
        name: "type_text",
        description: "Types text into the currently focused application, as if the user typed it on the keyboard. Use when the user wants to write something in a text field, terminal, editor, etc.",
        parameters: [
            "type": "object",
            "properties": [
                "text": [
                    "type": "string",
                    "description": "The text to type into the focused application"
                ] as [String: Any]
            ] as [String: Any],
            "required": ["text"]
        ]
    )

    static let takeScreenshot = AgentToolDefinition(
        name: "take_screenshot",
        description: "Captures a fresh screenshot of the user's current screen(s) and returns a description of what is now visible. Use this when you need to check the current state of the screen after performing an action.",
        parameters: [
            "type": "object",
            "properties": [:] as [String: Any],
            "required": []
        ]
    )

    static let listRunningApps = AgentToolDefinition(
        name: "list_running_apps",
        description: "Returns a list of all currently running applications. Use when you need to check if a specific app is open, or to see what the user has running.",
        parameters: [
            "type": "object",
            "properties": [:] as [String: Any],
            "required": []
        ]
    )

    static let readClipboard = AgentToolDefinition(
        name: "read_clipboard",
        description: "Reads and returns the current text content of the clipboard. Use when the user says 'what's in my clipboard' or wants you to work with copied content.",
        parameters: [
            "type": "object",
            "properties": [:] as [String: Any],
            "required": []
        ]
    )

    static let writeClipboard = AgentToolDefinition(
        name: "write_clipboard",
        description: "Writes text to the clipboard so the user can paste it. Use when you've generated content the user will want to paste somewhere.",
        parameters: [
            "type": "object",
            "properties": [
                "text": [
                    "type": "string",
                    "description": "The text to copy to the clipboard"
                ] as [String: Any]
            ] as [String: Any],
            "required": ["text"]
        ]
    )
}
