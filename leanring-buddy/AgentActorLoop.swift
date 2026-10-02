//
//  AgentActorLoop.swift
//  leanring-buddy
//
//  The execution module running the resident qwen3.5-9b model on oMLX.
//  Executes exactly one tool call per turn on the current subgoal.
//  State is maintained entirely outside the model via AgentStateManager.
//  Uses the actor system prompt from clicky-architecture.md verbatim.
//

import Foundation

/// Parsed representation of a single tool invocation requested by the actor model.
struct ParsedActorToolCall {
    let toolName: String
    let arguments: [String: Any]
    let rawText: String
}

/// The result of executing the full actor loop for a task.
struct ActorExecutionResult {
    let isTaskSuccessful: Bool
    let totalStepsTaken: Int
    let finalSummary: String
}

/// Orchestrates the execution loop using the resident qwen3.5-9b model.
@MainActor
class AgentActorLoop {
    
    private let omlxClient: OMLXClient
    private let toolExecutor: AgentToolExecutor
    private let perceptionManager: PerceptionManager
    
    /// Maximum number of total actor tool calls before aborting a runaway task.
    let maximumTotalSteps: Int = 30
    
    /// The actor system prompt from clicky-architecture.md used verbatim.
    static let actorSystemPrompt: String = """
You are Clicky, a friendly voice companion that lives in the macOS menu bar.
The user speaks to you via push-to-talk and your text responses are spoken
aloud via text-to-speech. You can also automate the Mac by calling tools.

Most of the time you act on exactly one subgoal at a time, given the
current state of the screen. But on the VERY FIRST turn of a new task
(no subgoal assigned yet), you also act as triage: decide which of three
paths this request should take.

TRIAGE (first turn of a task only — pick exactly one path):

PATH A — DIRECT ANSWER (just reply with text, no tool call):
  Use this when the user is having a conversation, asking a question,
  greeting you, asking for knowledge or opinions, or saying anything
  that does NOT require you to click, type, or navigate on their Mac.
  You ARE the voice interface — you don't need to open an app to talk.
  Write your reply the way you'd actually speak: casual, warm, concise,
  all lowercase, no emojis, no markdown. One or two sentences by default.
  Examples that should ALWAYS be direct answers:
    - "hey clicky how are you"
    - "what is the weather like" (answer from general knowledge)
    - "what does this button do" (describe what you see)
    - "explain what html is"
    - "thanks that worked"

PATH B — DIRECT TOOL (emit a single tool call):
  Use this when the task is an action achievable right now:
  - Terminal commands: ALWAYS PREFER running a terminal command (run_terminal_command)
    for anything involving checking files, finding files, listing directory contents
    (e.g. on Desktop, in Downloads, in Documents), checking git status, running scripts,
    or checking system/process info.
    Examples:
      - "Can you see the position file on my desktop?" -> run_terminal_command("ls ~/Desktop")
      - "What files are on my desktop?" -> run_terminal_command("ls ~/Desktop")
      - "Open the position file on my desktop" -> run_terminal_command("open ~/Desktop/position.pages")
      - "Check what is inside notes.txt" -> run_terminal_command("cat ~/Desktop/notes.txt")
      - "Check if there's a pdf in my downloads" -> run_terminal_command("find ~/Downloads -maxdepth 2 -iname '*.pdf'")
      - "Is Docker running?" -> run_terminal_command("docker ps")
      - "Check git status" -> run_terminal_command("git status")
  - UI actions: "click send", "open safari", "close this window", "scroll down".
  Emit exactly ONE tool call.

PATH C — NEEDS PLAN (respond with the JSON below and nothing else):
  Use this ONLY when the task requires multiple sequential UI actions
  across different steps, windows, or apps that you can't do in one
  tool call. Respond with ONLY this JSON:
  {"needs_plan": true, "reason": "<short reason>"}
  Examples: "send an email to John about the meeting", "create a new
  Xcode project and add a file", "find the cheapest flight to London".
  NOTE: If checking a file or directory can be done with a terminal
  command (like ls ~/Desktop or find), DO NOT choose Path C. Use Path B with
  run_terminal_command instead.

IMPORTANT: When in doubt between A and C, prefer A (direct answer).
Only choose C when you are certain the user wants you to physically
automate multiple UI steps on their Mac. Conversations, greetings,
knowledge questions, and opinions are NEVER path C.

EXECUTION (once a subgoal has been assigned by the planner):
You will receive:
- The current subgoal you're working on.
- The current UI state: a list of visible elements with their type,
  label, and position (preferred), OR a screenshot if the element list
  wasn't available for this app.
- A short history of your last few actions and their results (compact,
  one line each).

Rules:
- Choose exactly ONE tool call per turn. Never describe multiple steps.
- TERMINAL FIRST: Whenever checking for files (e.g. on Desktop, in Downloads, in home directory),
  inspecting directories, running scripts, or checking system state, ALWAYS use
  run_terminal_command instead of clicking windows or guessing from screenshots.
- BACKGROUND EXECUTION: run_terminal_command and open_app execute independently in the background
  regardless of what app or window is frontmost or visible! You DO NOT need to be in an app or have
  it focused to open it or run shell commands. NEVER call escalate just because the target app is not
  frontmost or you see Terminal on screen. To open or switch to an app, simply call open_app("AppName")
  or run_terminal_command("open -a AppName").
- RESEARCH & DOCUMENT CREATION (Pages, Word, TextEdit, Safari):
  1. If user asks to find/open in Safari, open it: run_terminal_command("open -a Safari 'https://en.wikipedia.org/wiki/Topic'")
  2. NEVER manually echo or re-type article text into terminal commands. ALWAYS pipe command output directly into files!
     Working Wikipedia fetch on macOS:
     run_terminal_command("curl -sL 'https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&titles=Topic_Name&format=json' | python3 -c \"import sys,json; p=json.load(sys.stdin)['query']['pages']; print(next(iter(p.values()))['extract'])\" > /tmp/topic_raw.txt")
     (Note: Always use next(iter(p.values()))['extract'] in python because Wikipedia keys pages by numeric ID. Never use grep -P on macOS.)
  3. Summarize /tmp/topic_raw.txt into /tmp/summary.txt via python:
     run_terminal_command("python3 -c \"import sys; text=open('/tmp/topic_raw.txt').read()[:4000]; paragraphs=[p.strip() for p in text.split('\\n') if len(p.strip()) > 50][:4]; open('/tmp/summary.txt','w').write('\\n\\n'.join(paragraphs))\"")
  4. Create & populate Pages document via AppleScript:
     run_terminal_command("osascript -e 'set txt to read POSIX file \"/tmp/summary.txt\" as «class utf8»' -e 'tell application \"Pages\"' -e 'activate' -e 'set doc to make new document' -e 'set body text of doc to txt' -e 'end tell'")
     (Or convert via textutil: textutil -convert docx /tmp/summary.txt -output ~/Desktop/Summary.docx && open -a Pages ~/Desktop/Summary.docx)
  5. Check file exists and is non-empty before calling done(): run_terminal_command("[ -s /tmp/summary.txt ] && echo OK")
- DO NOT ESCALATE FOR ACTIONS YOU CAN DO YOURSELF: You have full access to run_terminal_command, open_app, and write_clipboard.
  If you need to run a command (like textutil, python, curl, osascript) or open an app, execute it directly! NEVER call escalate to run commands.
- ESCALATE IS A LAST RESORT: Only call escalate if an external roadblock truly prevents achieving the plan.
- NEVER output `{"needs_plan": true}` during execution. If an action fails twice or you need replanning,
  call `escalate(reason: "...")`.
- Never call wait consecutively. If a target element or file is not visible, use
  run_terminal_command, open_app, or escalate(reason). Do NOT loop wait.
- If the subgoal appears already complete based on the current state,
  call "done" instead of taking a redundant action.
- If you cannot find anything on screen that matches what the subgoal
  needs, or an action fails twice in a row, call "escalate" with a
  short reason instead of guessing further.
- Never invent an element, label, or coordinate that isn't visibly
  present in what you were given.

Available tools:
- run_terminal_command(command): Executes a zsh shell command (e.g. ls ~/Desktop, open ~/Desktop/file.pages, cat file.txt, curl, find, git). PREFER THIS for files & system.
- click(element_id | x,y): Clicks an element or coordinate.
- type(text): Types text into the focused application.
- scroll(direction, amount): Scrolls up/down/left/right.
- point(x,y): Points cursor overlay to a coordinate.
- open_app(name): Opens an application by name.
- open_url(url): Opens a URL in default browser.
- search_web(query): Searches the web.
- read_webpage(url): Reads text content from a web page.
- list_running_apps(): Lists open applications.
- read_clipboard(): Reads clipboard text.
- write_clipboard(text): Copies text to clipboard.
- wait(seconds): Pauses execution (max 2s, never call consecutively).
- done(): Marks the current subgoal complete (also: subgoal_complete).
- escalate(reason): Escalates to planner if stuck (LAST RESORT only).

Respond with a single tool call in the required function-call format —
no extra commentary.
"""
    
