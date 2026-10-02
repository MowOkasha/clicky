//
//  AgentTaskDockWindow.swift
//  leanring-buddy
//
//  Floating task progress dock located in the top-right corner of the screen,
//  right below the macOS menu bar clock. Displays live tool-by-tool execution
//  progress during multi-step agent tasks.
//  In compact state: shows a glowing blue active cursor badge.
//  On hover: expands smoothly into a detailed task progress card.
//

import AppKit
import SwiftUI

// MARK: - Custom Hosting View with Selective Hit-Testing

class AgentTaskDockHostingView: NSHostingView<AgentTaskDockView> {
    let companionManager: CompanionManager

    @MainActor required init(rootView: AgentTaskDockView) {
        self.companionManager = rootView.companionManager
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    convenience init(companionManager: CompanionManager) {
        self.init(rootView: AgentTaskDockView(companionManager: companionManager))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if companionManager.isAgentTaskDockExpanded {
            // When expanded, the full card area is interactive for hover and viewing
            return super.hitTest(point)
        } else {
            // When compact, only the top-right 56x56 badge area intercepts mouse events.
            // Clicks everywhere else pass through completely to underlying windows.
            let compactHitRect = NSRect(
                x: bounds.width - 56,
                y: bounds.height - 56,
                width: 56,
                height: 56
            )
            if compactHitRect.contains(point) {
                return super.hitTest(point)
            }
            return nil
        }
    }
}

// MARK: - Non-Activating Dock Window

final class AgentTaskDockWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - SwiftUI Dock View

struct AgentTaskDockView: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var isHovered: Bool = false
    @State private var spinnerRotation: Double = 0.0

    private let compactSize: CGFloat = 40
    private let expandedWidth: CGFloat = 300
    private let expandedHeight: CGFloat = 220

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear

            if isHovered || companionManager.isAgentTaskDockExpanded {
                expandedProgressCard
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity)
                    ))
            } else {
                compactDockBadge
                    .transition(.opacity)
            }
        }
        .frame(width: 320, height: 260)
        .onHover { hovering in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                self.isHovered = hovering
                self.companionManager.isAgentTaskDockExpanded = hovering
            }
        }
    }

    // MARK: - Compact Badge

    private var compactDockBadge: some View {
        ZStack {
            // Soft glowing pulse behind the badge
            Circle()
                .fill(DS.Colors.overlayCursorBlue.opacity(0.25))
                .frame(width: compactSize + 10, height: compactSize + 10)
                .blur(radius: 6)

            // Frosted dark glass circle
            Circle()
                .fill(Color(hex: "#121514").opacity(0.88))
                .overlay(
                    Circle()
                        .stroke(DS.Colors.overlayCursorBlue.opacity(0.6), lineWidth: 1.5)
                )
                .frame(width: compactSize, height: compactSize)
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 8, x: 0, y: 2)

            // Spinning progress arc
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(
                    AngularGradient(
                        colors: [
                            DS.Colors.overlayCursorBlue.opacity(0.1),
                            DS.Colors.overlayCursorBlue
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .frame(width: compactSize - 12, height: compactSize - 12)
                .rotationEffect(.degrees(spinnerRotation))

            // Blue triangle cursor icon in the center
            Triangle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 10, height: 10)
                .rotationEffect(.degrees(-35))
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.8), radius: 4)
        }
        .padding(.trailing, 10)
        .padding(.top, 8)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                spinnerRotation = 360
            }
        }
    }

    // MARK: - Expanded Progress Card

    private var expandedProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Card Header
            HStack(spacing: 8) {
                // Active status indicator
                ZStack {
                    Circle()
                        .fill(DS.Colors.overlayCursorBlue.opacity(0.3))
                        .frame(width: 18, height: 18)
                    Circle()
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(width: 8, height: 8)
                        .shadow(color: DS.Colors.overlayCursorBlue, radius: 4)
                }

                Text("Clicky is working")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                // Step count pill
                let steps = companionManager.agentTaskProgressSteps
                let completedCount = steps.filter { $0.isComplete }.count
                Text("\(completedCount)/\(max(steps.count, 1))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.accentText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(DS.Colors.blue500.opacity(0.15))
                            .overlay(
                                Capsule().stroke(DS.Colors.blue500.opacity(0.3), lineWidth: 0.5)
                            )
                    )
            }

            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.6))

            // Step List
            let steps = companionManager.agentTaskProgressSteps
            if steps.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 16, height: 16)
                    Text("Starting task...")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .padding(.vertical, 8)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(steps.suffix(5)) { step in
                            stepRow(step)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 120)
            }

            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.4))

            // Footer
            HStack {
                Text("Hover to view progress")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(DS.Colors.textTertiary)

                Spacer()

                Text("In progress")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.overlayCursorBlue)
            }
        }
        .padding(14)
        .frame(width: expandedWidth)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: "#121514").opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    DS.Colors.overlayCursorBlue.opacity(0.5),
                                    DS.Colors.borderSubtle.opacity(0.4)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.6), radius: 16, x: 0, y: 8)
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.15), radius: 20, x: 0, y: 0)
        )
        .padding(.trailing, 8)
        .padding(.top, 4)
    }

    private func stepRow(_ step: AgentTaskProgressStep) -> some View {
        HStack(spacing: 8) {
            if step.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.success)
                    .frame(width: 16, height: 16)
            } else {
                Circle()
                    .trim(from: 0.1, to: 0.9)
                    .stroke(DS.Colors.overlayCursorBlue, lineWidth: 1.8)
                    .frame(width: 11, height: 11)
                    .rotationEffect(.degrees(spinnerRotation))
                    .frame(width: 16, height: 16)
            }

            Text(step.summary)
                .font(.system(size: 11, weight: step.isComplete ? .regular : .medium))
                .foregroundColor(step.isComplete ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
    }
}

// MARK: - Window Manager

@MainActor
final class AgentTaskDockWindowManager {
    private var dockWindow: AgentTaskDockWindow?

    func showDock(onScreen screen: NSScreen, companionManager: CompanionManager) {
        hideDock()

        let panelWidth: CGFloat = 320
        let panelHeight: CGFloat = 260
        let screenFrame = screen.frame

        // Position window at the top right of the target display,
        // just beneath the menu bar clock.
        // AppKit coordinates: y is distance from bottom of screen.
        let xOrigin = screenFrame.maxX - panelWidth - 8
        let yOrigin = screenFrame.maxY - panelHeight - 34

        let frame = NSRect(
            x: xOrigin,
            y: yOrigin,
            width: panelWidth,
            height: panelHeight
        )

        let window = AgentTaskDockWindow(contentRect: frame)

        let hostingView = AgentTaskDockHostingView(companionManager: companionManager)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        window.contentView = hostingView

        self.dockWindow = window
        window.alphaValue = 0.0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 1.0
        }
    }

    func hideDock() {
        guard let window = dockWindow else { return }
        dockWindow = nil

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window.animator().alphaValue = 0.0
        }, completionHandler: {
            window.orderOut(nil)
            window.contentView = nil
        })
    }
}
