# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via Apple's on-device SFSpeechRecognizer, and executes tasks using a local single-model agent architecture served by oMLX (`http://localhost:8000/v1`):
- **Generative Model (Triage, Planner, Actor)**: `qwen3.5-9b` (pinned, resident)
- **Embedder**: `qwen3-embedding-0.6b` (pinned, resident)

Task state lives entirely outside model context in an external state manager. Perception reads the macOS `AXUIElement` hierarchy first, falling back to multi-monitor screenshots only when the accessibility tree is insufficient. Past trajectories and UI maps are retrieved from a pure Swift in-process SQLite vector store using Apple's Accelerate framework. When executing a task, Clicky relocates to a task progress dock below the menu bar clock in the top-right corner, expanding on hover to reveal tool-by-tool progress. Spoken replies are delivered via AVSpeechSynthesizer with element pointing via the blue cursor overlay.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **Model Server**: oMLX serving two models over an OpenAI-compatible API at `http://localhost:8000/v1`
  - `qwen3.5-9b`: Pinned, resident model handling triage, high-level planning, and step-by-step tool execution with thinking tags disabled for instant responses
  - `qwen3-embedding-0.6b`: Pinned, resident embedder for RAG retrieval
- **Speech-to-Text**: Apple SFSpeechRecognizer (on-device, zero-latency push-to-talk)
- **Text-to-Speech**: AVSpeechSynthesizer (on-device, zero-latency)
- **Perception Layer**: macOS Accessibility API (`AXUIElement`) inspection first; ScreenCaptureKit screenshot fallback only when AX tree is insufficient
- **External State Management**: Task goal, planned subgoals, compressed action history, and failure counters live in `AgentStateManager` outside model context
- **Minimal Local RAG**: In-process SQLite vector store (`LocalVectorStore`) storing trajectories and per-app UI maps with Accelerate `vDSP` cosine similarity
- **Task Progress Dock**: During task execution, Clicky stations below the menu bar clock in the top-right screen corner; hovering expands live tool execution steps
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap
- **Element Pointing**: Blue cursor overlay navigates to UI elements via bezier curve animation and speech bubbles
- **Tool Execution**: Accessibility actions (`kAXPressAction`, text values) with `CGEvent` mouse clicks and scroll fallback
- **Concurrency**: `@MainActor` isolation, async/await throughout

### Local AI Pipeline (per interaction)

```text
User speaks (ctrl+option held)
  → Apple SFSpeechRecognizer → transcript
  → Upfront spoken confirmation
  → Blue cursor docks to top-right screen corner (below menu bar clock)
  → PerceptionManager: inspects AXUIElement hierarchy (or captures fallback screenshots)
  → LocalVectorStore: RAG lookup via qwen3-embedding-0.6b for past trajectories & app UI map
  → AgentStateManager: initializes session with goal + RAG hints (state lives outside model)
  → AgentPlanner: qwen3.5-9b decomposes goal into ordered subgoals
  → AgentActorLoop (resident qwen3.5-9b):
      For each subgoal:
        → Capture fresh screen state (AX tree preferred)
        → Reconstruct fresh prompt from AgentStateManager
        → Model returns single tool call: run_applescript, run_terminal_command, click, type, scroll, point, open_app, wait, done, escalate
        → AgentToolExecutor executes tool via osascript (AppleScript), zsh shell, AXUIElement, or CGEvent
        → AgentStateManager compresses result into 1 line, increments/resets failure count
        → On 3 consecutive failures or explicit escalate → re-invoke AgentPlanner with failure context
  → On success: LocalVectorStore saves completed trajectory
  → Task dock dismisses, cursor returns to follow mouse
  → AVSpeechSynthesizer speaks completion
```

### Key Architecture Decisions

**Single Resident 9B Model**: Uses `qwen3.5-9b` for triage, planning, and execution without model swapping. With `enableThinking: false` and strict token limits, latency per step remains under 2 seconds while benefiting from 9B's stronger reasoning and formatting adherence over 4B. The legacy 4B model is evicted on launch.

**State Lives Outside the Model**: Task state (goal, plan, step history, RAG hits) lives in Clicky's own app layer (`AgentStateManager`), not in model context. Every call reconstructs the prompt fresh from that state.