    init(
        omlxClient: OMLXClient,
        toolExecutor: AgentToolExecutor,
        perceptionManager: PerceptionManager
    ) {
        self.omlxClient = omlxClient
        self.toolExecutor = toolExecutor
        self.perceptionManager = perceptionManager
    }
    
    /// Runs the actor execution loop until all subgoals in the state manager are completed,
    /// or an escalation requires replanning, or the step limit is reached.
    ///
    /// - Parameters:
    ///   - stateManager: External task state manager.
    ///   - onStepStarted: Optional callback when an action step begins.
    ///   - onStepCompleted: Optional callback when an action step finishes.
    ///   - onEscalationNeeded: Callback invoked when 3 failures occur or actor calls escalate.
    /// - Returns: `ActorExecutionResult` summarizing the task outcome.
    func runActorLoop(
        stateManager: AgentStateManager,
        onStepStarted: (@MainActor (String, [String: Any]) -> Void)? = nil,
        onStepCompleted: (@MainActor (String, String) -> Void)? = nil,
        onEscalationNeeded: (@MainActor (String) async throws -> Bool)? = nil
    ) async throws -> ActorExecutionResult {
        var stepsTaken = 0
        var subgoalAttempts: [Int: Int] = [:]
        var lastExecutedCommand: String?
        var lastCommandFailed: Bool = false
        var lastCommandError: String = ""

        while !stateManager.isTaskCompleted && stepsTaken < maximumTotalSteps {
            guard let activeSubgoal = stateManager.currentActiveSubgoal() else {
                break
            }

            // 1. Capture screen state via perception (AXUIElement first, screenshot fallback)
            let perceptionResult = await perceptionManager.captureCurrentScreenState()
            toolExecutor.currentPerceptionLiveElementMap = perceptionResult.elementLiveReferenceMap

            // Check if current subgoal is already satisfied before calling the model
            if isSubgoalAlreadySatisfied(activeSubgoal, perceptionResult: perceptionResult) {
                print("✅ AgentActorLoop: Subgoal #\(activeSubgoal.id) (\"\(activeSubgoal.description)\") is already satisfied by current state. Marking done.")
                stateManager.completeCurrentActiveSubgoal()
                onStepCompleted?("done", "Subgoal already satisfied: \(activeSubgoal.description)")
                continue
            }

            stepsTaken += 1
            let currentAttempt = (subgoalAttempts[activeSubgoal.id] ?? 0) + 1
            subgoalAttempts[activeSubgoal.id] = currentAttempt

            print("🚀 AgentActorLoop: Step \(stepsTaken) on Subgoal #\(activeSubgoal.id) (attempt \(currentAttempt)): \"\(activeSubgoal.description)\"")
            DebugEventLogger.shared.log(.actorStepStarted(
                stepNumber: stepsTaken,
                subgoalIndex: activeSubgoal.id,
                totalSubgoals: stateManager.orderedSubgoals.count,
                attemptNumber: currentAttempt,
                subgoalDescription: activeSubgoal.description
            ))

            // 2. Reconstruct user prompt fresh from state manager (state lives outside model)
            let userPromptText = stateManager.constructActorUserPrompt(
                currentUIStateText: perceptionResult.formattedElementListText
            )

            // Multi-modal image payload only present if screenshot fallback was used
            let base64Images: [String] = perceptionResult.isScreenshotFallbackUsed
            ? perceptionResult.fallbackScreenshots.map { $0.data.base64EncodedString() }
            : []

            let messages: [OMLXChatMessage] = [
                OMLXChatMessage(role: .system, text: AgentActorLoop.actorSystemPrompt),
                OMLXChatMessage(role: .user, text: userPromptText, base64ImageData: base64Images)
            ]

            // 3. Invoke resident actor model qwen3.5-9b (token ceiling raised to prevent cut-off commands)
            let modelResponse = try await omlxClient.sendChatCompletionRequest(
                model: OMLXClient.actorModelAlias,
                messages: messages,
                temperature: 0.0,
                maxTokens: 1024,
                enableThinking: false
            )

            // 4. Parse the single tool call (with automatic fast re-prompting on parse error)
            var parsedToolCall = parseActorToolCall(from: modelResponse)

            if parsedToolCall == nil {
                print("⚠️ AgentActorLoop: Tool parse failed on output: \"\(modelResponse.contentText)\". Retrying with schema reminder...")
                let reminderMessages = messages + [
                    OMLXChatMessage(role: .assistant, text: modelResponse.contentText),
                    OMLXChatMessage(
                        role: .user,
                        text: "Error: Your response was not a valid tool call. You must reply ONLY with a tool call in the form `tool_name(...)` or `done()`. Do NOT output conversational prose, explanations, or markdown. Example: open_app(\"Safari\") or run_terminal_command(\"ls ~/Desktop\") or done()."
                    )
                ]
                for retryAttempt in 1...2 {
                    if let retryResponse = try? await omlxClient.sendChatCompletionRequest(
                        model: OMLXClient.actorModelAlias,
                        messages: reminderMessages,
                        temperature: 0.1,
                        maxTokens: 512,
                        enableThinking: false
                    ) {
                        if let recoveredCall = parseActorToolCall(from: retryResponse) {
                            parsedToolCall = recoveredCall
                            print("✅ AgentActorLoop: Recovered valid tool call on retry \(retryAttempt): \(recoveredCall.toolName)")
                            break
                        }
                    }
                }
            }

            guard let validToolCall = parsedToolCall else {
                print("⚠️ AgentActorLoop: Could not parse tool call after retries: \(modelResponse.contentText)")
                _ = stateManager.recordActionExecution(
                    actionSummary: "Unparseable response",
                    resultSummary: "Model did not output a valid tool call: \(modelResponse.contentText.prefix(100))",
                    isActionSuccessful: false
                )
                // Do NOT trigger 9B replanning for a syntax/parse error!
                continue
            }

            print("🎯 AgentActorLoop: Tool chosen: \(validToolCall.toolName) with arguments: \(validToolCall.arguments)")
            DebugEventLogger.shared.log(.actorResponse(
                toolName: validToolCall.toolName,
                argumentsSummary: formatArgumentsForSummary(validToolCall.arguments),
                promptTokens: modelResponse.promptTokens,
                completionTokens: modelResponse.completionTokens,
                durationSeconds: modelResponse.requestDuration
            ))
            onStepStarted?(validToolCall.toolName, validToolCall.arguments)

            // 5. Check special termination/escalation tools before executor
            if validToolCall.toolName == "done" || validToolCall.toolName == "subgoal_complete" {
                // Verify result if subgoal or goal involves writing a file or summary
                let activeDesc = activeSubgoal.description.lowercased()
                let isFileCreationGoal = activeDesc.contains("save") || activeDesc.contains("write") || activeDesc.contains("document") || activeDesc.contains(".txt") || activeDesc.contains(".pages") || activeDesc.contains(".docx") || activeDesc.contains("summary")

                if isFileCreationGoal {
                    var targetFilePath: String?
                    let pathPattern = #"(/[a-zA-Z0-9_\-\./~]+\.(txt|pages|docx|html|json|pdf))"#
                    if let regex = try? NSRegularExpression(pattern: pathPattern, options: []) {
                        for historyLine in stateManager.compressedActionHistory.reversed() {
                            let nsRange = NSRange(historyLine.startIndex..<historyLine.endIndex, in: historyLine)
                            if let match = regex.firstMatch(in: historyLine, options: [], range: nsRange),
                               let range = Range(match.range(at: 1), in: historyLine) {
                                targetFilePath = String(historyLine[range])
                                break
                            }
                        }
                    }

                    if let rawPath = targetFilePath {
                        let resolvedPath = (rawPath as NSString).expandingTildeInPath
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir) && !isDir.boolValue {
                            if let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedPath),
                               let size = attrs[.size] as? Int64, size < 50 {
                                print("⚠️ AgentActorLoop: Verification failed: Target file '\(rawPath)' is only \(size) bytes. Rejecting premature done.")
                                let errorMsg = "Verification failed: Target file '\(rawPath)' is empty or only \(size) bytes. Write the actual content to the file before marking done."
                                _ = stateManager.recordActionExecution(
                                    actionSummary: "done() [REJECTED]",
                                    resultSummary: errorMsg,
                                    isActionSuccessful: false
                                )
                                onStepCompleted?("done", errorMsg)
                                continue
                            }
                        }
                    }
                }

                stateManager.completeCurrentActiveSubgoal()
                onStepCompleted?("done", "Subgoal marked done")
                lastExecutedCommand = nil
                lastCommandFailed = false
                continue
            }

