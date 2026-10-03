//
//  PerceptionManager.swift
//  leanring-buddy
//
//  Perception layer that inspects the active macOS application's UI hierarchy
//  using the Accessibility API (AXUIElement) first, and falls back to capturing
//  a screenshot only when the accessibility tree is insufficient (e.g., non-accessible
//  canvas/Electron apps, games, or missing accessibility permissions).
//

import AppKit
import ApplicationServices
import Foundation

/// Represents a single interactable UI element discovered via the Accessibility API.
struct PerceivedUIElement: Identifiable {
    /// Generated unique identifier used in prompts (e.g. "elem_1", "elem_2").
    let id: String
    /// The accessibility role (e.g., "AXButton", "AXTextField", "AXPopUpButton").
    let role: String
    /// The accessibility subrole if available.
    let subrole: String?
    /// User-visible title or label.
    let label: String
    /// Current value of the element if applicable (e.g., text content of a text field).
    let value: String?
    /// Screen-coordinate bounding rectangle of the element.
    let frame: CGRect
    /// Native accessibility identifier if provided by the application.
    let nativeIdentifier: String?
    /// Whether the element is currently enabled for interaction.
    let isEnabled: Bool

    /// Formats the element as a concise single-line description for the actor prompt.
    var promptDescription: String {
        let cleanRole = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        var desc = "[\(id)] \(cleanRole)"
        if !label.isEmpty {
            desc += " \"\(label)\""
        }
        if let value = value, !value.isEmpty, value != label {
            let truncatedValue = value.count > 30 ? "\(value.prefix(27))..." : value
            desc += " value=\"\(truncatedValue)\""
        }
        return desc
    }
}

/// The result produced by the perception layer for a single state capture.
struct PerceptionResult {
    /// Name of the active frontmost application.
    let frontmostApplicationName: String
    /// Bundle identifier of the frontmost application.
    let frontmostApplicationBundleIdentifier: String
    /// Title of the active window.
    let activeWindowTitle: String
    /// List of interactive elements discovered in the AX tree.
    let elements: [PerceivedUIElement]
    /// Mapping from element id (e.g. "elem_1") to the live AXUIElement reference for direct actions.
    let elementLiveReferenceMap: [String: AXUIElement]
    /// Formatted string summary of visible UI elements for the model prompt.
    let formattedElementListText: String
    /// Whether the accessibility tree was deemed insufficient, triggering a screenshot fallback.
    let isScreenshotFallbackUsed: Bool
    /// Screenshots captured if fallback was triggered (empty if AX tree was sufficient).
    let fallbackScreenshots: [(data: Data, label: String)]

    /// Compact summary for fast triage evaluation (avoids element dumping on chit-chat or tool routing)
    var triageSummaryText: String {
        var summary = "Frontmost App: \(frontmostApplicationName)"
        if !activeWindowTitle.isEmpty && activeWindowTitle != "Untitled Window" {
            summary += " | Window: \"\(activeWindowTitle)\""
        }
        return summary
    }
}

/// Manages UI perception using AXUIElement with fallback to multi-monitor screenshots.
@MainActor
class PerceptionManager {

    /// Maximum number of interactive elements to retain per window to avoid token bloat.
    private let maximumElementsPerWindow: Int = 45

    /// Maximum recursion depth when traversing the accessibility tree.
    private let maximumTreeTraversalDepth: Int = 12

    /// Minimum interactive element count required to consider the AX tree sufficient.
    private let minimumElementSufficiencyThreshold: Int = 3

    // MARK: - Primary Perception Capture

    /// Captures the current screen state: attempts AXUIElement tree traversal first,
    /// and falls back to ScreenCaptureKit screenshots only if permitted and necessary.
    func captureCurrentScreenState(allowScreenshotFallback: Bool = true) async -> PerceptionResult {
        // Check accessibility permissions
        let isAccessibilityPermissionGranted = AXIsProcessTrusted()

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            print("⚠️ PerceptionManager: No frontmost application found.")
            let screenshots = allowScreenshotFallback ? await captureFallbackScreenshots() : []
            return PerceptionResult(
                frontmostApplicationName: "Unknown",
                frontmostApplicationBundleIdentifier: "",
                activeWindowTitle: "Unknown",
                elements: [],
                elementLiveReferenceMap: [:],
                formattedElementListText: allowScreenshotFallback
                    ? "No active application found. Screenshot attached."
                    : "No active application found.",
                isScreenshotFallbackUsed: allowScreenshotFallback,
                fallbackScreenshots: screenshots
            )
        }

        let applicationName = frontmostApp.localizedName ?? "Application"
        let applicationBundleID = frontmostApp.bundleIdentifier ?? ""
        let processIdentifier = frontmostApp.processIdentifier

