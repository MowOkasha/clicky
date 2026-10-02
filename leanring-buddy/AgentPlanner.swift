//
//  AgentPlanner.swift
//  leanring-buddy
//
//  Planner module running qwen3.5-9b on oMLX on-demand (~90s idle TTL).
//  Turns a user's goal + screen state + RAG hints into an ordered list of subgoals.
//  Uses the system prompt from clicky-architecture.md verbatim.
//

import Foundation

/// Orchestrates task planning and replanning using the qwen3.5-9b model.
@MainActor
class AgentPlanner {

    private let omlxClient: OMLXClient

    /// The planner system prompt from clicky-architecture.md used verbatim with terminal-first research guidelines.
    static let plannerSystemPrompt: String = """
/no_think
You are the planning module for Clicky, a local macOS automation agent.
You do not click or type anything yourself. Your only job is to turn a
user's goal into an ordered list of concrete subgoals that a separate,
simpler execution model can carry out one step at a time.
Do NOT think or output <think> tags. Output ONLY the JSON response immediately.

You will receive:
- The user's goal, in their own words.
- A summary of the current screen state (active app, window title, and
  either a list of visible UI elements or a note that a screenshot is
  attached).
- Optionally, relevant past trajectories or a cached UI map for the
  current app, retrieved from memory. Treat these as hints, not ground
  truth — the live screen state always wins if they conflict.
- Optionally, a note that a previous attempt failed, with the reason.

Rules:
- Prefer terminal commands over GUI navigation: If the user's goal involves
  checking for files, opening files, inspecting directories (like ~/Desktop, ~/Downloads,
  ~/Documents), searching disk, checking running processes, git status, or system
  information, plan subgoals that use terminal commands (e.g. "run terminal command: ls ~/Desktop",
  "open file via terminal: open ~/Desktop/position.pages", "read file: cat ~/Desktop/notes.txt")
  rather than opening Finder, clicking around the desktop, or taking screenshots.

- Research & Document Creation (Pages, Word, TextEdit):
  When asked to research a topic and put it into Pages, Word, or another document editor:
  NEVER plan fragile multi-step GUI web browsing, waiting for pages, clicking links, selecting text, and pasting into text areas.
  Instead, plan concise terminal-first actions:
  1. Fetch/compile research: use Wikipedia API via curl (e.g. curl -s 'https://en.wikipedia.org/w/api.php?action=query&prop=extracts&exintro=1&explaintext=1&titles=Topic_Name&format=json') or search_web or compile summary.
  2. Save content to a document file: write HTML or Markdown, convert using macOS built-in textutil:
     run terminal command: cat << 'EOF' > ~/Desktop/Topic_Name.html ... EOF
     run terminal command: textutil -convert docx ~/Desktop/Topic_Name.html -output ~/Desktop/Topic_Name.docx
  3. Open the document in Pages:
     run terminal command: open -a Pages ~/Desktop/Topic_Name.docx
     (Or use AppleScript: osascript -e 'tell application "Pages" to make new document with properties {body text:"..."}')
  This completes the task cleanly in 3-4 reliable terminal steps without browser tabs, clipboard copy/paste, or clicking.

- Opening / Switching Applications:
  Use concrete single-step subgoals: e.g. "open application: open_app(\"Safari\")" or "open file via terminal: open ~/Desktop/file.pages".
  Terminal commands and open_app execute independently in the background regardless of what app is frontmost. NEVER plan intermediate steps like "switch from Terminal to Safari" as separate escalations.

- Never suggest stopping or killing background terminal processes or pressing Ctrl+C in user terminal windows.
- Each subgoal must be a single, concrete, verifiable outcome
  (e.g. "open Pages", "attach the file named invoice.pdf",
  "click Send") — never a vague instruction like "handle the email."
- Order subgoals the way a careful human would actually perform the
  task, including any necessary intermediate steps (opening menus,
  waiting for windows to load) even if the user didn't mention them.
- If you're replanning after a failure, don't just repeat the same
  subgoal — adjust it based on the failure reason you were given.
- Never invent UI elements you weren't told exist.
- Output ONLY valid JSON, no prose, in this exact shape:

{
  "subgoals": [
    {"id": 1, "description": "..."},
    {"id": 2, "description": "..."}
  ]
}
"""

