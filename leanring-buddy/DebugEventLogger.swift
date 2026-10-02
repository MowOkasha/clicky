//
//  DebugEventLogger.swift
//  leanring-buddy
//
//  Streams structured debug events to ~/Library/Logs/Clicky/debug.log so you
//  can run `tail -f ~/Library/Logs/Clicky/debug.log` in a terminal to watch
//  every step of the agent pipeline in real-time: what the user said, which
//  perception path was taken, model swaps, token counts, tool executions, etc.
//
//  Thread safety: all file writes are serialized on a private background queue,
//  so log() can be called from any actor or thread without await or @MainActor.
//
//  Usage:
//    DebugEventLogger.shared.log(.voiceInput(transcript: "open safari"))
//
//  Terminal:
//    tail -f ~/Library/Logs/Clicky/debug.log
//    tail -f ~/Library/Logs/Clicky/debug.log | grep -E "TRIAGE|ACTOR|PLAN"
//

import Foundation

final class DebugEventLogger {

    // MARK: - Singleton

    static let shared = DebugEventLogger()

    // MARK: - Log File Setup

    private let logFileHandle: FileHandle?
    let logFileURL: URL

    // Serial queue ensures all file writes happen one at a time from any caller context
    private let writeQueue = DispatchQueue(label: "com.clicky.debuglogger", qos: .utility)

    private init() {
        let fileManager = FileManager.default

        // Use ~/Library/Logs/Clicky/ — the macOS-conventional location for app logs
        let logsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Clicky", isDirectory: true)

        try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        logFileURL = logsDirectory.appendingPathComponent("debug.log")

        // Ensure the file exists without recreating it if it already exists.
        // Truncating in-place preserves the file inode so active `tail -f` terminal streams
        // keep streaming live without requiring the user to quit and rerun tail.
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }

        if let existingFileHandle = try? FileHandle(forWritingTo: logFileURL) {
            try? existingFileHandle.truncate(atOffset: 0)
            logFileHandle = existingFileHandle
        } else {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
            logFileHandle = try? FileHandle(forWritingTo: logFileURL)
        }