**Accessibility Tree First, Screenshot Fallback**: Rather than capturing multi-monitor screenshots for every step, Clicky traverses the active window's `AXUIElement` tree. This provides exact coordinates, labels, and roles with zero vision model latency. Screen capture is reserved solely as a fallback for non-accessible apps (games, custom canvases).

**Pure Swift In-Process RAG**: The local vector store runs directly in-process via macOS system SQLite (`libsqlite3`) and calculates cosine similarity using Apple's Accelerate framework (`vDSP`). No external Python sidecars or external vector databases required.

**Task Progress Dock (Top-Right Screen Corner)**: When an agent task begins, the blue cursor flies up to the top-right corner of the screen right below the macOS menu bar clock. It features a compact circular badge with a pulsing glow that expands on hover into a floating frosted glass card displaying live, tool-by-tool progress with checkmarks and active spinners.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1310 | Central state machine. Coordinates push-to-talk, intelligent triage, perception, RAG lookup, planner, actor loop, TTS, element pointing, spoken tool synthesis, and task dock. |
| `OMLXClient.swift` | ~475 | HTTP client wrapper for oMLX OpenAI-compatible endpoints (`localhost:8000/v1`) and admin API. Configured for single resident 9B model + embedder with no swapping. |
| `PerceptionManager.swift` | ~380 | UI perception layer. Reads the `AXUIElement` hierarchy for active windows and falls back to ScreenCaptureKit screenshots only when permitted and necessary. |
| `AgentStateManager.swift` | ~320 | External task state manager. Owns task goal, subgoals, compressed 1-line action history, stall detection, and failure counters outside model context. |
| `AgentPlanner.swift` | ~190 | Planner orchestrator using `qwen3.5-9b`. Houses verbatim planner prompt, turns goal + screen state + RAG hints into ordered subgoals JSON with terminal and AppleScript preference. |
| `AgentActorLoop.swift` | ~1110 | Execution loop using resident `qwen3.5-9b`. Evaluates first-turn triage, executes atomic tool calls with terminal & AppleScript preference, argument parsing, stall prevention, and spoken answer/failure synthesis. |
| `AgentToolExecutor.swift` | ~630 | Executes agent tools: run_applescript (direct osascript via stdin with safety timeout), run_terminal_command (zsh with PATH resolution), click (AXUIElement with CGEvent fallback), type, scroll, point, open_app, wait, done, escalate, and clipboard. |
| `LocalVectorStore.swift` | ~350 | Pure Swift in-process SQLite vector store with Accelerate `vDSP` cosine similarity for trajectories, per-app UI maps, and user facts. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~700 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~925 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, dock flight, element pointing with bezier arcs, and multi-monitor coordinate mapping. |
| `AgentTaskDockWindow.swift` | ~270 | Dedicated top-right floating task progress dock window and SwiftUI view. Shows compact pulsing badge below menu bar clock; expands on hover to display live tool execution steps. |
| `AgentTaskProgressStep.swift` | ~100 | Data model representing individual tool execution steps with user-friendly formatting and completion status. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | On-device transcription provider backed by Apple's SFSpeechRecognizer. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `LocalTTSClient.swift` | ~80 | AVSpeechSynthesizer wrapper. Speaks text on-device. Exposes `isPlaying` for transient cursor scheduling. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `ObservationStore.swift` | ~65 | External working memory for Clicky. Offloads full tool outputs to disk in `~/Library/Caches/Clicky/obs/` and returns compact previews to keep context window bounded. |
| `ConversationMemoryManager.swift` | ~100 | In-process conversational memory manager. Retains short-term verbatim exchanges and recent task artifact snapshots for follow-up triage and planner context. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `DebugEventLogger.swift` | ~270 | Singleton terminal debug logger. Streams structured, emoji-prefixed, timestamped events to `~/Library/Logs/Clicky/debug.log` with in-place truncation and live synchronization. Run `tail -f ~/Library/Logs/Clicky/debug.log` to watch the full agent pipeline live. |

## Build & Run

```bash
# Terminal 1: Ensure oMLX is running at localhost:8000
# (serves pinned resident qwen3.5-9b and qwen3-embed)

# Terminal 2: Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
