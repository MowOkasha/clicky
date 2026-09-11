//
//  OllamaAPI.swift
//  leanring-buddy
//
//  Ollama API Implementation with streaming support
//

import Foundation

/// Ollama API helper with streaming for progressive text display.
class OllamaAPI {
    private let apiURL: URL
    var model: String
    private let session: URLSession

    init(model: String = "deepseek-coder-v2:lite") {
        self.apiURL = URL(string: "http://localhost:11434/api/chat")!
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Send a request to Ollama with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        temperature: Double? = nil,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        return try await GlobalOllamaLock.shared.withLock {
            let startTime = Date()

        var request = makeAPIRequest()

        // Build messages array
        var messages: [[String: Any]] = []

        if !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with images + prompt
        var contentText = ""
        var base64Images: [String] = []
        
        if !images.isEmpty {
            var imageContext = "Here are the images provided:\n"
            for (index, image) in images.enumerated() {
                imageContext += "Image \(index + 1) label: \(image.label)\n"
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

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages
        ]
        
        if let temp = temperature {
            body["options"] = ["temperature": temp]
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Ollama streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

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
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            guard !line.isEmpty else { continue }
            
            guard let jsonData = line.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }
            
            if let isDone = eventPayload["done"] as? Bool, isDone {
                break
            }

            if let message = eventPayload["message"] as? [String: Any],
               let textChunk = message["content"] as? String {
                accumulatedResponseText += textChunk
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }
        }

            let duration = Date().timeIntervalSince(startTime)
            return (text: accumulatedResponseText, duration: duration)
        }
    }

    /// Non-streaming fallback for validation requests where we don't need progressive display.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        temperature: Double? = nil
    ) async throws -> (text: String, duration: TimeInterval) {
        return try await GlobalOllamaLock.shared.withLock {
            let startTime = Date()

        var request = makeAPIRequest()

        var messages: [[String: Any]] = []

        if !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        var contentText = ""
        var base64Images: [String] = []
        
        if !images.isEmpty {
            var imageContext = "Here are the images provided:\n"
            for (index, image) in images.enumerated() {
                imageContext += "Image \(index + 1) label: \(image.label)\n"
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

        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": messages
        ]
        
        if let temp = temperature {
            body["options"] = ["temperature": temp]
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Ollama request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "OllamaAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let message = json?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw NSError(
                domain: "OllamaAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

            let duration = Date().timeIntervalSince(startTime)
            return (text: text, duration: duration)
        }
    }
}