        // If accessibility permission is not granted, fallback to screenshot only if allowed
        guard isAccessibilityPermissionGranted else {
            print("⚠️ PerceptionManager: Accessibility permission not granted.")
            let screenshots = allowScreenshotFallback ? await captureFallbackScreenshots() : []
            return PerceptionResult(
                frontmostApplicationName: applicationName,
                frontmostApplicationBundleIdentifier: applicationBundleID,
                activeWindowTitle: "Unknown",
                elements: [],
                elementLiveReferenceMap: [:],
                formattedElementListText: allowScreenshotFallback
                    ? "Accessibility permissions unavailable. Multi-monitor screenshot attached."
                    : "Accessibility permissions unavailable.",
                isScreenshotFallbackUsed: allowScreenshotFallback,
                fallbackScreenshots: screenshots
            )
        }

        // Create AXUIElement application reference
        let axApplicationElement = AXUIElementCreateApplication(processIdentifier)

        // Find active window and title
        let (activeWindowElement, activeWindowTitle) = resolveActiveWindow(for: axApplicationElement)

        // Traverse the element tree starting from the active window (or whole app if window not found)
        let rootElementToTraverse = activeWindowElement ?? axApplicationElement
        var discoveredElements: [PerceivedUIElement] = []
        var liveReferenceMap: [String: AXUIElement] = [:]

        traverseAccessibilityElementHierarchy(
            element: rootElementToTraverse,
            currentDepth: 0,
            discoveredElements: &discoveredElements,
            liveReferenceMap: &liveReferenceMap
        )

        print("🔍 PerceptionManager: Found \(discoveredElements.count) element(s) in '\(applicationName)' (Window: '\(activeWindowTitle)')")

        // Evaluate whether the AX tree is sufficient
        let isTreeInsufficient = discoveredElements.count < minimumElementSufficiencyThreshold

        let isTerminalLogViewer = (applicationName.lowercased().contains("terminal") || applicationName.lowercased().contains("iterm")) &&
            (activeWindowTitle.lowercased().contains("debug.log") || activeWindowTitle.lowercased().contains("tail -f") || activeWindowTitle.lowercased().contains("clicky"))
        let terminalNote = isTerminalLogViewer
            ? "\n[Note: The active window is Clicky's terminal debug log. Shell commands (run_terminal_command) and open_app execute independently in the background; you do NOT need to switch windows or focus an app to run commands.]\n"
            : ""

