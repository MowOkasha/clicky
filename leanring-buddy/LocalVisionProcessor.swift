//
//  LocalVisionProcessor.swift
//  leanring-buddy
//
//  Processes screenshots through a local vision model (qwen2.5vl:7b) to generate
//  a structured text description of the screen content. This allows the main
//  reasoning model (deepseek-coder-v2:lite) to understand the screen without
//  needing its own vision capabilities.
//

import Foundation

@MainActor
class LocalVisionProcessor {
    private let visionAPI: OllamaAPI
    private let visionModel = "qwen2.5vl:7b"
    
    private let systemPrompt = """
    You are a screen analysis assistant. You are given screenshots of a user's computer screen(s) and their spoken request.
    Your job is to provide a highly detailed, structured text description of everything visible on the screen that is relevant to the user's request.
    
    Format your response exactly as follows:
    Screen Description:
    - App: [App name/Window title]
    - Important Text/Code: [Summarize any visible text, code, or terminal output]
    - Visible Elements: [List buttons, menus, icons, or UI elements relevant to the request]
    - Element Locations: [If the user is asking to click or find something, describe its approximate location, e.g., 'top-right corner', 'left sidebar']
    
    Do NOT answer the user's question. ONLY describe the screen content.
    """

    init() {
        self.visionAPI = OllamaAPI(model: visionModel)
    }

    /// Analyzes screenshots and returns a structured text description of the screen.
    func analyzeScreenshots(
        images: [(data: Data, label: String)],
        userTranscript: String
    ) async throws -> String {
        print("👁️ LocalVisionProcessor: Starting vision analysis with \(visionModel)...")
        
        do {
            let (visionText, duration) = try await visionAPI.analyzeImage(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: [],
                userPrompt: "The user said: \"\(userTranscript)\". Describe the screen content relevant to this."
            )
            
            print("👁️ LocalVisionProcessor: Completed in \(String(format: "%.1f", duration))s")
            
            // Immediately unload the vision model to free up RAM/VRAM for the reasoning model
            OllamaModelMemoryManager.shared.unloadModel(visionModel)
            
            return visionText
        } catch {
            print("⚠️ LocalVisionProcessor: Failed to analyze screenshots: \(error)")
            // Make sure we try to unload even if it fails
            OllamaModelMemoryManager.shared.unloadModel(visionModel)
            throw error
        }
    }
}
