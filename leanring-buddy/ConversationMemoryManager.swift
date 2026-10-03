//
//  ConversationMemoryManager.swift
//  leanring-buddy
//
//  Maintains short-term conversational context and task artifacts in-process.
//  Provides compact conversation history and outcome summaries from recent tasks
//  to the triage and planner prompts so follow-up interactions maintain continuity.
//

import Foundation

/// Snapshot of an executed task or tool invocation.
struct TaskArtifactSnapshot {
    let goal: String
    let actionSummary: String
    let outputPreview: String
    let targetApp: String?
    let timestamp: Date

    var promptSummary: String {
        var text = "Goal: \"\(goal)\" -> Action: \(actionSummary)"
        if !outputPreview.isEmpty {
            let cleanPreview = outputPreview.replacingOccurrences(of: "\n", with: " ")
            let truncated = cleanPreview.count > 100 ? "\(cleanPreview.prefix(97))..." : cleanPreview
            text += " (Result: \(truncated))"
        }
        return text
    }
}

@MainActor
class ConversationMemoryManager {
    static let shared = ConversationMemoryManager()

    /// Maximum number of recent conversational exchanges to retain verbatim.
    private let maximumRecentExchanges: Int = 3

    /// Recent user/assistant dialogue turns.
    private(set) var recentExchanges: [(userTranscript: String, assistantResponse: String)] = []

    /// The outcome of the most recently executed task or direct tool call.
    private(set) var lastTaskArtifact: TaskArtifactSnapshot? = nil

    // MARK: - Recording

    /// Records an exchange between user and Clicky.
    func recordExchange(userTranscript: String, assistantResponse: String) {
        recentExchanges.append((userTranscript: userTranscript, assistantResponse: assistantResponse))
        if recentExchanges.count > maximumRecentExchanges {
            recentExchanges.removeFirst(recentExchanges.count - maximumRecentExchanges)
        }
    }

    /// Records the artifact or outcome of a completed tool or multi-step task.
    func recordTaskArtifact(
        goal: String,
        actionSummary: String,
        outputPreview: String,
        targetApp: String? = nil
    ) {
        self.lastTaskArtifact = TaskArtifactSnapshot(
            goal: goal,
            actionSummary: actionSummary,
            outputPreview: outputPreview,
            targetApp: targetApp,
            timestamp: Date()
        )
    }

    /// Clears task artifact once consumed or if a new unrelated topic starts.
    func clearTaskArtifact() {
        self.lastTaskArtifact = nil
    }

    // MARK: - Prompt Formatting

    /// Formats recent dialogue as a compact string snippet (under ~120 tokens).
    func formatRecentConversationSnippet() -> String? {
        guard !recentExchanges.isEmpty else { return nil }
        var lines: [String] = []
        for exchange in recentExchanges {
            let u = exchange.userTranscript.replacingOccurrences(of: "\n", with: " ").prefix(90)
            let a = exchange.assistantResponse.replacingOccurrences(of: "\n", with: " ").prefix(110)
            lines.append("User: \"\(u)\"")
            lines.append("Clicky: \"\(a)\"")
        }
        return lines.joined(separator: "\n")
    }

    /// Formats the last task artifact as a single context line.
    func formatLastTaskArtifactSummary() -> String? {
        guard let artifact = lastTaskArtifact else { return nil }
        // Expire task artifact if older than 5 minutes
        if Date().timeIntervalSince(artifact.timestamp) > 300 {
            self.lastTaskArtifact = nil
            return nil
        }
        return artifact.promptSummary
    }
}
