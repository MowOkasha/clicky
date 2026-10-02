//
//  OMLXClient.swift
//  leanring-buddy
//
//  Client for talking to the local oMLX model server at http://localhost:8000/v1.
//  oMLX provides an OpenAI-compatible API serving:
//    - Generative Model (Planner & Actor): qwen3.5-9b (pinned, always resident)
//    - Embedder: qwen3-embedding-0.6b (pinned, always resident)
//

import Foundation

/// Represents a role in an OpenAI-compatible chat completion conversation.
enum OMLXChatRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}

/// Content payload within a chat completion message.
/// Supports both plain text and multimodal content (text + base64 image data).
enum OMLXMessageContent {
    case text(String)
    case multimodal(text: String, base64ImageData: [String])

    func encodeToOpenAIFormat() -> Any {
        switch self {
        case .text(let textContent):
            return textContent
        case .multimodal(let textContent, let base64ImageDataArray):
            var contentParts: [[String: Any]] = [
                [
                    "type": "text",
                    "text": textContent
                ]
            ]
            for base64ImageData in base64ImageDataArray {
                contentParts.append([
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/jpeg;base64,\(base64ImageData)"
                    ]
                ])
            }
            return contentParts
        }
    }
}

/// A single message passed to the chat completion endpoint.
struct OMLXChatMessage {
    let role: OMLXChatRole
    let content: OMLXMessageContent

    init(role: OMLXChatRole, text: String) {
        self.role = role
        self.content = .text(text)
    }

    init(role: OMLXChatRole, text: String, base64ImageData: [String]) {
        self.role = role
        if base64ImageData.isEmpty {
            self.content = .text(text)
        } else {
            self.content = .multimodal(text: text, base64ImageData: base64ImageData)
        }
    }
}

/// Result returned from an oMLX chat completion call.
struct OMLXChatCompletionResponse {
    /// Raw textual content returned by the assistant.
    let contentText: String
    /// Optional structured tool calls returned by an OpenAI-compatible server.
    let toolCalls: [OMLXRawToolCall]
    /// Total duration of the network request.
    let requestDuration: TimeInterval
    /// Number of tokens in the prompt sent to the model (from oMLX usage field).
    let promptTokens: Int
    /// Number of tokens in the model's completion response (from oMLX usage field).
    let completionTokens: Int
}

/// Structure representing a tool call emitted by an OpenAI-compatible API.
struct OMLXRawToolCall: Codable {
    let id: String
    let type: String
    let function: OMLXRawFunctionCall
}

struct OMLXRawFunctionCall: Codable {
    let name: String
    let arguments: String
}