        if isTreeInsufficient && allowScreenshotFallback {
            print("📸 PerceptionManager: AX tree is insufficient (\(discoveredElements.count) elements). Falling back to screenshot.")
            let screenshots = await captureFallbackScreenshots()
            await DebugEventLogger.shared.log(.perception(
                app: applicationName,
                windowTitle: activeWindowTitle,
                elementCount: discoveredElements.count,
                usedScreenshotFallback: true
            ))

            let summaryText = discoveredElements.isEmpty
                ? "Active application: \(applicationName). Window: \"\(activeWindowTitle)\". Accessibility tree yielded no interactable elements (screenshot attached).\(terminalNote)"
                : "Active application: \(applicationName). Window: \"\(activeWindowTitle)\". Discovered \(discoveredElements.count) elements, but tree appears incomplete (screenshot attached):\(terminalNote)\n" +
                  discoveredElements.map { $0.promptDescription }.joined(separator: "\n")

            return PerceptionResult(
                frontmostApplicationName: applicationName,
                frontmostApplicationBundleIdentifier: applicationBundleID,
                activeWindowTitle: activeWindowTitle,
                elements: discoveredElements,
                elementLiveReferenceMap: liveReferenceMap,
                formattedElementListText: summaryText,
                isScreenshotFallbackUsed: true,
                fallbackScreenshots: screenshots
            )
        } else {
            // Tree is sufficient or screenshot fallback is disabled — no screenshot needed!
            let formattedList = discoveredElements.map { $0.promptDescription }.joined(separator: "\n")
            let summaryText = discoveredElements.isEmpty
                ? "Active application: \(applicationName)\nWindow: \"\(activeWindowTitle)\"\(terminalNote)\nNo interactive UI elements discovered in accessibility tree."
                : "Active application: \(applicationName)\nWindow: \"\(activeWindowTitle)\"\(terminalNote)\nVisible interactive elements (\(discoveredElements.count)):\n\(formattedList)"

            DebugEventLogger.shared.log(.perception(
                app: applicationName,
                windowTitle: activeWindowTitle,
                elementCount: discoveredElements.count,
                usedScreenshotFallback: false
            ))

            return PerceptionResult(
                frontmostApplicationName: applicationName,
                frontmostApplicationBundleIdentifier: applicationBundleID,
                activeWindowTitle: activeWindowTitle,
                elements: discoveredElements,
                elementLiveReferenceMap: liveReferenceMap,
                formattedElementListText: summaryText,
                isScreenshotFallbackUsed: false,
                fallbackScreenshots: []
            )
        }
    }

    // MARK: - Active Window Resolution

    private func resolveActiveWindow(for axApplicationElement: AXUIElement) -> (AXUIElement?, String) {
        var windowElementValue: AnyObject?
        let copyWindowResult = AXUIElementCopyAttributeValue(
            axApplicationElement,
            kAXFocusedWindowAttribute as CFString,
            &windowElementValue
        )

        if copyWindowResult == .success, let windowElement = windowElementValue {
            let axWindow = windowElement as! AXUIElement
            let title = copyStringAttribute(axElement: axWindow, attributeName: kAXTitleAttribute) ?? "Untitled Window"
            return (axWindow, title)
        }

        // Fallback: copy first window from kAXWindowsAttribute
        var windowsListValue: AnyObject?
        let copyWindowsResult = AXUIElementCopyAttributeValue(
            axApplicationElement,
            kAXWindowsAttribute as CFString,
            &windowsListValue
        )

        if copyWindowsResult == .success, let windowsArray = windowsListValue as? [AXUIElement], let firstWindow = windowsArray.first {
            let title = copyStringAttribute(axElement: firstWindow, attributeName: kAXTitleAttribute) ?? "Main Window"
            return (firstWindow, title)
        }

        return (nil, "Main Window")
    }

    // MARK: - Tree Traversal

    private func traverseAccessibilityElementHierarchy(
        element: AXUIElement,
        currentDepth: Int,
        discoveredElements: inout [PerceivedUIElement],
        liveReferenceMap: inout [String: AXUIElement]
    ) {
        guard currentDepth <= maximumTreeTraversalDepth else { return }
        guard discoveredElements.count < maximumElementsPerWindow else { return }

        // Read role
        guard let role = copyStringAttribute(axElement: element, attributeName: kAXRoleAttribute) else {
            return
        }

        // Ignore invisible or container-only roles that have no user interaction
        let ignoredRoles: Set<String> = [
            "AXScrollArea", "AXSplitGroup", "AXGroup", "AXLayoutArea", "AXUnknown"
        ]

        // Check if this element is interactive or informational
        let isInterestingRole = !ignoredRoles.contains(role)

        if isInterestingRole {
            let label = copyStringAttribute(axElement: element, attributeName: kAXTitleAttribute)
                ?? copyStringAttribute(axElement: element, attributeName: kAXDescriptionAttribute)
                ?? ""
            let value = copyStringAttribute(axElement: element, attributeName: kAXValueAttribute)
            let nativeIdentifier = copyStringAttribute(axElement: element, attributeName: kAXIdentifierAttribute)
            let subrole = copyStringAttribute(axElement: element, attributeName: kAXSubroleAttribute)
            let frame = copyElementFrame(axElement: element)

            // Only retain elements with a non-empty frame and some identifying label or interactive role
            let hasValidSize = frame.width > 2 && frame.height > 2
            let isActionable = role.contains("Button") || role.contains("Field") || role.contains("Menu") ||
                               role.contains("Box") || role.contains("Row") || role.contains("Cell") ||
                               role.contains("Tab") || role.contains("Link") || role.contains("Slider")

            if hasValidSize && (!label.isEmpty || isActionable || value != nil) {
                let elementID = "elem_\(discoveredElements.count + 1)"
                let perceivedElement = PerceivedUIElement(
                    id: elementID,
                    role: role,
                    subrole: subrole,
                    label: label,
                    value: value,
                    frame: frame,
                    nativeIdentifier: nativeIdentifier,
                    isEnabled: copyBooleanAttribute(axElement: element, attributeName: kAXEnabledAttribute) ?? true
                )

                discoveredElements.append(perceivedElement)
                liveReferenceMap[elementID] = element
            }
        }

        // Recursively inspect children
        var childrenValue: AnyObject?
        let copyChildrenResult = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        )

        if copyChildrenResult == .success, let childrenArray = childrenValue as? [AXUIElement] {
            for childElement in childrenArray {
                if discoveredElements.count >= maximumElementsPerWindow { break }
                traverseAccessibilityElementHierarchy(
                    element: childElement,
                    currentDepth: currentDepth + 1,
                    discoveredElements: &discoveredElements,
                    liveReferenceMap: &liveReferenceMap
                )
            }
        }
    }

    // MARK: - Attribute Helpers

    private func copyStringAttribute(axElement: AXUIElement, attributeName: String) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(axElement, attributeName as CFString, &value)
        guard result == .success, let stringValue = value as? String else {
            return nil
        }
        return stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copyBooleanAttribute(axElement: AXUIElement, attributeName: String) -> Bool? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(axElement, attributeName as CFString, &value)
        guard result == .success, let boolValue = value as? Bool else {
            return nil
        }
        return boolValue
    }

    private func copyElementFrame(axElement: AXUIElement) -> CGRect {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?

        var position = CGPoint.zero
        var size = CGSize.zero

        let positionResult = AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &positionValue)
        if positionResult == .success, let axVal = positionValue as! AXValue? {
            AXValueGetValue(axVal, .cgPoint, &position)
        }

        let sizeResult = AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &sizeValue)
        if sizeResult == .success, let axVal = sizeValue as! AXValue? {
            AXValueGetValue(axVal, .cgSize, &size)
        }

        return CGRect(origin: position, size: size)
    }

    // MARK: - Screenshot Fallback

    private func captureFallbackScreenshots() async -> [(data: Data, label: String)] {
        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            return screenCaptures.map { (data: $0.imageData, label: $0.label) }
        } catch {
            print("⚠️ PerceptionManager: Failed to capture fallback screenshots: \(error)")
            return []
        }
    }
}
