//
//  OllamaAPI.swift
//  leanring-buddy
//
//  Ollama API client supporting streaming chat with native tool calling.
//  Images (screenshots) are sent as base64 alongside the user prompt so
//  the single vision-language model (qwen3.5:9b-q5) can see the screen.
//

import Foundation

/// A tool_call returned by Ollama when the model wants to invoke a tool.
struct OllamaToolCall: Sendable {
    let toolCallID: String
    let functionName: String
    let arguments: [String: Any]
}

/// Result of one streaming chat call — either the model produced text,
/// or it returned tool calls that the agent loop must execute before
/// the model can produce its final response.
enum OllamaStreamResult: Sendable {
    /// The model generated a final text response (no tool calls).
    case textResponse(text: String, duration: TimeInterval)
    /// The model wants to call one or more tools before continuing.
    case toolCallsRequested(toolCalls: [OllamaToolCall], duration: TimeInterval)
}

/// Ollama API helper with streaming and native tool calling support.
class OllamaAPI {
    private let apiURL: URL
    var model: String
    private let session: URLSession

    init(model: String = "qwen3.5:9b-q5") {
        self.apiURL = URL(string: "http://localhost:11434/api/chat")!
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300  // Long timeout for multi-step agentic tasks
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: - Streaming Chat (with optional tool calling)

    /// Sends a chat request to Ollama with optional tool definitions and screenshot images.
    /// 
    /// If `tools` is non-empty, Ollama may return `tool_calls` instead of text.
    /// The caller (AgentLoop) is responsible for executing tool calls and sending
    /// results back for the next iteration.
    ///
    /// `onTextChunk` is called on the main actor as streaming text arrives.
    /// Returns either a final text response or a list of tool calls to execute.
    func chat(
        images: [(data: Data, label: String)] = [],
        systemPrompt: String,
        conversationHistory: [(role: String, content: String)] = [],
        userPrompt: String,
        tools: [[String: Any]] = [],
        temperature: Double? = nil,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> OllamaStreamResult {
        return try await GlobalOllamaLock.shared.withLock {
            let startTime = Date()

            var request = makeAPIRequest()

            // Build the messages array
            var messages: [[String: Any]] = []

            if !systemPrompt.isEmpty {
                messages.append(["role": "system", "content": systemPrompt])
            }

            // Inject conversation history (role is already "user", "assistant", or "tool")
            for entry in conversationHistory {
                messages.append(["role": entry.role, "content": entry.content])
            }

            // Build the current user message, attaching screenshots as base64
            var contentText = ""
            var base64Images: [String] = []

            if !images.isEmpty {
                var imageContext = "Screenshots of the user's screen:\n"
                for (index, image) in images.enumerated() {
                    imageContext += "Screen \(index + 1): \(image.label)\n"
                    base64Images.append(image.data.base64EncodedString())
                }
                contentText += imageContext + "\n"
            }

            contentText += userPrompt

            var userMessage: [String: Any] = [
                "role": "user",
                "content": contentText
            ]

            if !base64Images.isEmpty {
                userMessage["images"] = base64Images
            }

            messages.append(userMessage)

            // Assemble the request body
            var body: [String: Any] = [
                "model": model,
                "stream": true,
                "messages": messages
            ]

            if !tools.isEmpty {
                body["tools"] = tools
            }

            if let temp = temperature {
                body["options"] = ["temperature": temp]
            }

            let bodyData = try JSONSerialization.data(withJSONObject: body)
            request.httpBody = bodyData
            let payloadMB = Double(bodyData.count) / 1_048_576.0
            print("🌐 Ollama chat: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), \(tools.count) tool(s)")

            let (byteStream, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(
                    domain: "OllamaAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
                )
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                var errorBodyChunks: [String] = []
                for try await line in byteStream.lines {
                    errorBodyChunks.append(line)
                }
                let errorBody = errorBodyChunks.joined(separator: "\n")
                throw NSError(
                    domain: "OllamaAPI",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Ollama error (\(httpResponse.statusCode)): \(errorBody)"]
                )
            }

            var accumulatedResponseText = ""
            // Ollama accumulates tool_calls across chunks — we collect the full
            // tool call list from the final "done: true" message.
            var collectedToolCalls: [[String: Any]] = []

            for try await line in byteStream.lines {
                guard !line.isEmpty else { continue }

                guard let jsonData = line.data(using: .utf8),
                      let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    continue
                }

                let isDone = (eventPayload["done"] as? Bool) == true

                if let message = eventPayload["message"] as? [String: Any] {
                    // Accumulate streamed text content
                    if let textChunk = message["content"] as? String, !textChunk.isEmpty {
                        accumulatedResponseText += textChunk
                        let snapshot = accumulatedResponseText
                        await onTextChunk(snapshot)
                    }

                    // Collect tool_calls from the final message
                    if isDone, let toolCalls = message["tool_calls"] as? [[String: Any]] {
                        collectedToolCalls = toolCalls
                    }
                }

                if isDone { break }
            }

            let duration = Date().timeIntervalSince(startTime)

            // If the model returned tool calls, parse them for the agent loop
            if !collectedToolCalls.isEmpty {
                let parsedToolCalls = collectedToolCalls.compactMap { rawToolCall -> OllamaToolCall? in
                    guard let function_ = rawToolCall["function"] as? [String: Any],
                          let name = function_["name"] as? String else { return nil }

                    // Arguments may be a JSON string or already a dictionary
                    let arguments: [String: Any]
                    if let argsDict = function_["arguments"] as? [String: Any] {
                        arguments = argsDict
                    } else if let argsString = function_["arguments"] as? String,
                              let argsData = argsString.data(using: .utf8),
                              let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                        arguments = argsDict
                    } else {
                        arguments = [:]
                    }

                    // Ollama does not always provide an ID — generate one if missing
                    let toolCallID = rawToolCall["id"] as? String ?? UUID().uuidString

                    return OllamaToolCall(
                        toolCallID: toolCallID,
                        functionName: name,
                        arguments: arguments
                    )
                }

                print("🔧 Ollama returned \(parsedToolCalls.count) tool call(s): \(parsedToolCalls.map { $0.functionName }.joined(separator: ", "))")
                return .toolCallsRequested(toolCalls: parsedToolCalls, duration: duration)
            }

            return .textResponse(text: accumulatedResponseText, duration: duration)
        }
    }
}
