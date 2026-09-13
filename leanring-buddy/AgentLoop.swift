//
//  AgentLoop.swift
//  leanring-buddy
//
//  The agentic orchestrator. Manages the think → act → observe loop
//  between the model and the tool executor until the model produces
//  a final text response or the iteration limit is reached.
//

import Foundation

/// The result of a completed agent loop run.
struct AgentLoopResult {
    /// The model's final spoken response (with [POINT:...] tags still present).
    let finalResponseText: String
    /// All tool calls that were executed during this run, in order.
    let executedToolCalls: [(toolName: String, arguments: [String: Any], result: String)]
    /// Total wall-clock time for the entire loop (all model calls + tool execution).
    let totalDuration: TimeInterval
}

/// Orchestrates the agentic think → act → observe loop.
///
/// Flow:
///   1. Call the model with the user's message, screenshots, and all tool definitions.
///   2. If the model returns tool_calls → execute each tool → append results → go to 1.
///   3. If the model returns a text response → return AgentLoopResult.
///   4. If we hit maxIterations → send one final call with no tools to force a text response.
@MainActor
class AgentLoop {
    let ollamaAPI: OllamaAPI
    let toolExecutor: AgentToolExecutor
    /// Safety limit on how many tool-calling iterations we allow before
    /// forcing a final text response. Prevents runaway loops.
    let maxIterations: Int

    init(ollamaAPI: OllamaAPI, toolExecutor: AgentToolExecutor, maxIterations: Int = 10) {
        self.ollamaAPI = ollamaAPI
        self.toolExecutor = toolExecutor
        self.maxIterations = maxIterations
    }

    /// Runs the full agent loop starting from a user message.
    ///
    /// - Parameters:
    ///   - systemPrompt: The system prompt for the model.
    ///   - initialImages: Screenshots from before the user spoke, to include in the first call.
    ///   - conversationHistory: Prior turns in the conversation (user/assistant pairs).
    ///   - userPrompt: The current user message (transcript + vision context + memories).
    ///   - onTextChunk: Called on the main actor as the model streams its final response.
    ///   - onToolCallStarted: Optional UI callback when a tool call begins (name, args).
    func run(
        systemPrompt: String,
        initialImages: [(data: Data, label: String)],
        conversationHistory: [(role: String, content: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void,
        onToolCallStarted: (@MainActor (String, [String: Any]) -> Void)? = nil
    ) async throws -> AgentLoopResult {
        let overallStartTime = Date()

        // Mutable history that grows as we add tool calls and results
        var runningHistory = conversationHistory

        // Track all tool calls executed this run
        var executedToolCalls: [(toolName: String, arguments: [String: Any], result: String)] = []

        // Images to attach to the current call — starts with the initial screenshots,
        // then updated if the model calls take_screenshot
        var currentImages = initialImages

        // The user prompt is only sent in the first iteration;
        // subsequent iterations have the user message already in history.
        var currentUserPrompt: String? = userPrompt

        for iterationIndex in 0..<maxIterations {
            let isLastIteration = (iterationIndex == maxIterations - 1)

            // On the last allowed iteration, send with no tools so the model
            // is forced to produce a text response rather than another tool call.
            let toolsToSend: [[String: Any]] = isLastIteration ? [] : AgentToolDefinition.allToolsAsOllamaFormat()

            print("🔄 AgentLoop iteration \(iterationIndex + 1)/\(maxIterations): \(currentImages.count) image(s), \(toolsToSend.count) tool(s)")

            // If there's a pending user prompt, inject it into history now.
            // On subsequent iterations, the user message is already in history.
            let promptForThisCall: String
            if let pendingPrompt = currentUserPrompt {
                promptForThisCall = pendingPrompt
                currentUserPrompt = nil
            } else {
                // After the first iteration the user message is in history — send
                // an empty continuation so the model keeps going based on tool results.
                promptForThisCall = "Continue."
            }

            let result = try await ollamaAPI.chat(
                images: currentImages,
                systemPrompt: systemPrompt,
                conversationHistory: runningHistory,
                userPrompt: promptForThisCall,
                tools: toolsToSend,
                onTextChunk: onTextChunk
            )

            // Clear images after the first call — they've been sent to the model.
            // Fresh screenshots from take_screenshot will be re-attached below.
            currentImages = []

            switch result {
            case .textResponse(let text, _):
                // The model produced a final text answer — we're done.
                let totalDuration = Date().timeIntervalSince(overallStartTime)
                print("✅ AgentLoop finished in \(String(format: "%.1f", totalDuration))s, \(executedToolCalls.count) tool call(s)")
                return AgentLoopResult(
                    finalResponseText: text,
                    executedToolCalls: executedToolCalls,
                    totalDuration: totalDuration
                )

            case .toolCallsRequested(let toolCalls, _):
                // Execute each requested tool and collect results
                var toolResultMessages: [(role: String, content: String)] = []

                for toolCall in toolCalls {
                    // Notify the UI that a tool is being executed
                    onToolCallStarted?(toolCall.functionName, toolCall.arguments)

                    let toolResult = await toolExecutor.execute(
                        toolName: toolCall.functionName,
                        arguments: toolCall.arguments
                    )

                    executedToolCalls.append((
                        toolName: toolCall.functionName,
                        arguments: toolCall.arguments,
                        result: toolResult
                    ))

                    // Ollama expects tool results as messages with role "tool"
                    toolResultMessages.append((
                        role: "tool",
                        content: toolResult
                    ))

                    // If the model called take_screenshot, attach the fresh captures
                    // as images on the next iteration so it can actually see them.
                    if toolCall.functionName == "take_screenshot" && !toolExecutor.lastCapturedScreenshots.isEmpty {
                        currentImages = toolExecutor.lastCapturedScreenshots.map { capture in
                            let dimensionInfo = " (\(capture.screenshotWidthInPixels)×\(capture.screenshotHeightInPixels)px)"
                            return (data: capture.imageData, label: capture.label + dimensionInfo)
                        }
                        toolExecutor.lastCapturedScreenshots = []
                    }
                }

                // Append the user message and tool results to running history
                // so the model has full context on the next iteration.
                runningHistory.append((role: "user", content: promptForThisCall))
                runningHistory.append(contentsOf: toolResultMessages)
            }
        }

        // Fallback: maxIterations exhausted — send one final call with no tools
        // to get whatever conclusion the model can produce.
        print("⚠️ AgentLoop: maxIterations (\(maxIterations)) reached, forcing final response")

        let fallbackResult = try await ollamaAPI.chat(
            images: currentImages,
            systemPrompt: systemPrompt,
            conversationHistory: runningHistory,
            userPrompt: "Please give me your final answer based on everything you've found so far.",
            tools: [],
            onTextChunk: onTextChunk
        )

        let finalText: String
        if case .textResponse(let text, _) = fallbackResult {
            finalText = text
        } else {
            finalText = "I ran out of steps before finishing. Here's what I found: \(executedToolCalls.map { "\($0.toolName): \($0.result.prefix(100))" }.joined(separator: "; "))"
        }

        let totalDuration = Date().timeIntervalSince(overallStartTime)
        return AgentLoopResult(
            finalResponseText: finalText,
            executedToolCalls: executedToolCalls,
            totalDuration: totalDuration
        )
    }
}