/// Client that manages HTTP communication with the local oMLX OpenAI-compatible endpoints.
actor OMLXClient {

    // MARK: - Constants & Aliases

    /// Base URL for the oMLX OpenAI-compatible endpoints.
    let serverBaseURL: URL

    /// URLSession instance used for network requests.
    private let urlSession: URLSession

    /// Model alias for the actor / execution model (pinned, resident).
    static let actorModelAlias: String = "qwen3.5-9b"

    /// Model alias for the planner model (pinned, resident).
    static let plannerModelAlias: String = "qwen3.5-9b"

    /// Model alias for the embedding model (pinned, resident).
    /// In oMLX, Qwen3-Embedding-0.6B is registered as "qwen3-embed".
    static let embedderModelAlias: String = "qwen3-embed"

    /// Cached API key.
    private var cachedAPIKey: String?

    // MARK: - Initialization

    init(serverBaseURL: URL = URL(string: "http://localhost:8000/v1")!) {
        self.serverBaseURL = serverBaseURL

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180.0
        configuration.timeoutIntervalForResource = 300.0
        self.urlSession = URLSession(configuration: configuration)
    }

    // MARK: - API Key Resolution

    /// Resolves the oMLX API key by checking explicit configuration, UserDefaults,
    /// environment variables, and reading ~/.omlx/settings.json created during initial setup.
    func resolveAPIKey() -> String? {
        if let key = cachedAPIKey, !key.isEmpty { return key }
        if let key = UserDefaults.standard.string(forKey: "omlxApiKey"), !key.isEmpty {
            self.cachedAPIKey = key
            return key
        }
        if let key = ProcessInfo.processInfo.environment["OMLX_API_KEY"], !key.isEmpty {
            self.cachedAPIKey = key
            return key
        }

        // Auto-discover from ~/.omlx/settings.json
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let settingsURL = homeDirectory.appendingPathComponent(".omlx/settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let authDict = json["auth"] as? [String: Any],
           let apiKey = authDict["api_key"] as? String, !apiKey.isEmpty {
            self.cachedAPIKey = apiKey
            print("🔑 OMLXClient: Auto-discovered API key from ~/.omlx/settings.json")
            return apiKey
        }

        return nil
    }

    // MARK: - Chat Completions

    /// Sends a chat completion request to oMLX and returns the assistant's response.
    ///
    /// - Parameters:
    ///   - model: Model alias to invoke (e.g. `qwen3.5-4b` or `qwen3.5-9b`).
    ///   - messages: Array of chat messages (system, user, assistant).
    ///   - temperature: Sampling temperature (defaults to 0.0 for deterministic grounding).
    ///   - maxTokens: Optional maximum output tokens.
    ///   - enableThinking: Whether reasoning/thinking mode is allowed (defaults to true; set false for fast planning).
    /// - Returns: An `OMLXChatCompletionResponse` with text and parsed tool calls.
    func sendChatCompletionRequest(
        model: String,
        messages: [OMLXChatMessage],
        temperature: Double = 0.0,
        maxTokens: Int? = nil,
        enableThinking: Bool = true
    ) async throws -> OMLXChatCompletionResponse {
        let endpointURL = serverBaseURL.appendingPathComponent("chat/completions")
        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = resolveAPIKey() {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // Build serialized messages array
        var serializedMessages: [[String: Any]] = []
        for message in messages {
            serializedMessages.append([
                "role": message.role.rawValue,
                "content": message.content.encodeToOpenAIFormat()
            ])
        }

        var requestBody: [String: Any] = [
            "model": model,
            "messages": serializedMessages,
            "temperature": temperature,
            "stream": false
        ]

        if let maxTokens = maxTokens {
            requestBody["max_tokens"] = maxTokens
        }

        if !enableThinking {
            requestBody["enable_thinking"] = false
            requestBody["chat_template_kwargs"] = ["enable_thinking": false]
        }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let startTime = Date()
        let (data, httpResponse) = try await urlSession.data(for: urlRequest)
        let duration = Date().timeIntervalSince(startTime)

        guard let httpURLResponse = httpResponse as? HTTPURLResponse else {
            throw NSError(
                domain: "OMLXClientError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response received from oMLX server"]
            )
        }

        guard (200...299).contains(httpURLResponse.statusCode) else {
            let responseBodyString = String(data: data, encoding: .utf8) ?? "Unknown server error"
            throw NSError(
                domain: "OMLXClientError",
                code: httpURLResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "oMLX server returned HTTP \(httpURLResponse.statusCode): \(responseBodyString)"]
            )
        }

        // Parse standard OpenAI chat completion JSON response
        guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = jsonObject["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let messagePayload = firstChoice["message"] as? [String: Any] else {
            throw NSError(
                domain: "OMLXClientError",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse OpenAI choices payload from oMLX response"]
            )
        }

        let contentText = messagePayload["content"] as? String ?? ""

        // Extract token usage from the OpenAI-compatible usage field oMLX returns
        let usagePayload = jsonObject["usage"] as? [String: Any]
        let promptTokenCount = usagePayload?["prompt_tokens"] as? Int ?? 0
        let completionTokenCount = usagePayload?["completion_tokens"] as? Int ?? 0

        var parsedToolCalls: [OMLXRawToolCall] = []
        if let rawToolCallsArray = messagePayload["tool_calls"] as? [[String: Any]] {
            for rawToolCallDictionary in rawToolCallsArray {
                if let toolCallID = rawToolCallDictionary["id"] as? String,
                   let toolType = rawToolCallDictionary["type"] as? String,
                   let functionDict = rawToolCallDictionary["function"] as? [String: Any],
                   let functionName = functionDict["name"] as? String,
                   let functionArguments = functionDict["arguments"] as? String {
                    let toolCall = OMLXRawToolCall(
                        id: toolCallID,
                        type: toolType,
                        function: OMLXRawFunctionCall(name: functionName, arguments: functionArguments)
                    )
                    parsedToolCalls.append(toolCall)
                }
            }
        }

        return OMLXChatCompletionResponse(
            contentText: contentText,
            toolCalls: parsedToolCalls,
            requestDuration: duration,
            promptTokens: promptTokenCount,
            completionTokens: completionTokenCount
        )
    }

    // MARK: - Embeddings

    /// Generates a vector embedding for the provided text using the embedding model.
    ///
    /// - Parameters:
    ///   - textToEmbed: The string to generate an embedding for.
    ///   - model: The model alias (defaults to `qwen3-embedding-0.6b`).
    /// - Returns: An array of Floats representing the embedding vector.
    func generateEmbeddingVector(
        for textToEmbed: String,
        model: String = OMLXClient.embedderModelAlias
    ) async throws -> [Float] {
        let endpointURL = serverBaseURL.appendingPathComponent("embeddings")
        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = resolveAPIKey() {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let requestBody: [String: Any] = [
            "model": model,
            "input": textToEmbed
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, httpResponse) = try await urlSession.data(for: urlRequest)

        guard let httpURLResponse = httpResponse as? HTTPURLResponse,
              (200...299).contains(httpURLResponse.statusCode) else {
            let responseBodyString = String(data: data, encoding: .utf8) ?? "Unknown server error"
            throw NSError(
                domain: "OMLXClientError",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to generate embedding: \(responseBodyString)"]
            )
        }

        guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = jsonObject["data"] as? [[String: Any]],
              let firstEntry = dataArray.first,
              let embeddingFloats = firstEntry["embedding"] as? [Double] else {
            throw NSError(
                domain: "OMLXClientError",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse embedding vector from response"]
            )
        }

        return embeddingFloats.map { Float($0) }
    }

    // MARK: - Admin Endpoints & Model Swapping (Mutual Exclusion: 4B vs 9B)

    private var adminBaseURL: URL {
        return serverBaseURL.deletingLastPathComponent().appendingPathComponent("admin/api")
    }

    private var hasAuthenticatedAdminSession: Bool = false

    /// Logs into the oMLX admin API using the configured API key to obtain a session cookie.
    private func ensureAdminSession() async {
        guard !hasAuthenticatedAdminSession else { return }
        guard let apiKey = resolveAPIKey(), !apiKey.isEmpty else { return }

        let loginURL = adminBaseURL.appendingPathComponent("login")
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ["api_key": apiKey]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        if let (_, response) = try? await urlSession.data(for: request),
           let httpResponse = response as? HTTPURLResponse,
           (200...299).contains(httpResponse.statusCode) {
            hasAuthenticatedAdminSession = true
            print("🔑 OMLXClient: Authenticated with oMLX admin session")
        }
    }

    /// Sets the pinned status of a model in oMLX via PUT /admin/api/models/{model_id}/settings.
    func setPinStatus(modelId: String, isPinned: Bool) async throws {
        await ensureAdminSession()

        let settingsURL = adminBaseURL.appendingPathComponent("models").appendingPathComponent(modelId).appendingPathComponent("settings")
        var request = URLRequest(url: settingsURL)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = resolveAPIKey() {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let payload: [String: Any] = ["is_pinned": isPinned]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                print("📌 OMLXClient: Updated \(modelId) pinned status to \(isPinned) via admin API")
            } else {
                print("⚠️ OMLXClient: Admin API status for \(modelId) pin update")
            }
        } catch {
            print("⚠️ OMLXClient: Network error setting pin for \(modelId): \(error)")
        }

        // Also persist directly to disk (~/.omlx/model_settings.json) as guaranteed fallback
        persistPinStatusToDisk(modelId: modelId, isPinned: isPinned)
    }

    /// Explicitly unloads an idle model from oMLX via POST /admin/api/models/{model_id}/unload.
    func unloadModel(modelId: String) async throws {
        await ensureAdminSession()

        let unloadURL = adminBaseURL.appendingPathComponent("models").appendingPathComponent(modelId).appendingPathComponent("unload")
        var request = URLRequest(url: unloadURL)
        request.httpMethod = "POST"
        if let apiKey = resolveAPIKey() {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 400 {
                print("🧹 OMLXClient: Unloaded \(modelId) from memory")
            }
        } catch {
            print("⚠️ OMLXClient: Network error unloading \(modelId): \(error)")
        }
    }

    /// In single-model mode (9B only), the 9B model handles both planning and execution.
    /// No swapping is performed, eliminating model reload latency.
    func swapToPlanner() async throws {
        try await setPinStatus(modelId: OMLXClient.plannerModelAlias, isPinned: true)
    }

    /// In single-model mode (9B only), the 9B model handles both planning and execution.
    /// No swapping is performed, eliminating model reload latency.
    func swapToActor() async throws {
        try await setPinStatus(modelId: OMLXClient.actorModelAlias, isPinned: true)
    }

    /// Enforces the idle baseline at startup: Embedder pinned, 9B pinned, and legacy 4B unpinned & unloaded.
    func ensureIdleModelConfiguration() async {
        print("🛡️ OMLXClient: Enforcing single-model baseline (qwen3.5-9b pinned, 4b evicted)...")
        // Ensure 4B model is evicted if left over from previous multi-model runs
        try? await setPinStatus(modelId: "qwen3.5-4b", isPinned: false)
        try? await unloadModel(modelId: "qwen3.5-4b")

        // Ensure 9B and embedder are pinned
        try? await setPinStatus(modelId: OMLXClient.embedderModelAlias, isPinned: true)
        try? await setPinStatus(modelId: OMLXClient.actorModelAlias, isPinned: true)
    }

    /// Runtime assertion: ensures 4B is not pinned and 9B is active.
    func assertSingleLLMResident(activeLLM: String) async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let modelSettingsURL = homeDirectory.appendingPathComponent(".omlx/model_settings.json")
        guard let data = try? Data(contentsOf: modelSettingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [String: [String: Any]] else {
            return
        }

        let is4BPinned = (models["qwen3.5-4b"]?["is_pinned"] as? Bool) ?? false
        if is4BPinned {
            print("🛡️ OMLXClient: Evicting legacy 4B model from pinned state...")
            try? await setPinStatus(modelId: "qwen3.5-4b", isPinned: false)
            try? await unloadModel(modelId: "qwen3.5-4b")
        }
    }

    private func persistPinStatusToDisk(modelId: String, isPinned: Bool) {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let modelSettingsURL = homeDirectory.appendingPathComponent(".omlx/model_settings.json")
        guard let data = try? Data(contentsOf: modelSettingsURL),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var models = json["models"] as? [String: [String: Any]] else {
            return
        }

        var modelDict = models[modelId] ?? [:]
        modelDict["is_pinned"] = isPinned
        models[modelId] = modelDict
        json["models"] = models

        if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? updatedData.write(to: modelSettingsURL)
        }
    }
}
