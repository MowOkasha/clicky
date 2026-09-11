//
//  ElementLocationDetector.swift
//  leanring-buddy
//
//  Uses qwen2.5vl:7b (via local Ollama) to identify the screen location of UI
//  elements in screenshots. When a user asks about a visible element (e.g.,
//  "click the blue button"), this asks the vision model to return the element's
//  approximate coordinates so the buddy can animate to it and point at it.
//
//  The model is asked to respond with a JSON blob containing an "x" and "y"
//  field in the 0–1 normalised coordinate space (top-left origin). The caller
//  is responsible for mapping those normalised values to real screen points.
//

import AppKit
import Foundation

/// Detects the screen location of UI elements in screenshots using the local
/// qwen2.5vl:7b vision model running via Ollama.
///
/// The vision model returns normalised coordinates (0.0–1.0 range, top-left
/// origin). The caller scales these to display-local AppKit coordinates
/// (bottom-left origin) before animating the cursor overlay.
///
/// Memory management: The vision model is loaded on demand and immediately
/// unloaded via `OllamaModelMemoryManager` after each call so it does not
/// compete with the reasoning model for RAM/VRAM.
class ElementLocationDetector {
    private let visionAPI: OllamaAPI
    private let visionModel = "qwen2.5vl:7b"

    init() {
        self.visionAPI = OllamaAPI(model: visionModel)
    }

    /// Detects the screen location of a UI element the user is asking about.
    ///
    /// - Parameters:
    ///   - screenshotData: JPEG or PNG screenshot data from ScreenCaptureKit.
    ///   - userQuestion: The user's voice transcript (e.g., "How do I add a project?").
    ///   - displayWidthInPoints: The captured display's width in screen points.
    ///   - displayHeightInPoints: The captured display's height in screen points.
    ///
    /// - Returns: A `CGPoint` in display-local macOS AppKit coordinates (bottom-left
    ///   origin) if an element was identified, or `nil` if no element was found or
    ///   detection failed.
    func detectElementLocation(
        screenshotData: Data,
        userQuestion: String,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int
    ) async -> CGPoint? {
        print("🎯 ElementLocationDetector: asking \(visionModel) to locate element for question: \"\(userQuestion.prefix(60))\"")

        let systemPrompt = """
        You are a precise UI element locator. You are given a screenshot and a user question.
        Your job is to identify the most relevant UI element (button, link, menu item, text field, icon, etc.) that the user is referring to or should interact with.
        
        If you find a relevant element, respond ONLY with a JSON object like:
        {"found": true, "x": 0.42, "y": 0.35, "label": "Submit button"}
        
        Where x and y are normalised coordinates between 0.0 and 1.0, with (0,0) at the TOP-LEFT corner of the screenshot.
        
        If the question is conceptual (e.g., "what does HTML mean?") and there is no specific element to point at, respond ONLY with:
        {"found": false}
        
        WARNING: Do NOT guess, invent, or hallucinate elements. If the element the user is asking about is NOT clearly and explicitly visible on the screen, respond ONLY with {"found": false}. You must be strictly factual.
        
        Do NOT include any other text, explanation, or markdown. Only output the JSON object.
        """

        let userPrompt = "Screenshot provided. User asked: \"\(userQuestion)\". Locate the most relevant UI element."

        do {
            let (responseText, _) = try await visionAPI.analyzeImage(
                images: [(data: screenshotData, label: "screenshot")],
                systemPrompt: systemPrompt,
                conversationHistory: [],
                userPrompt: userPrompt,
                temperature: 0.0
            )

            // Await the unload so the vision model is fully out of RAM before returning
            await OllamaModelMemoryManager.shared.unloadModel(visionModel)

            return parseNormalisedCoordinateFromResponse(
                responseText: responseText,
                displayWidthInPoints: displayWidthInPoints,
                displayHeightInPoints: displayHeightInPoints
            )
        } catch {
            print("⚠️ ElementLocationDetector: vision model call failed: \(error.localizedDescription)")
            await OllamaModelMemoryManager.shared.unloadModel(visionModel)
            return nil
        }
    }

    // MARK: - Private Helpers

    /// Parses the normalised (0–1) coordinate from the model's JSON response and
    /// converts it to a display-local AppKit point (bottom-left origin).
    private func parseNormalisedCoordinateFromResponse(
        responseText: String,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int
    ) -> CGPoint? {
        // The model should return a clean JSON object. Strip any markdown fences
        // in case the model wraps it despite instructions.
        let cleanedResponse = responseText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Find the JSON object boundaries so we tolerate any surrounding whitespace
        guard let jsonStartIndex = cleanedResponse.firstIndex(of: "{"),
              let jsonEndIndex = cleanedResponse.lastIndex(of: "}") else {
            print("🎯 ElementLocationDetector: no JSON object found in response")
            return nil
        }

        let jsonSubstring = String(cleanedResponse[jsonStartIndex...jsonEndIndex])

        guard let jsonData = jsonSubstring.data(using: .utf8),
              let parsedJSON = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            print("🎯 ElementLocationDetector: failed to parse JSON: \(jsonSubstring.prefix(200))")
            return nil
        }

        // Check whether the model found an element
        guard let wasElementFound = parsedJSON["found"] as? Bool, wasElementFound else {
            print("🎯 ElementLocationDetector: model reported no specific element (conceptual question)")
            return nil
        }

        // Extract normalised x/y coordinates
        guard let normalisedX = parsedJSON["x"] as? Double,
              let normalisedY = parsedJSON["y"] as? Double else {
            print("🎯 ElementLocationDetector: JSON missing x/y fields: \(jsonSubstring.prefix(200))")
            return nil
        }

        // Clamp to valid 0–1 range in case the model overshoots slightly
        let clampedNormalisedX = max(0.0, min(1.0, normalisedX))
        let clampedNormalisedY = max(0.0, min(1.0, normalisedY))

        // Scale normalised coords to display point dimensions
        let displayLocalX = clampedNormalisedX * Double(displayWidthInPoints)
        let displayLocalYTopLeft = clampedNormalisedY * Double(displayHeightInPoints)

        // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
        let displayLocalYBottomLeft = Double(displayHeightInPoints) - displayLocalYTopLeft

        let label = parsedJSON["label"] as? String ?? "element"
        print("🎯 ElementLocationDetector: found \"\(label)\" at normalised (\(String(format: "%.3f", clampedNormalisedX)), \(String(format: "%.3f", clampedNormalisedY))) → display-local (\(Int(displayLocalX)), \(Int(displayLocalYBottomLeft)))")

        return CGPoint(x: displayLocalX, y: displayLocalYBottomLeft)
    }
}
