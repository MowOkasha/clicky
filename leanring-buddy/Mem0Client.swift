//
//  Mem0Client.swift
//  leanring-buddy
//
//  Communicates with the local Mem0 Python sidecar server (port 8769) to store
//  and retrieve persistent conversational memories.
//

import Foundation

@MainActor
class Mem0Client {
    static let shared = Mem0Client()
    
    private let baseURL = URL(string: "http://127.0.0.1:8769")!
    private let session: URLSession
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }
    
    /// Checks if the Mem0 sidecar is running and initialized.
    func isAvailable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2 // Fast timeout for health check
        
        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                return true
            }
        } catch {
            // Server is down or unreachable
        }
        return false
    }
    
    /// Adds a conversational exchange to Mem0.
    func addConversationToMemory(userTranscript: String, assistantResponse: String) {
        Task {
            var request = URLRequest(url: baseURL.appendingPathComponent("add"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let body: [String: Any] = [
                "user_id": "clicky_user",
                "messages": [
                    ["role": "user", "content": userTranscript],
                    ["role": "assistant", "content": assistantResponse]
                ]
            ]
            
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (_, response) = try await session.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    print("⚠️ Mem0Client: Failed to add memory (status \(httpResponse.statusCode))")
                }
            } catch {
                print("⚠️ Mem0Client: Network error adding memory: \(error)")
            }
        }
    }
    
    /// Searches for relevant past memories based on the current query.
    func searchRelevantMemories(forQuery query: String, limit: Int = 3) async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("search"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "user_id": "clicky_user",
            "query": query,
            "limit": limit
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("⚠️ Mem0Client: Search failed")
                return []
            }
            
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let results = json?["results"] as? [[String: Any]] else {
                return []
            }
            
            // Extract the 'memory' text from each result
            let memories = results.compactMap { $0["memory"] as? String }
            return memories
            
        } catch {
            print("⚠️ Mem0Client: Network error searching memory: \(error)")
            return []
        }
    }
}
