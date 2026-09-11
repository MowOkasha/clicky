//
//  OllamaModelMemoryManager.swift
//  leanring-buddy
//
//  Manages Ollama model memory by explicitly unloading models when they are no longer needed,
//  using the keep_alive: 0 parameter on the /api/generate endpoint.
//

import Foundation

@MainActor
class OllamaModelMemoryManager {
    static let shared = OllamaModelMemoryManager()
    
    private let apiURL = URL(string: "http://localhost:11434/api/generate")!
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    /// Unloads a specific model from Ollama's memory immediately.
    func unloadModel(_ model: String) {
        Task {
            var request = URLRequest(url: apiURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "model": model,
                "keep_alive": 0
            ]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                print("🧹 OllamaModelMemoryManager: Unloading model '\(model)' from memory...")
                let (data, response) = try await session.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                    print("✅ OllamaModelMemoryManager: Successfully unloaded '\(model)'")
                } else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    print("⚠️ OllamaModelMemoryManager: Failed to unload '\(model)'. Error: \(errorBody)")
                }
            } catch {
                print("⚠️ OllamaModelMemoryManager: Network error while unloading '\(model)': \(error.localizedDescription)")
            }
        }
    }
}
