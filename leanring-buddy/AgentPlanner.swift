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
- A summary of the current screen state.
- Optionally, relevant past trajectories or UI hints.
- Optionally, context on completed subgoals and previous failure reasons when replanning.

Rules:
1. RESPECT USER-SPECIFIED APPLICATIONS & BROWSERS:
   If the user specifically asks to open, find, or use an application (e.g. "open on Safari", "find that on Safari", "paste into Pages", "write in Notes"):
   You MUST include opening and using that application!
   - For Safari: e.g. "open Safari to page: run_applescript(\"tell application \\\"Safari\\\" to open location \\\"https://en.wikipedia.org/wiki/Topic_Name\\\"\")" or run_terminal_command("open -a Safari 'https://en.wikipedia.org/wiki/Topic_Name'")
   - For Pages: e.g. "create Pages document with summary: run_applescript" or open a generated document in Pages.

2. PIPING TOOL OUTPUT STRAIGHT TO FILES (NEVER RETYPE LONG TEXT):
   When fetching research or web data, NEVER plan subgoals where the model has to manually copy, echo, or retype article text into terminal commands.
   ALWAYS pipe command output directly into a file:
   - Wikipedia extraction (working macOS pattern):
     curl -sL 'https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&titles=Topic_Name&format=json' | python3 -c "import sys,json; p=json.load(sys.stdin)['query']['pages']; print(next(iter(p.values()))['extract'])" > /tmp/topic_raw.txt
     NOTE: Wikipedia API keys pages by numeric ID (e.g. '312905'). ALWAYS use next(iter(p.values()))['extract'] in python. NEVER access p['Topic_Name'] directly (causes KeyError).
     NOTE: macOS grep is BSD grep and does NOT support -P. NEVER use grep -oP or grep -oE on raw JSON.

3. SUMMARIZING & POPULATING PAGES DOCUMENTS:
   For tasks requiring research or summaries put into Pages, Word, or Notes:
   - Step 1: Open browser (e.g. Safari) to the topic if requested.
   - Step 2: Fetch article or query data directly to a temporary file via curl.
   - Step 3: Summarize content into a temporary text file.
   - Step 4: Create new Pages document and insert the summary via AppleScript.
   - Step 5: Verify the document exists and is populated.

4. APPLESCRIPT AUTOMATION (run_applescript):
   PREFER run_applescript over GUI clicking for scriptable macOS apps:
   - Pages: make new document, set body text, export
   - Safari: open location, read page text (do JavaScript), get active tab URL
   - Notes: make new note, get notes list
   - Reminders: make new reminder
   - Music: get current track, control playback

5. GENERAL PLANNING & FORMATTING:
   - Prefer terminal commands over manual clicking for file operations (ls, open, cat, find).
   - When replanning, plan ONLY the remaining subgoals needed to complete the user goal. Do not repeat completed subgoals.
   - Subgoals must be concise, high-level descriptions (1-2 sentences). Do NOT paste giant raw shell scripts or multi-line python code into the JSON description strings; describe what each step accomplishes so the executor can select the appropriate tool.
   - Output ONLY valid JSON, no prose, in this exact shape:

6. DO NOT OVER-DECOMPOSE SIMPLE FILE OPENING:
   If the user simply wants to open an existing file, document, or app (e.g. "open the Pages document on my desktop", "open resume.pdf", "open notes"):
   Do NOT create separate listing or search subgoals. Use a SINGLE subgoal:
   e.g. {"id": 1, "description": "Open the Pages document on the Desktop using open ~/Desktop/*.pages"}

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
        fallbackScreenshots: [(data: Data, label: String)] = [],
        recentConversationSnippet: String? = nil,
        lastTaskArtifactSummary: String? = nil
    ) async throws -> [AgentSubgoal] {
        let userPrompt = stateManager.constructPlannerUserPrompt(
            screenSummaryText: screenSummaryText,
            recentConversationSnippet: recentConversationSnippet,
            lastTaskArtifactSummary: lastTaskArtifactSummary
        )

        let base64Images: [String] = fallbackScreenshots.map { $0.data.base64EncodedString() }

        let messages: [OMLXChatMessage] = [
            OMLXChatMessage(role: .system, text: AgentPlanner.plannerSystemPrompt),
            OMLXChatMessage(role: .user, text: userPrompt, base64ImageData: base64Images)
        ]

        print("🧠 AgentPlanner: Invoking qwen3.5-9b planner (thinking disabled, maxTokens: 1024)...")
        let response = try await omlxClient.sendChatCompletionRequest(
            model: OMLXClient.plannerModelAlias,
            messages: messages,
            temperature: 0.1,
            maxTokens: 1024,
            enableThinking: false,
            responseFormat: ["type": "json_object"]
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
        let firstOpenBrace = cleanedText.firstIndex(of: "{")
        let firstOpenBracket = cleanedText.firstIndex(of: "[")

        if let brace = firstOpenBrace, (firstOpenBracket == nil || brace < firstOpenBracket!),
           let lastBrace = cleanedText.lastIndex(of: "}") {
            cleanedText = String(cleanedText[brace...lastBrace])
        } else if let bracket = firstOpenBracket, let lastBracket = cleanedText.lastIndex(of: "]") {
            cleanedText = String(cleanedText[bracket...lastBracket])
        }

        guard let jsonData = cleanedText.data(using: .utf8) else {
            throw NSError(
                domain: "AgentPlannerError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to convert planner response text to UTF-8 data: \(rawResponse)"]
            )
        }

        struct RawSubgoal: Decodable {
            let id: Int
            let description: String
        }

        struct PlannerJSONResponse: Decodable {
            let subgoals: [RawSubgoal]
        }

        // Attempt 1: Standard object with "subgoals" key
        if let decodedResponse = try? JSONDecoder().decode(PlannerJSONResponse.self, from: jsonData),
           !decodedResponse.subgoals.isEmpty {
            return decodedResponse.subgoals.map { raw in
                AgentSubgoal(id: raw.id, description: raw.description, status: .pending)
            }
        }

        // Attempt 2: Direct top-level array of subgoals
        if let rawArray = try? JSONDecoder().decode([RawSubgoal].self, from: jsonData),
           !rawArray.isEmpty {
            return rawArray.map { raw in
                AgentSubgoal(id: raw.id, description: raw.description, status: .pending)
            }
        }

        // Attempt 3: Resilient regex extraction for malformed quotes or partial JSON
        let subgoalPattern = #""id"\s*:\s*(\d+)[\s\S]*?"description"\s*:\s*"([\s\S]*?)(?="\s*[,}\]])"#
        if let regex = try? NSRegularExpression(pattern: subgoalPattern, options: []) {
            let nsString = cleanedText as NSString
            let matches = regex.matches(in: cleanedText, options: [], range: NSRange(location: 0, length: nsString.length))
            if !matches.isEmpty {
                var recoveredSubgoals: [AgentSubgoal] = []
                for match in matches {
                    guard match.numberOfRanges >= 3 else { continue }
                    let idString = nsString.substring(with: match.range(at: 1))
                    let rawDescription = nsString.substring(with: match.range(at: 2))
                    let cleanedDescription = rawDescription
                        .replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let subgoalId = Int(idString), !cleanedDescription.isEmpty {
                        recoveredSubgoals.append(AgentSubgoal(id: subgoalId, description: cleanedDescription, status: .pending))
                    }
                }
                if !recoveredSubgoals.isEmpty {
                    print("✅ AgentPlanner: Successfully recovered \(recoveredSubgoals.count) subgoals via resilient regex fallback")
                    return recoveredSubgoals
                }
            }
        }

        // Attempt 4: Strict decode with detailed error reporting
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