        // Write the session header so it's easy to spot where a new run started
        let sessionHeader = """

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        🟢 CLICKY SESSION STARTED — \(formattedTimestamp())
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        """
        writeRawLine(sessionHeader)
    }

    // MARK: - Event Enum

    enum Event {
        /// The user's voice transcript, just captured from push-to-talk.
        case voiceInput(transcript: String)

        /// Result of PerceptionManager's UI state capture for a single step.
        case perception(
            app: String,
            windowTitle: String,
            elementCount: Int,
            usedScreenshotFallback: Bool
        )

        /// Result of the RAG lookup using the embedder model.
        case ragLookup(hintCount: Int, error: String?)

        /// Decision returned by the actor model's first-turn triage pass.
        case triageResult(
            decision: String,
            reason: String?,
            promptTokens: Int,
            completionTokens: Int,
            durationSeconds: Double
        )

        /// The model residency is being swapped between actor (4B) and planner (9B).
        case modelSwap(fromModel: String, toModel: String)

        /// The planner produced a list of subgoals for the task.
        case planGenerated(
            subgoals: [String],
            promptTokens: Int,
            completionTokens: Int,
            durationSeconds: Double
        )

        /// A new actor loop step is starting on a specific subgoal.
        case actorStepStarted(
            stepNumber: Int,
            subgoalIndex: Int,
            totalSubgoals: Int,
            attemptNumber: Int,
            subgoalDescription: String
        )

        /// The actor model returned a tool call decision for the current step.
        case actorResponse(
            toolName: String,
            argumentsSummary: String,
            promptTokens: Int,
            completionTokens: Int,
            durationSeconds: Double
        )

        /// A tool was executed by AgentToolExecutor, with its result.
        case toolExecution(toolName: String, argumentsSummary: String, result: String)

        /// The failure counter hit the escalation threshold on the current subgoal.
        case escalation(reason: String, consecutiveFailureCount: Int)

        /// Replanning is being triggered after an escalation.
        case replan(reason: String)

        /// The full multi-step task concluded (success or failure).
        case taskCompleted(totalSteps: Int, isSuccessful: Bool, failureReason: String? = nil)

        /// A successful trajectory was saved to the local RAG vector store.
        case ragSave(taskGoal: String)

        /// Text is about to be spoken via AVSpeechSynthesizer.
        case tts(spokenText: String)

        /// A separator to visually divide each user interaction in the log.
        case interactionSeparator

        /// A generic error event for catch blocks.
        case error(context: String, message: String)
    }

    // MARK: - Public Log Method

    /// Logs a debug event. Safe to call from any actor or thread — writes are serialized internally.
    func log(_ event: Event) {
        let timestamp = formattedTimestamp()

        switch event {

        case .voiceInput(let transcript):
            let separator = String(repeating: "─", count: 65)
            writeRawLine("")
            writeRawLine("\(timestamp) \(separator)")
            writeLine("\(timestamp) 🎤 VOICE      ─── User said: \"\(transcript)\"")

        case .perception(let app, let windowTitle, let elementCount, let usedScreenshotFallback):
            let methodLabel = usedScreenshotFallback ? "Screenshot fallback" : "AX tree"
            writeLine("\(timestamp) 🔍 PERCEPTION ─── \(methodLabel): \(app) (\(elementCount) elements) Window: \"\(windowTitle)\"")

        case .ragLookup(let hintCount, let error):
            if let errorMessage = error {
                writeLine("\(timestamp) 📚 RAG        ─── Lookup failed: \(errorMessage)")
            } else {
                writeLine("\(timestamp) 📚 RAG        ─── Queried embedder (qwen3-embed) — \(hintCount) hint(s) retrieved")
            }

        case .triageResult(let decision, let reason, let promptTokens, let completionTokens, let durationSeconds):
            writeLine("\(timestamp) 🧠 TRIAGE     ─── Model: qwen3.5-9b | Tokens: \(promptTokens)→\(completionTokens) | \(formattedDuration(durationSeconds))")
            if let reason = reason {
                writeLine("           └── Decision: \(decision) (\"\(reason)\")")
            } else {
                writeLine("           └── Decision: \(decision)")
            }

        case .modelSwap(let fromModel, let toModel):
            if fromModel != toModel {
                writeLine("\(timestamp) 🔄 MODEL_SWAP ─── \(fromModel) → \(toModel)")
            }

        case .planGenerated(let subgoals, let promptTokens, let completionTokens, let durationSeconds):
            writeLine("\(timestamp) 📋 PLAN       ─── Model: qwen3.5-9b | Tokens: \(promptTokens)→\(completionTokens) | \(formattedDuration(durationSeconds)) | \(subgoals.count) subgoal(s)")
            for (index, subgoal) in subgoals.enumerated() {
                let isLast = index == subgoals.count - 1
                let branch = isLast ? "└──" : "├──"
                writeLine("           \(branch) \(index + 1). \(subgoal)")
            }

        case .actorStepStarted(let stepNumber, let subgoalIndex, let totalSubgoals, let attemptNumber, let subgoalDescription):
            writeLine("\(timestamp) 🚀 STEP \(stepNumber)     ─── Subgoal \(subgoalIndex)/\(totalSubgoals) (attempt \(attemptNumber)): \"\(subgoalDescription)\"")

        case .actorResponse(let toolName, let argumentsSummary, let promptTokens, let completionTokens, let durationSeconds):
            writeLine("\(timestamp) 🧠 ACTOR      ─── Model: qwen3.5-9b | Tokens: \(promptTokens)→\(completionTokens) | \(formattedDuration(durationSeconds))")
            writeLine("           └── Tool: \(toolName)(\(argumentsSummary))")

        case .toolExecution(let toolName, let argumentsSummary, let result):
            // Truncate very long results (e.g. AX tree dumps from read_webpage)
            let truncatedResult = result.count > 200 ? "\(result.prefix(197))..." : result
            writeLine("\(timestamp) 🔧 TOOL_EXEC  ─── \(toolName)(\(argumentsSummary)) → \"\(truncatedResult)\"")

        case .escalation(let reason, let consecutiveFailureCount):
            writeLine("\(timestamp) 🚨 ESCALATION ─── \(consecutiveFailureCount) consecutive failure(s): \(reason)")

        case .replan(let reason):
            writeLine("\(timestamp) 🔁 REPLAN     ─── Triggering replanning: \(reason)")

        case .taskCompleted(let totalSteps, let isSuccessful, let failureReason):
            let statusLabel = isSuccessful ? "✅ TASK_DONE" : "❌ TASK_FAILED"
            if let failureReason = failureReason, !isSuccessful {
                writeLine("\(timestamp) \(statusLabel)  ─── \(totalSteps) step(s) taken | Reason: \(failureReason)")
            } else {
                writeLine("\(timestamp) \(statusLabel)  ─── \(totalSteps) step(s) taken")
            }

        case .ragSave(let taskGoal):
            writeLine("\(timestamp) 💾 RAG_SAVE   ─── Saved trajectory for \"\(taskGoal)\"")

        case .tts(let spokenText):
            writeLine("\(timestamp) 🔊 TTS        ─── Speaking: \"\(spokenText)\"")

        case .interactionSeparator:
            // Intentionally no-op — separator is written inside .voiceInput
            break

        case .error(let context, let message):
            writeLine("\(timestamp) ⚠️  ERROR      ─── [\(context)] \(message)")
        }
    }

    // MARK: - Private Helpers

    private func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    private func formattedDuration(_ seconds: Double) -> String {
        return String(format: "%.2fs", seconds)
    }

    private func writeLine(_ text: String) {
        writeRawLine(text)
        // Also mirror to Xcode console so the logger supplements rather than replaces print()
        print(text)
    }

    /// Serializes file writes through writeQueue so concurrent callers never interleave lines.
    private func writeRawLine(_ text: String) {
        guard let fileHandle = logFileHandle else { return }
        let lineWithNewline = text + "\n"
        guard let data = lineWithNewline.data(using: .utf8) else { return }
        writeQueue.async {
            fileHandle.write(data)
            // Immediately synchronize file buffers to disk so `tail -f` streams every log entry live in real-time
            try? fileHandle.synchronize()
        }
    }
}