    init(omlxClient: OMLXClient) {
        self.omlxClient = omlxClient
    }

    /// Calls qwen3.5-9b to generate an ordered list of subgoals for the task.
    ///
    /// - Parameters:
    ///   - stateManager: The state manager providing the reconstructed user prompt.
    ///   - screenSummaryText: Text summary of the current screen state.
    ///   - fallbackScreenshots: Optional screenshots if perception used screenshot fallback.
    /// - Returns: An ordered array of `AgentSubgoal` objects.
    func generatePlan(
        stateManager: AgentStateManager,
        screenSummaryText: String,
        fallbackScreenshots: [(data: Data, label: String)] = []
    ) async throws -> [AgentSubgoal] {
        let userPrompt = stateManager.constructPlannerUserPrompt(screenSummaryText: screenSummaryText)

        let base64Images: [String] = fallbackScreenshots.map { $0.data.base64EncodedString() }

        let messages: [OMLXChatMessage] = [
            OMLXChatMessage(role: .system, text: AgentPlanner.plannerSystemPrompt),
            OMLXChatMessage(role: .user, text: userPrompt, base64ImageData: base64Images)
        ]

        print("🧠 AgentPlanner: Invoking qwen3.5-9b planner (thinking disabled, maxTokens: 400)...")
        let response = try await omlxClient.sendChatCompletionRequest(
            model: OMLXClient.plannerModelAlias,
            messages: messages,
            temperature: 0.1,
            maxTokens: 400,
            enableThinking: false
        )
        print("🧠 AgentPlanner: Received response in \(String(format: "%.2f", response.requestDuration))s")

        let parsedSubgoals = try parseSubgoals(from: response.contentText)

        DebugEventLogger.shared.log(.planGenerated(
            subgoals: parsedSubgoals.map { $0.description },
            promptTokens: response.promptTokens,
            completionTokens: response.completionTokens,
            durationSeconds: response.requestDuration
        ))

        return parsedSubgoals
    }

    // MARK: - JSON Parsing

    private func parseSubgoals(from rawResponse: String) throws -> [AgentSubgoal] {
        var cleanedText = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip any <think>...</think> tags that reasoning models may output
        let thinkPattern = "(?s)<think>.*?</think>"
        cleanedText = cleanedText.replacingOccurrences(of: thinkPattern, with: "", options: .regularExpression)
        if let openIndex = cleanedText.range(of: "<think>") {
            cleanedText = String(cleanedText[..<openIndex.lowerBound])
        }
        cleanedText = cleanedText.replacingOccurrences(of: "</think>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code block if present
        if cleanedText.hasPrefix("```") {
            let lines = cleanedText.components(separatedBy: "\n")
            let strippedLines = lines.dropFirst().dropLast()
            cleanedText = strippedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Locate JSON bounds if there's any surrounding commentary
        if let openingBraceIndex = cleanedText.firstIndex(of: "{"),
           let closingBraceIndex = cleanedText.lastIndex(of: "}") {
            cleanedText = String(cleanedText[openingBraceIndex...closingBraceIndex])
        }

        guard let jsonData = cleanedText.data(using: .utf8) else {
            throw NSError(
                domain: "AgentPlannerError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to convert planner response text to UTF-8 data: \(rawResponse)"]
            )
        }

        struct PlannerJSONResponse: Decodable {
            struct RawSubgoal: Decodable {
                let id: Int
                let description: String
            }
            let subgoals: [RawSubgoal]
        }

        do {
            let decodedResponse = try JSONDecoder().decode(PlannerJSONResponse.self, from: jsonData)
            let subgoals = decodedResponse.subgoals.map { raw in
                AgentSubgoal(id: raw.id, description: raw.description, status: .pending)
            }
            guard !subgoals.isEmpty else {
                throw NSError(
                    domain: "AgentPlannerError",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Planner returned an empty subgoals list"]
                )
            }
            return subgoals
        } catch {
            print("⚠️ AgentPlanner: Failed to decode planner JSON. Raw: \(rawResponse)")
            throw error
        }
    }
}
