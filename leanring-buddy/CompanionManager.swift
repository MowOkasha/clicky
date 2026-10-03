//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation

import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    /// Sets the target location and bubble text for the cursor pointing animation.
    func setPointingTarget(location: CGPoint, label: String? = nil) {
        self.detectedElementScreenLocation = location
        self.detectedElementBubbleText = label
        if let matchingScreen = NSScreen.screens.first(where: { $0.frame.contains(location) }) {
            self.detectedElementDisplayFrame = matchingScreen.frame
        }
    }

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

    // MARK: - Agent Task Progress & Dock

    /// Whether an agentic multi-step task is currently executing.
    @Published var isAgentTaskRunning: Bool = false

    /// Live progress steps of the currently executing agent task.
    @Published var agentTaskProgressSteps: [AgentTaskProgressStep] = []

    /// Whether the top-right task dock is currently expanded via hover.
    @Published var isAgentTaskDockExpanded: Bool = false

    /// Dock window manager for the top-right task progress indicator.
    let agentTaskDockWindowManager = AgentTaskDockWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.


    private lazy var localTTSClient: LocalTTSClient = {
        return LocalTTSClient()
    }()

    /// Tool executor for the agent loop — handles click, type, scroll, point, open_app, etc.
    private lazy var agentToolExecutor: AgentToolExecutor = {
        let executor = AgentToolExecutor()
        executor.companionManager = self
        return executor
    }()

    // MARK: - Local Agent Architecture Components (oMLX, Perception, State, Planner, Actor, RAG)

    let omlxClient = OMLXClient()
    let perceptionManager = PerceptionManager()
    let agentStateManager = AgentStateManager()
    let localVectorStore = LocalVectorStore()

    private lazy var agentPlanner: AgentPlanner = {
        return AgentPlanner(omlxClient: omlxClient)
    }()

    private lazy var agentActorLoop: AgentActorLoop = {
        return AgentActorLoop(
            omlxClient: omlxClient,
            toolExecutor: agentToolExecutor,
            perceptionManager: perceptionManager
        )
    }()

    /// Conversation history for multi-turn interactions.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false


    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            agentTaskDockWindowManager.hideDock()
            isAgentTaskRunning = false
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }



    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()

        // Enforce idle model baseline in oMLX: Embedder and 9B pinned, legacy 4B evicted
        Task {
            await omlxClient.ensureIdleModelConfiguration()
        }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true


        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil

    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            localTTSClient.stopPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    


            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        self?.processUserTranscript(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }



    // MARK: - AI Response Pipeline

    /// Strips any <think>...</think> tags that reasoning models may output.
    static func stripThinkingTags(from text: String) -> String {
        let pattern = "(?s)<think>.*?</think>"
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Orchestrates the intelligent request routing, direct question answering,
    /// selective perception, and agentic workflow execution:
    ///   1. First-turn triage using resident qwen3.5-9b evaluates the user prompt and screen state.
    ///   2. Direct questions are answered immediately via TTS (no dock, no screenshots, no 9B planner).
    ///   3. Single direct tools are executed immediately.
    ///   4. Multi-step workflows move the blue cursor to the top-right dock, plan via qwen3.5-9b,
    ///      and execute each subgoal via qwen3.5-9b.
    private func processUserTranscript(transcript: String) {
        currentResponseTask?.cancel()
        localTTSClient.stopPlayback()

        // Reset previous task state
        isAgentTaskRunning = false
        agentTaskProgressSteps = []
        agentTaskDockWindowManager.hideDock()

        currentResponseTask = Task {
            voiceState = .processing
            DebugEventLogger.shared.log(.voiceInput(transcript: transcript))

            do {
                // Step 1: Capture initial screen state via perception (AXUIElement hierarchy first)
                let initialPerception = await perceptionManager.captureCurrentScreenState(allowScreenshotFallback: true)
                guard !Task.isCancelled else { return }

                // Step 2: Local RAG Lookup (Embedder + in-process vector store)
                var retrievedRAGHints: [String] = []
                do {
                    let queryEmbedding = try await omlxClient.generateEmbeddingVector(for: transcript)
                    let pastTrajectories = await localVectorStore.findRelevantPastTrajectories(
                        queryEmbedding: queryEmbedding,
                        appName: initialPerception.frontmostApplicationName
                    )
                    let cachedUIMap = await localVectorStore.findAppUIMap(appName: initialPerception.frontmostApplicationName)

                    retrievedRAGHints = pastTrajectories
                    if let uiMapHint = cachedUIMap {
                        retrievedRAGHints.append(uiMapHint)
                    }
                    print("📚 CompanionManager: Retrieved \(retrievedRAGHints.count) RAG hint(s)")
                    DebugEventLogger.shared.log(.ragLookup(hintCount: retrievedRAGHints.count, error: nil))
                } catch {
                    print("⚠️ CompanionManager: Local RAG lookup skipped/failed: \(error)")
                    DebugEventLogger.shared.log(.ragLookup(hintCount: 0, error: error.localizedDescription))
                }

                // Step 3: Initialize External State Manager (state lives outside model)
                agentStateManager.initializeTaskSession(
                    userGoal: transcript,
                    retrievedRAGHints: retrievedRAGHints
                )

                // Step 4: First-turn Triage via resident qwen3.5-9b
                let triageDecision = try await agentActorLoop.evaluateTriageTurn(
                    stateManager: agentStateManager,
                    perceptionResult: initialPerception
                )
                guard !Task.isCancelled else { return }

                switch triageDecision {
                case .directAnswer(let directAnswerText):
                    print("💬 CompanionManager: Direct answer from Actor: \"\(directAnswerText)\"")
                    voiceState = .responding

                    conversationHistory.append((
                        userTranscript: transcript,
                        assistantResponse: directAnswerText
                    ))
                    if conversationHistory.count > 10 {
                        conversationHistory.removeFirst(conversationHistory.count - 10)
                    }

                    // Speak the direct answer out loud
                    do {
                        try await localTTSClient.speakText(directAnswerText)
                    } catch {
                        print("Local TTS direct answer error: \(error)")
                    }

                    voiceState = .idle
                    scheduleTransientHideIfNeeded()
                    return

                case .directTool(let toolCall):
                    print("⚡️ CompanionManager: Direct tool from Actor triage: \(toolCall.toolName)")
                    voiceState = .responding
                    try? await localTTSClient.speakText("on it")
                    voiceState = .processing

                    agentToolExecutor.currentPerceptionLiveElementMap = initialPerception.elementLiveReferenceMap
                    let executionResult = await agentToolExecutor.execute(
                        toolName: toolCall.toolName,
                        arguments: toolCall.arguments
                    )
                    let toolSummary = AgentTaskProgressStep.createSummary(
                        toolName: toolCall.toolName,
                        arguments: toolCall.arguments
                    )
                    print("⚡️ Direct tool executed: \(toolSummary) -> \(executionResult)")

                    let spokenFeedback: String
                    let informationalTools = ["run_terminal_command", "run_applescript", "search_web", "read_webpage", "read_clipboard", "list_running_apps"]
                    if informationalTools.contains(toolCall.toolName) {
                        // For terminal commands and informational tools, synthesize a natural spoken response answering the user's question
                        spokenFeedback = await agentActorLoop.synthesizeSpokenAnswer(
                            userGoal: transcript,
                            toolName: toolCall.toolName,
                            toolResult: executionResult
                        )
                    } else if executionResult.lowercased().hasPrefix("error") {
                        spokenFeedback = "I ran into an issue: \(executionResult)"
                    } else {
                        spokenFeedback = "Done!"
                    }

                    voiceState = .responding
                    DebugEventLogger.shared.log(.tts(spokenText: spokenFeedback))
                    try? await localTTSClient.speakText(spokenFeedback)

                    conversationHistory.append((
                        userTranscript: transcript,
                        assistantResponse: spokenFeedback
                    ))
                    if conversationHistory.count > 10 {
                        conversationHistory.removeFirst(conversationHistory.count - 10)
                    }

                    voiceState = .idle
                    scheduleTransientHideIfNeeded()
                    return

                case .needsPlan(let planningReason):
                    print("📋 CompanionManager: Multi-step task needs plan (\(planningReason)). Activating dock and planner...")

                    // Upfront spoken confirmation
                    voiceState = .responding
                    try? await localTTSClient.speakText("on it")
                    guard !Task.isCancelled else { return }

                    // Move blue cursor to top-right task dock
                    voiceState = .processing
                    isAgentTaskRunning = true
                    agentTaskProgressSteps = [
                        AgentTaskProgressStep(
                            toolName: "perception",
                            summary: "Inspecting UI hierarchy & active window...",
                            isComplete: true
                        ),
                        AgentTaskProgressStep(
                            toolName: "plan",
                            summary: "Planning: \(planningReason)",
                            isComplete: false
                        )
                    ]



                    // Invoke Planner (qwen3.5-9b on demand)
                    let plannedSubgoals = try await agentPlanner.generatePlan(
                        stateManager: agentStateManager,
                        screenSummaryText: initialPerception.formattedElementListText,
                        fallbackScreenshots: initialPerception.fallbackScreenshots
                    )

                    agentStateManager.updatePlannedSubgoals(with: plannedSubgoals)
                    if let planIndex = agentTaskProgressSteps.firstIndex(where: { $0.toolName == "plan" }) {
                        agentTaskProgressSteps[planIndex].isComplete = true
                    }

                    for subgoal in plannedSubgoals {
                        agentTaskProgressSteps.append(
                            AgentTaskProgressStep(toolName: "subgoal", summary: subgoal.description, isComplete: false)
                        )
                    }

                    guard !Task.isCancelled else {
                        isAgentTaskRunning = false
                        agentTaskDockWindowManager.hideDock()
                        return
                    }

                    var replanAttemptsCount = 0
                    let maximumReplanAttemptsAllowed = 2

                    // Run Actor Loop (resident qwen3.5-9b)
                    let actorResult = try await agentActorLoop.runActorLoop(
                        stateManager: agentStateManager,
                        onStepStarted: { [weak self] toolName, arguments in
                            guard let self = self else { return }
                            let summary = AgentTaskProgressStep.createSummary(toolName: toolName, arguments: arguments)
                            self.agentTaskProgressSteps.append(
                                AgentTaskProgressStep(toolName: toolName, summary: summary, isComplete: false)
                            )
                        },
                        onStepCompleted: { [weak self] toolName, _ in
                            guard let self = self else { return }
                            if let lastIndex = self.agentTaskProgressSteps.indices.last {
                                self.agentTaskProgressSteps[lastIndex].isComplete = true
                            }
                        },
                        onEscalationNeeded: { [weak self] failureReason in
                            guard let self = self else { return false }

                            replanAttemptsCount += 1
                            if replanAttemptsCount > maximumReplanAttemptsAllowed {
                                print("🚨 CompanionManager: Reached maximum replan limit (\(maximumReplanAttemptsAllowed)). Stopping task to prevent infinite loop.")
                                self.agentStateManager.recordTaskFailure(reason: "Gave up after \(maximumReplanAttemptsAllowed) replan attempts: \(failureReason)")
                                return false
                            }

                            print("🚨 CompanionManager: Escalation triggered (\(failureReason)). Replanning with qwen3.5-9b (Attempt \(replanAttemptsCount)/\(maximumReplanAttemptsAllowed))...")
                            DebugEventLogger.shared.log(.replan(reason: "\(failureReason) [attempt \(replanAttemptsCount)/\(maximumReplanAttemptsAllowed)]"))
                            self.agentTaskProgressSteps.append(
                                AgentTaskProgressStep(toolName: "replan", summary: "Replanning: \(failureReason)", isComplete: false)
                            )

                            let freshPerception = await self.perceptionManager.captureCurrentScreenState(
                                allowScreenshotFallback: true
                            )
                            let replannedSubgoals = try? await self.agentPlanner.generatePlan(
                                stateManager: self.agentStateManager,
                                screenSummaryText: freshPerception.formattedElementListText,
                                fallbackScreenshots: freshPerception.fallbackScreenshots
                            )

                            if let newSubgoals = replannedSubgoals {
                                self.agentStateManager.updatePlannedSubgoals(with: newSubgoals)
                                if let replanIndex = self.agentTaskProgressSteps.firstIndex(where: { $0.toolName == "replan" && !$0.isComplete }) {
                                    self.agentTaskProgressSteps[replanIndex].isComplete = true
                                }
                                for subgoal in newSubgoals {
                                    self.agentTaskProgressSteps.append(
                                        AgentTaskProgressStep(toolName: "subgoal", summary: subgoal.description, isComplete: false)
                                    )
                                }
                                return true
                            }
                            return false
                        }
                    )

                    // Mark all remaining task dock steps complete
                    for index in agentTaskProgressSteps.indices {
                        agentTaskProgressSteps[index].isComplete = true
                    }

                    guard !Task.isCancelled else {
                        isAgentTaskRunning = false
                        agentTaskDockWindowManager.hideDock()
                        return
                    }

                    // Task execution concluded
                    isAgentTaskRunning = false
                    DebugEventLogger.shared.log(.taskCompleted(
                        totalSteps: actorResult.totalStepsTaken,
                        isSuccessful: actorResult.isTaskSuccessful,
                        failureReason: actorResult.isTaskSuccessful ? nil : agentStateManager.taskFailureReason
                    ))

                    // Step 9: On task success, write trajectory back into RAG store
                    if actorResult.isTaskSuccessful {
                        let trajectorySummary = agentStateManager.buildCompletedTrajectorySummary()
                        Task {
                            if let embedding = try? await omlxClient.generateEmbeddingVector(for: transcript) {
                                await localVectorStore.saveSuccessfulTrajectory(
                                    taskGoal: transcript,
                                    appName: initialPerception.frontmostApplicationName,
                                    trajectorySummary: trajectorySummary,
                                    embedding: embedding
                                )
                                DebugEventLogger.shared.log(.ragSave(taskGoal: transcript))
                            }
                        }
                    }

                    // Step 10: Speak final confirmation to the user
                    let completionPhrase: String
                    if actorResult.isTaskSuccessful {
                        completionPhrase = "Done! I completed that for you."
                    } else {
                        completionPhrase = await agentActorLoop.generateFailureExplanation(stateManager: agentStateManager)
                    }

                    voiceState = .responding
                    DebugEventLogger.shared.log(.tts(spokenText: completionPhrase))
                    try? await localTTSClient.speakText(completionPhrase)
                    voiceState = .idle
                    scheduleTransientHideIfNeeded()

                    // Save exchange
                    conversationHistory.append((
                        userTranscript: transcript,
                        assistantResponse: completionPhrase
                    ))
                    if conversationHistory.count > 10 {
                        conversationHistory.removeFirst(conversationHistory.count - 10)
                    }

                    // Exchange recorded in conversation history
                }
            } catch is CancellationError {
                isAgentTaskRunning = false
                agentTaskDockWindowManager.hideDock()
            } catch {
                print("Companion response error: \(error)")
                isAgentTaskRunning = false
                agentTaskDockWindowManager.hideDock()
                handleCompanionPipelineError(error, userTranscript: transcript)
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }



    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while localTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Handles unexpected errors in the companion pipeline and provides a clear,
    /// friendly spoken explanation of the actual issue rather than a misleading credit message.
    private func handleCompanionPipelineError(_ error: Error, userTranscript: String) {
        let errorDescription = error.localizedDescription
        DebugEventLogger.shared.log(.error(context: "CompanionPipeline", message: errorDescription))

        let spokenErrorMessage: String
        let lowercasedError = errorDescription.lowercased()
        if lowercasedError.contains("could not connect") || lowercasedError.contains("connection refused") || lowercasedError.contains("connection reset") {
            spokenErrorMessage = "I couldn't connect to the local model server on port 8000. Please check that omlx is running."
        } else if lowercasedError.contains("timed out") || lowercasedError.contains("timeout") {
            spokenErrorMessage = "The local model took too long to respond. Please try again."
        } else {
            spokenErrorMessage = "Sorry, I ran into an issue: \(errorDescription)"
        }

        voiceState = .responding
        Task {
            do {
                try await localTTSClient.speakText(spokenErrorMessage)
            } catch {
                let synthesizer = NSSpeechSynthesizer()
                synthesizer.startSpeaking(spokenErrorMessage)
            }
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        }

        conversationHistory.append((
            userTranscript: userTranscript,
            assistantResponse: spokenErrorMessage
        ))
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks the single qwen2.5vl:7b model to find
    /// something interesting to point at. Used during onboarding to demo the
    /// pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only use the cursor screen so the model picks something visible to the user
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                // Send screenshot directly to resident qwen3.5-9b on oMLX
                let base64Image = cursorScreenCapture.imageData.base64EncodedString()
                let messages: [OMLXChatMessage] = [
                    OMLXChatMessage(role: .system, text: Self.onboardingDemoSystemPrompt),
                    OMLXChatMessage(
                        role: .user,
                        text: "look around my screen and find something interesting to point at" + dimensionInfo,
                        base64ImageData: [base64Image]
                    )
                ]

                let modelResponse = try await omlxClient.sendChatCompletionRequest(
                    model: OMLXClient.actorModelAlias,
                    messages: messages,
                    temperature: 0.2,
                    maxTokens: 100,
                    enableThinking: false
                )

                let cleanedText = Self.stripThinkingTags(from: modelResponse.contentText)
                let parseResult = Self.parsePointingCoordinates(from: cleanedText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" -- \"\(parseResult.spokenText)\"")
            } catch {
                print("Onboarding demo error: \(error)")
            }
        }
    }
}
