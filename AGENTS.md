# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via Apple's on-device SFSpeechRecognizer, and runs a two-stage local AI pipeline: a vision model analyzes the screenshot, then a reasoning model generates a response. The app speaks the reply via AVSpeechSynthesizer. A blue cursor overlay can fly to and point at UI elements the model references on any connected monitor.

All AI inference runs locally via Ollama — no external API keys or network calls required for core functionality.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **Unified Model**: `qwen3.5:9b-q5` (Q5_K_M GGUF, ~6.6GB) via local Ollama — handles vision (screenshot analysis), reasoning (response generation), and native tool calling in a single model load
- **Speech-to-Text**: Apple SFSpeechRecognizer (on-device, zero-latency push-to-talk)
- **Text-to-Speech**: AVSpeechSynthesizer (on-device, zero-latency)
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: The reasoning model embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Agentic Tool Calling**: Native Ollama `tools` API with a think→act→observe loop (up to 10 iterations). Tools: open_app, run_terminal_command, open_url, search_web, read_webpage, type_text, take_screenshot, list_running_apps, read_clipboard, write_clipboard.
- **Memory**: Persistent conversation memory via a local Mem0 FastAPI sidecar (`memory-server/`).
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Model Memory Management**: Model is loaded on-demand and immediately unloaded via `keep_alive: 0` after each use. Model is unloaded when idle (hotkey not held).

### Local AI Pipeline (per interaction)

```text
User speaks (ctrl+option held)
  → Apple SFSpeechRecognizer → transcript
  → ScreenCaptureKit → screenshots
  → Mem0 sidecar → retrieve relevant past memories
  → qwen3.5:9b-q5 (Ollama /api/chat with tools + images)
      Agent Loop (up to 10 iterations):
        → model returns tool_calls? → AgentToolExecutor runs tool → feed result back → repeat
        → model returns text response? → done
  → UNLOAD qwen3.5:9b-q5
  → AVSpeechSynthesizer → spoken audio
  → Cursor overlay → animate to pointed element (if any)
  → Mem0 sidecar → save this exchange
```

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Single Model for Vision + Reasoning + Tools**: `qwen3.5:9b-q5` is a unified multimodal model that receives screenshots as base64 images alongside the user transcript in a single Ollama `/api/chat` call. This eliminates the two-model sequential load/unload cycle and halves the RAM churn compared to the previous architecture.

**Agentic Tool Loop**: `AgentLoop` implements the ReAct-style think→act→observe pattern. It sends the model's tool_calls to `AgentToolExecutor`, feeds results back as `role: "tool"` messages, and loops until the model produces a plain text response or 10 iterations are reached. The model stays loaded throughout the loop and is unloaded immediately after.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

**Mem0 Memory Sidecar**: A local FastAPI server (`memory-server/server.py`) wraps the `mem0ai` Python library and persists conversation context across sessions using an embedded vector store. The Swift `Mem0Client` communicates with it over localhost.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~920 | Central state machine. Owns dictation, shortcut monitoring, screen capture, agentic AI pipeline, TTS, memory, and overlay management. Coordinates the full push-to-talk → screenshot → agent loop → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~700 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~39 | Protocol surface and provider factory for voice transcription backends. Factory always returns `AppleSpeechTranscriptionProvider`. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | On-device transcription provider backed by Apple's SFSpeechRecognizer. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `OllamaAPI.swift` | ~220 | Local Ollama API client. Streaming chat with native tool calling support — sends screenshots as base64 images, passes tool definitions to Ollama, parses `tool_calls` from the streamed response. |
| `OllamaModelMemoryManager.swift` | ~60 | Sends `keep_alive: 0` requests to Ollama to force immediate model unload after inference, freeing RAM/VRAM. |
| `AgentToolDefinition.swift` | ~200 | JSON schema definitions for all 10 agentic tools. Converts to Ollama's tool format for the API request. |
| `AgentToolExecutor.swift` | ~310 | Executes agentic tools by name. Implements open_app, run_terminal_command, open_url, search_web, read_webpage, type_text, take_screenshot, list_running_apps, read_clipboard, write_clipboard using NSWorkspace, Process/zsh, URLSession, NSPasteboard, and ScreenCaptureKit. |
| `AgentLoop.swift` | ~160 | The agentic think→act→observe orchestrator. Calls the model, parses tool_calls, executes tools via AgentToolExecutor, feeds results back as "tool" role messages, and loops until the model produces a final text response or 10 iterations are reached. |
| `LocalTTSClient.swift` | ~80 | AVSpeechSynthesizer wrapper. Speaks text on-device. Exposes `isPlaying` for transient cursor scheduling. |
| `Mem0Client.swift` | ~100 | Swift HTTP client for the local Mem0 memory sidecar. Retrieves relevant past memories before inference and saves new exchanges after. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `memory-server/server.py` | ~80 | FastAPI sidecar that wraps `mem0ai` for persistent conversation memory. Exposes `/add`, `/search`, and `/reset` endpoints on localhost. |

## Build & Run

```bash
# Start the Mem0 memory sidecar (in a separate terminal, keep running)
cd memory-server
pip install -e .
python server.py

# Ensure Ollama is running with the unified model
# (qwen3.5:9b-q5 was created from the Q5_K_M GGUF via a custom Modelfile)
ollama list  # verify qwen3.5:9b-q5 is present

# Open in Xcode
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