            if validToolCall.toolName == "escalate" {
                let reason = (validToolCall.arguments["reason"] as? String) ?? "Model escalated without specific reason"
                let lowerReason = reason.lowercased()

                // Intercept premature escalate on attempt 1 if model escalated to switch/open an app
                if currentAttempt == 1 && (lowerReason.contains("switch") || lowerReason.contains("open") || lowerReason.contains("terminal") || lowerReason.contains("safari") || lowerReason.contains("browser") || lowerReason.contains("pages")) {
                    if let targetApp = extractTargetAppName(from: "\(activeSubgoal.description) \(reason)") {
                        print("🛡️ AgentActorLoop: Converting premature escalate('\(reason)') into open_app('\(targetApp)')")
                        let appResult = await toolExecutor.execute(toolName: "open_app", arguments: ["app_name": targetApp])
                        _ = stateManager.recordActionExecution(
                            actionSummary: "open_app(name: \"\(targetApp)\")",
                            resultSummary: appResult,
                            isActionSuccessful: true
                        )
                        onStepCompleted?("open_app", appResult)
                        continue
                    }
                }

                // Intercept premature escalate when the model has tools to do it directly (textutil, command, python, curl, osascript)
                let selfExecutableKeywords = ["textutil", "curl", "python", "open_app", "command", "osascript", "applescript", "convert", "script"]
                if selfExecutableKeywords.contains(where: { lowerReason.contains($0) }) {
                    print("🛡️ AgentActorLoop: Intercepting misuse of escalate('\(reason)'). Reminding actor to execute directly.")
                    let guidance = "Error: Do not call escalate to run commands or tools. You have full access to run_terminal_command, open_app, and write_clipboard. Execute the action directly."
                    _ = stateManager.recordActionExecution(
                        actionSummary: "escalate(\(reason.prefix(40))) [INTERCEPTED]",
                        resultSummary: guidance,
                        isActionSuccessful: false
                    )
                    onStepCompleted?("escalate", guidance)
                    continue
                }

                stateManager.recordExplicitActorEscalation(reason: reason)
                onStepCompleted?("escalate", reason)

                if let replanHandler = onEscalationNeeded {
                    let shouldContinue = try await replanHandler(reason)
                    if !shouldContinue { break }
                }
                continue
            }

