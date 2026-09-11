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
    You are a screen-reading assistant. Your ONLY job is to describe exactly what you see on the user's screen(s) — literally, precisely, and completely.

    Rules:
    - Transcribe ALL visible text VERBATIM. Do not paraphrase, summarize, or omit any text you can read.
    - Describe the layout and visual structure in plain language (e.g. "There is a code editor open, the file is named Foo.swift, and the cursor is on line 42").
    - Name the application and window title if visible.
    - For EVERY button, icon, folder, file, menu item, tab, or interactive element you see, describe it AND include its approximate pixel coordinates in the format: [x, y] where (0,0) is the top-left corner of the screenshot, x increases rightward, and y increases downward. Example: "There is a folder icon labeled 'Projects' at [450, 320]."
    - If there are multiple screens, describe each one separately.
    - Do NOT answer the user's question. ONLY describe what you see.
    - Do NOT invent, hallucinate, or guess any content. If you cannot clearly read a piece of text, say so (e.g. "some small text that is too small to read clearly").
    - Be thorough. It is better to over-describe than to miss something the user is asking about.
    - Use plain, natural language — no bullet-point templates or headers.
    """

    init() {
        self.visionAPI = OllamaAPI(model: visionModel)
    }

    /// Analyzes screenshots and returns a detailed literal description of the screen.
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
                userPrompt: "The user asked: \"\(userTranscript)\". Describe everything visible on the screen in detail, paying particular attention to anything relevant to their question.",
                temperature: 0.1
            )
            
            print("👁️ LocalVisionProcessor: Completed in \(String(format: "%.1f", duration))s")
            
            // Immediately unload the vision model to free up RAM/VRAM for the reasoning model.
            // Awaiting this ensures qwen2.5vl:7b is fully evicted before we return,
            // so deepseek-coder-v2:lite never loads while the vision model is still in RAM.
            await OllamaModelMemoryManager.shared.unloadModel(visionModel)
            
            return visionText
        } catch {
            print("⚠️ LocalVisionProcessor: Failed to analyze screenshots: \(error)")
            // Make sure we try to unload even if analysis fails
            await OllamaModelMemoryManager.shared.unloadModel(visionModel)
            throw error
        }
    }
}