            // 6. Block repeated identical failing commands
            if validToolCall.toolName == "run_terminal_command",
               let cmd = (validToolCall.arguments["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if lastCommandFailed && lastExecutedCommand == cmd {
                    print("🛡️ AgentActorLoop: Blocking repeated identical failing command: \(cmd)")
                    let blockedMessage = "Error: That exact command failed on the previous step (\(lastCommandError.prefix(120))). Do not repeat identical failed commands. Change your command, pipe to a file, or use a python script."
                    _ = stateManager.recordActionExecution(
                        actionSummary: "run_terminal_command(\(cmd.prefix(40))...) [BLOCKED REPEAT]",
                        resultSummary: blockedMessage,
                        isActionSuccessful: false
                    )
                    onStepCompleted?("run_terminal_command", blockedMessage)
                    continue
                }
            }

            // 7. Execute tool via AgentToolExecutor
            let toolExecutionResult = await toolExecutor.execute(
                toolName: validToolCall.toolName,
                arguments: validToolCall.arguments
            )

            let isActionSuccessful = !toolExecutionResult.lowercased().hasPrefix("error")

            // Track command execution outcome
            if validToolCall.toolName == "run_terminal_command",
               let cmd = (validToolCall.arguments["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                lastExecutedCommand = cmd
                lastCommandFailed = !isActionSuccessful
                lastCommandError = isActionSuccessful ? "" : toolExecutionResult
            } else {
                lastExecutedCommand = nil
                lastCommandFailed = false
                lastCommandError = ""
            }

            // 8. Compress result into one line and update state manager
            let actionSummaryDescription = "\(validToolCall.toolName)(\(formatArgumentsForSummary(validToolCall.arguments)))"
            let shouldEscalate = stateManager.recordActionExecution(
                actionSummary: actionSummaryDescription,
                resultSummary: toolExecutionResult,
                isActionSuccessful: isActionSuccessful
            )

            onStepCompleted?(validToolCall.toolName, toolExecutionResult)

            // 9. Handle escalation if 3 consecutive failures were hit
            if shouldEscalate {
                let reason = stateManager.lastEscalationFailureReason ?? "Action failed \(stateManager.maximumConsecutiveFailuresAllowed) consecutive times"
                if let replanHandler = onEscalationNeeded {
                    let shouldContinue = try await replanHandler(reason)
                    if !shouldContinue { break }
                }
            }
        }
        
        let isSuccessful = stateManager.isTaskCompleted
        if !isSuccessful && stateManager.taskFailureReason == nil {
            if stepsTaken >= maximumTotalSteps {
                let currentSubgoalDesc = stateManager.currentActiveSubgoal()?.description ?? "current subgoal"
                stateManager.recordTaskFailure(reason: "Reached maximum step limit (\(maximumTotalSteps)) while working on: \"\(currentSubgoalDesc)\"")
            } else {
                stateManager.recordTaskFailure(reason: "Task concluded without completing all planned subgoals.")
            }
        }

        let summary = isSuccessful
        ? "Task completed successfully in \(stepsTaken) steps."
        : (stateManager.taskFailureReason ?? "Task concluded without completing all subgoals (reached \(stepsTaken) steps).")

        return ActorExecutionResult(
            isTaskSuccessful: isSuccessful,
            totalStepsTaken: stepsTaken,
            finalSummary: summary
        )
    }
    
    // MARK: - First-Turn Triage Evaluation
    
    enum ActorTriageDecision {
        case directAnswer(String)
        case directTool(ParsedActorToolCall)
        case needsPlan(reason: String)
    }
    
    /// Evaluates the first turn of a new task using the 9B model.
    /// Returns either a direct answer, a direct tool call, or a signal that planning is required.
    func evaluateTriageTurn(
        stateManager: AgentStateManager,
        perceptionResult: PerceptionResult
    ) async throws -> ActorTriageDecision {
        let userPromptText = stateManager.constructActorTriageUserPrompt(
            currentUIStateText: perceptionResult.formattedElementListText
        )
        
        let base64Images: [String] = perceptionResult.isScreenshotFallbackUsed
        ? perceptionResult.fallbackScreenshots.map { $0.data.base64EncodedString() }
        : []
        
        let messages: [OMLXChatMessage] = [
            OMLXChatMessage(role: .system, text: AgentActorLoop.actorSystemPrompt),
            OMLXChatMessage(role: .user, text: userPromptText, base64ImageData: base64Images)
        ]
        
        print("🧠 AgentActorLoop: Evaluating triage on first turn with qwen3.5-9b...")
        let modelResponse = try await omlxClient.sendChatCompletionRequest(
            model: OMLXClient.actorModelAlias,
            messages: messages,
            temperature: 0.1,
            maxTokens: 250,
            enableThinking: false
        )
        
        let cleanedText = stripThinkingTags(from: modelResponse.contentText)
        print("🧠 AgentActorLoop: Triage raw response: \(cleanedText)")
        
        // 1. Check if model signaled {"needs_plan": true}
        if let planDecision = parseNeedsPlanDecision(from: cleanedText) {
            // Extract the reason string for logging if present
            let planReason: String?
            if case .needsPlan(let reason) = planDecision { planReason = reason } else { planReason = nil }
            DebugEventLogger.shared.log(.triageResult(
                decision: "needs_plan",
                reason: planReason,
                promptTokens: modelResponse.promptTokens,
                completionTokens: modelResponse.completionTokens,
                durationSeconds: modelResponse.requestDuration
            ))
            return planDecision
        }
        
        // 2. Check if model emitted a direct tool call
        if let toolCall = parseActorToolCall(fromText: cleanedText, response: modelResponse) {
            DebugEventLogger.shared.log(.triageResult(
                decision: "direct_tool(\(toolCall.toolName))",
                reason: nil,
                promptTokens: modelResponse.promptTokens,
                completionTokens: modelResponse.completionTokens,
                durationSeconds: modelResponse.requestDuration
            ))
            return .directTool(toolCall)
        }
        
        // 3. Otherwise, it's a direct text answer
        DebugEventLogger.shared.log(.triageResult(
            decision: "direct_answer",
            reason: nil,
            promptTokens: modelResponse.promptTokens,
            completionTokens: modelResponse.completionTokens,
            durationSeconds: modelResponse.requestDuration
        ))
        return .directAnswer(cleanedText)
    }
    
    /// Strips any <think>...</think> tags that reasoning models may output, including unclosed blocks.
    func stripThinkingTags(from text: String) -> String {
        var result = text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
        if let openIndex = result.range(of: "<think>") {
            result = String(result[..<openIndex.lowerBound])
        }
        result = result.replacingOccurrences(of: "</think>", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func parseNeedsPlanDecision(from text: String) -> ActorTriageDecision? {
        let lower = text.lowercased()
        guard lower.contains("needs_plan") else { return nil }
        
        var jsonString = text
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            jsonString = String(text[start...end])
        }
        
        if let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let needsPlan = json["needs_plan"] as? Bool, needsPlan {
            let reason = (json["reason"] as? String) ?? "Multi-step task requires planning"
            return .needsPlan(reason: reason)
        }
        
        if lower.contains("\"needs_plan\": true") || lower.contains("\"needs_plan\":true") {
            return .needsPlan(reason: "Multi-step task requires planning")
        }
        
        return nil
    }
    
    // MARK: - Memory-Effective Tool Call Parsing
    
    /// Parses a single tool call from the model's response.
    /// Handles standard function syntax: click(...), type(...), scroll(...), point(...),
    /// open_app(...), wait(...), done(), escalate(...) as well as JSON objects.
    func parseActorToolCall(from response: OMLXChatCompletionResponse) -> ParsedActorToolCall? {
        let cleaned = stripThinkingTags(from: response.contentText)
        return parseActorToolCall(fromText: cleaned, response: response)
    }
    
    /// Parses tool call from cleaned text or OpenAI-style tool_calls.
    func parseActorToolCall(fromText rawText: String, response: OMLXChatCompletionResponse) -> ParsedActorToolCall? {
        // 1. Check if the server returned OpenAI-style tool_calls
        if let rawToolCall = response.toolCalls.first {
            let toolName = rawToolCall.function.name
            let arguments = parseJSONDictionary(rawToolCall.function.arguments) ?? [:]
            return ParsedActorToolCall(toolName: toolName, arguments: arguments, rawText: rawText)
        }
        
        var cleanText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanText.hasPrefix("```") {
            let lines = cleanText.components(separatedBy: "\n")
            let strippedLines = lines.dropFirst().dropLast()
            cleanText = strippedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmedText = cleanText
        
        // 2. Check for JSON object in content
        if trimmedText.hasPrefix("{") && trimmedText.hasSuffix("}") {
            if let json = parseJSONDictionary(trimmedText) {
                if let needsPlan = json["needs_plan"] as? Bool, needsPlan {
                    let reason = (json["reason"] as? String) ?? "Model requested replanning"
                    return ParsedActorToolCall(toolName: "escalate", arguments: ["reason": reason], rawText: trimmedText)
                }
                let rawName = (json["name"] as? String) ?? (json["tool"] as? String) ?? (json["function"] as? String) ?? ""
                var args = (json["arguments"] as? [String: Any]) ?? (json["parameters"] as? [String: Any]) ?? [:]

                // If args is empty and rawName contains parentheses, extract arguments from inside rawName
                if args.isEmpty && rawName.contains("(") && rawName.hasSuffix(")") {
                    if let openParen = rawName.firstIndex(of: "("), let closeParen = rawName.lastIndex(of: ")") {
                        let inside = String(rawName[rawName.index(after: openParen)..<closeParen])
                        let normalized = normalizeToolName(rawName)
                        args = parseFunctionCallArguments(toolName: normalized, rawArgumentsString: inside)
                        return ParsedActorToolCall(toolName: normalized, arguments: args, rawText: trimmedText)
                    }
                }

                let normalizedName = normalizeToolName(rawName)
                if !normalizedName.isEmpty {
                    return ParsedActorToolCall(toolName: normalizedName, arguments: args, rawText: trimmedText)
                }
            }
        }

        // 2b. If model emitted needs_plan anywhere in text during execution, treat as escalation
        if trimmedText.lowercased().contains("needs_plan") {
            var reason = "Model requested replanning"
            let reasonRegex = try? NSRegularExpression(pattern: #""reason"\s*:\s*"([^"]+)""#)
            let nsRange = NSRange(trimmedText.startIndex..<trimmedText.endIndex, in: trimmedText)
            if let match = reasonRegex?.firstMatch(in: trimmedText, range: nsRange),
               let range = Range(match.range(at: 1), in: trimmedText) {
                reason = String(trimmedText[range])
            }
            return ParsedActorToolCall(toolName: "escalate", arguments: ["reason": reason], rawText: trimmedText)
        }

        // 2c. Check for completion or "already done" statements in conversational prose
        let lowerTrimmed = trimmedText.lowercased()
        if lowerTrimmed.contains("already in ") ||
           lowerTrimmed.contains("already open") ||
           lowerTrimmed.contains("already active") ||
           lowerTrimmed.contains("already done") ||
           lowerTrimmed.contains("already satisfied") ||
           lowerTrimmed.contains("already completed") ||
           lowerTrimmed.contains("this step is done") ||
           lowerTrimmed.contains("this is already") ||
           lowerTrimmed.contains("already on the") ||
           lowerTrimmed == "done" ||
           lowerTrimmed == "done()" ||
           lowerTrimmed == "completed" ||
           lowerTrimmed == "subgoal_complete" ||
           lowerTrimmed == "subgoal_complete()" {
            print("🎯 AgentActorLoop: Parsed conversational completion statement as done(): \"\(trimmedText.prefix(60))\"")
            return ParsedActorToolCall(toolName: "done", arguments: [:], rawText: trimmedText)
        }
        
        // 3. Parse function-call syntax: tool_name(args...)
        // Pattern: [a-zA-Z_]+\(.*?\)
        let functionPattern = #"^([a-zA-Z_]+)\s*\(([\s\S]*)\)"#
        if let regex = try? NSRegularExpression(pattern: functionPattern, options: []) {
            let nsRange = NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)
            if let match = regex.firstMatch(in: rawText, options: [], range: nsRange),
               let nameRange = Range(match.range(at: 1), in: rawText),
               let argsRange = Range(match.range(at: 2), in: rawText) {
                let rawToolName = String(rawText[nameRange]).lowercased()
                let toolName = normalizeToolName(rawToolName)
                let argsString = String(rawText[argsRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                
                let arguments = parseFunctionCallArguments(toolName: toolName, rawArgumentsString: argsString)
                return ParsedActorToolCall(toolName: toolName, arguments: arguments, rawText: rawText)
            }
        }
        
        // 4. Fallback: line-by-line search for a tool invocation
        for line in rawText.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let regex = try? NSRegularExpression(pattern: functionPattern, options: []),
               let match = regex.firstMatch(in: trimmedLine, options: [], range: NSRange(trimmedLine.startIndex..<trimmedLine.endIndex, in: trimmedLine)),
               let nameRange = Range(match.range(at: 1), in: trimmedLine),
               let argsRange = Range(match.range(at: 2), in: trimmedLine) {
                let rawToolName = String(trimmedLine[nameRange]).lowercased()
                let toolName = normalizeToolName(rawToolName)
                let argsString = String(trimmedLine[argsRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let arguments = parseFunctionCallArguments(toolName: toolName, rawArgumentsString: argsString)
                return ParsedActorToolCall(toolName: toolName, arguments: arguments, rawText: rawText)
            }
        }
        
        return nil
    }
    
    private func parseFunctionCallArguments(toolName: String, rawArgumentsString: String) -> [String: Any] {
        var arguments: [String: Any] = [:]
        let trimmed = rawArgumentsString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed.isEmpty {
            return arguments
        }
        
        // Special handling per tool signature
        switch toolName {
        case "run_terminal_command":
            var commandString = trimmed
            if commandString.lowercased().hasPrefix("command=") || commandString.lowercased().hasPrefix("command:") {
                let dropCount = 8
                commandString = String(commandString.dropFirst(dropCount)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if commandString.lowercased().hasPrefix("cmd=") || commandString.lowercased().hasPrefix("cmd:") {
                let dropCount = 4
                commandString = String(commandString.dropFirst(dropCount)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if (commandString.hasPrefix("\"") && commandString.hasSuffix("\"")) ||
               (commandString.hasPrefix("'") && commandString.hasSuffix("'")) {
                commandString = String(commandString.dropFirst().dropLast())
            }
            arguments["command"] = commandString

        case "open_url", "read_webpage":
            var urlString = trimmed
            if urlString.lowercased().hasPrefix("url=") || urlString.lowercased().hasPrefix("url:") {
                urlString = String(urlString.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            arguments["url"] = cleanArgumentToken(urlString)

        case "search_web":
            var queryText = trimmed
            if queryText.lowercased().hasPrefix("query=") || queryText.lowercased().hasPrefix("query:") {
                queryText = String(queryText.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            arguments["query"] = cleanArgumentToken(queryText)

        case "write_clipboard":
            var textPayload = trimmed
            if textPayload.lowercased().hasPrefix("text=") || textPayload.lowercased().hasPrefix("text:") {
                textPayload = String(textPayload.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            arguments["text"] = cleanArgumentToken(textPayload)

        case "read_clipboard", "list_running_apps", "take_screenshot", "done":
            // No arguments required
            break

        case "click":
            // click(element_id | x,y)
            if trimmed.contains(",") {
                let parts = trimmed.components(separatedBy: ",")
                if parts.count == 2,
                   let x = Double(cleanArgumentToken(parts[0])),
                   let y = Double(cleanArgumentToken(parts[1])) {
                    arguments["x"] = x
                    arguments["y"] = y
                    return arguments
                }
            }
            // If it's an element ID
            let cleaned = cleanArgumentToken(trimmed)
            arguments["element_id"] = cleaned
            
        case "type", "type_text":
            // type(text)
            var textPayload = trimmed
            if textPayload.lowercased().hasPrefix("text=") || textPayload.lowercased().hasPrefix("text:") {
                textPayload = String(textPayload.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            arguments["text"] = cleanArgumentToken(textPayload)
            
        case "scroll":
            // scroll(direction, amount)
            if trimmed.contains(",") {
                let parts = trimmed.components(separatedBy: ",")
                arguments["direction"] = cleanArgumentToken(parts[0])
                if parts.count > 1, let amount = Int(cleanArgumentToken(parts[1])) {
                    arguments["amount"] = amount
                }
            } else {
                arguments["direction"] = cleanArgumentToken(trimmed)
            }
            
        case "point":
            // point(x, y)
            let parts = trimmed.components(separatedBy: ",")
            if parts.count >= 2,
               let x = Double(cleanArgumentToken(parts[0])),
               let y = Double(cleanArgumentToken(parts[1])) {
                arguments["x"] = x
                arguments["y"] = y
            }
            
        case "open_app":
            // open_app(name)
            var appName = trimmed
            if appName.lowercased().hasPrefix("name=") || appName.lowercased().hasPrefix("name:") {
                appName = String(appName.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if appName.lowercased().hasPrefix("app_name=") || appName.lowercased().hasPrefix("app_name:") {
                appName = String(appName.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            arguments["name"] = cleanArgumentToken(appName)
            
        case "wait":
            // wait(seconds)
            var secString = trimmed
            if secString.lowercased().hasPrefix("seconds=") || secString.lowercased().hasPrefix("seconds:") {
                secString = String(secString.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let sec = Double(cleanArgumentToken(secString)) {
                arguments["seconds"] = sec
            }
            
        case "escalate":
            // escalate(reason)
            var reasonString = trimmed
            if reasonString.lowercased().hasPrefix("reason=") || reasonString.lowercased().hasPrefix("reason:") {
                reasonString = String(reasonString.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            arguments["reason"] = cleanArgumentToken(reasonString)
            
        default:
            // Generic key-value or raw positional parsing
            let pairs = trimmed.components(separatedBy: ",")
            for pair in pairs {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    let k = cleanArgumentToken(kv[0])
                    let v = cleanArgumentToken(kv[1])
                    arguments[k] = v
                }
            }
        }
        
        return arguments
    }
    
    private func cleanArgumentToken(_ rawToken: String) -> String {
        var token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if (token.hasPrefix("\"") && token.hasSuffix("\"")) ||
            (token.hasPrefix("'") && token.hasSuffix("'")) {
            token = String(token.dropFirst().dropLast())
        }
        // Strip parameter label only if it matches standard parameter identifier syntax (e.g. element_id="elem_1")
        // Don't strip if '=' is part of a shell command or text (like find . -name "*.txt" or export FOO=BAR)
        let parameterPrefixPattern = #"^[a-zA-Z_][a-zA-Z0-9_]*\s*=\s*"#
        if let regex = try? NSRegularExpression(pattern: parameterPrefixPattern) {
            let nsRange = NSRange(token.startIndex..<token.endIndex, in: token)
            if let match = regex.firstMatch(in: token, options: [], range: nsRange),
               match.range.location == 0 {
                token = String(token[token.index(token.startIndex, offsetBy: match.range.length)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if (token.hasPrefix("\"") && token.hasSuffix("\"")) ||
                    (token.hasPrefix("'") && token.hasSuffix("'")) {
                    token = String(token.dropFirst().dropLast())
                }
            }
        }
        return token
    }
    
    private func parseJSONDictionary(_ jsonString: String) -> [String: Any]? {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }
    
    private func formatArgumentsForSummary(_ args: [String: Any]) -> String {
        return args.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
    }

    // MARK: - Spoken Answer & Failure Explanation Synthesis

    /// Uses the resident 9B model to synthesize a natural spoken answer
    /// when a tool execution produces informative output (e.g. terminal ls/grep output, web search, etc.).
    func synthesizeSpokenAnswer(
        userGoal: String,
        toolName: String,
        toolResult: String
    ) async -> String {
        let maxResultChars = 1500
        let truncatedResult = toolResult.count > maxResultChars
            ? "\(toolResult.prefix(maxResultChars))... [truncated]"
            : toolResult

        let lowerResult = toolResult.lowercased()
        var contextNote = ""
        if lowerResult.contains("successfully opened") || lowerResult.contains("exit status 0") {
            contextNote = "\nNote: The command succeeded with exit status 0 (no errors). Confirm to the user that the file or application was opened/completed."
        }

        let synthesisUserPrompt = """
User request: "\(userGoal)"
Tool executed: \(toolName)
Tool output:
\(truncatedResult)\(contextNote)

Based on the tool output above, provide a direct, friendly, and concise spoken answer to the user in 1 or 2 sentences.
Speak conversationally: all lowercase, no markdown formatting, no bullet points, no emojis.
"""

        let messages: [OMLXChatMessage] = [
            OMLXChatMessage(
                role: .system,
                text: "You are Clicky, a friendly voice companion on macOS. Give a concise, direct spoken answer based on the tool result. All lowercase, no markdown, no emojis."
            ),
            OMLXChatMessage(role: .user, text: synthesisUserPrompt)
        ]

        do {
            let response = try await omlxClient.sendChatCompletionRequest(
                model: OMLXClient.actorModelAlias,
                messages: messages,
                temperature: 0.1,
                maxTokens: 120,
                enableThinking: false
            )
            let cleaned = stripThinkingTags(from: response.contentText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
        } catch {
            print("⚠️ AgentActorLoop: Failed to synthesize spoken answer: \(error)")
        }

        // Clean fallback if synthesis fails
        if lowerResult.contains("successfully opened") {
            return "i've opened that for you."
        }
        if toolResult.isEmpty || toolResult == "(command produced no output)" {
            return "Done! The command finished with no output."
        }
        return "Done! Here is what was found: \(toolResult.prefix(120))"
    }

    /// Generates a friendly, specific explanation of why a task could not be completed.
    func generateFailureExplanation(stateManager: AgentStateManager) async -> String {
        let failureReason = stateManager.taskFailureReason
            ?? stateManager.lastEscalationFailureReason
            ?? "Could not complete all planned actions"
        let activeSubgoalDescription = stateManager.currentActiveSubgoal()?.description ?? "the current step"
        let realLastError = stateManager.lastActualErrorMessage() ?? failureReason

        // Build brief action history snippet
        let recentActions = stateManager.compressedActionHistory.suffix(4).joined(separator: "\n")

        let explanationPrompt = """
User goal: "\(stateManager.userGoal)"
Task stopped on subgoal: "\(activeSubgoalDescription)"
Last recorded technical error: "\(realLastError)"
Recent actions:
\(recentActions)

In ONE friendly spoken sentence, explain to the user why the task could not be completed based STRICTLY on the last recorded technical error: "\(realLastError)".
CRITICAL: Do NOT invent causes. Do NOT claim the page does not exist or the API was empty unless the technical error literally says so.
All lowercase, no markdown, no emojis.
"""

        let messages: [OMLXChatMessage] = [
            OMLXChatMessage(
                role: .system,
                text: "You are Clicky, a friendly voice companion on macOS. Explain why a task failed concisely in one spoken sentence based strictly on the recorded error. All lowercase, no markdown, no emojis."
            ),
            OMLXChatMessage(role: .user, text: explanationPrompt)
        ]

        do {
            let response = try await omlxClient.sendChatCompletionRequest(
                model: OMLXClient.actorModelAlias,
                messages: messages,
                temperature: 0.1,
                maxTokens: 100,
                enableThinking: false
            )
            let cleaned = stripThinkingTags(from: response.contentText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
        } catch {
            print("⚠️ AgentActorLoop: Failed to synthesize failure explanation: \(error)")
        }

        // Clean factual fallback
        return "i ran into an issue while \(activeSubgoalDescription.lowercased()): \(realLastError.prefix(100).lowercased())."
    }

    // MARK: - Normalization & Goal Satisfaction Helpers

    /// Normalizes tool aliases (e.g. subgoal_complete, skip) to canonical tool names.
    private func normalizeToolName(_ name: String) -> String {
        var clean = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let parenIndex = clean.firstIndex(of: "(") {
            clean = String(clean[..<parenIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch clean {
        case "subgoal_complete", "mark_done", "skip", "finish_subgoal":
            return "done"
        case "type_text":
            return "type"
        case "terminal", "run_terminal", "exec", "bash", "zsh", "sh":
            return "run_terminal_command"
        case "launch_app", "open":
            return "open_app"
        default:
            return clean
        }
    }

    /// Checks if a subgoal is already satisfied by the current screen/system state before calling the model.
    private func isSubgoalAlreadySatisfied(_ subgoal: AgentSubgoal, perceptionResult: PerceptionResult) -> Bool {
        let desc = subgoal.description.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let activeApp = perceptionResult.frontmostApplicationName.lowercased()

        let openPrefixes = ["open ", "switch to ", "launch ", "activate "]
        for prefix in openPrefixes {
            if desc.hasPrefix(prefix) {
                var target = String(desc.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                for suffix in [" browser", " application", " app"] {
                    if target.hasSuffix(suffix) {
                        target = String(target.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                    }
                }
                if !target.isEmpty && (activeApp == target || activeApp.contains(target)) {
                    return true
                }
            }
        }
        return false
    }

    /// Extracts a recognized application name from a string for fallback opening.
    private func extractTargetAppName(from text: String) -> String? {
        let lower = text.lowercased()
        let knownApps = [
            "safari": "Safari",
            "pages": "Pages",
            "terminal": "Terminal",
            "finder": "Finder",
            "notes": "Notes",
            "mail": "Mail",
            "messages": "Messages",
            "music": "Music",
            "system settings": "System Settings",
            "calculator": "Calculator",
            "textedit": "TextEdit",
            "keynote": "Keynote",
            "numbers": "Numbers",
            "xcode": "Xcode"
        ]
        for (key, name) in knownApps {
            if lower.contains(key) {
                return name
            }
        }
        return nil
    }
}
