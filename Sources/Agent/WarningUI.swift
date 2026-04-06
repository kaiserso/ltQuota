import AppKit
import Foundation
import Shared

/// Manages all user-facing warning windows for the agent.
/// All methods must be called on the main thread.
@MainActor
final class WarningUI: NSObject {

    // MARK: - Early warning banner

    private var bannerWindow: NSPanel?

    /// Show a non-blocking HUD banner that auto-dismisses after 5 seconds.
    func showEarlyWarning(remainingSeconds: Int) {
        bannerWindow?.close()
        bannerWindow = nil

        let minutes = max(1, (remainingSeconds + 59) / 60)
        let message = "\(minutes) minute\(minutes == 1 ? "" : "s") of computer time remaining today."

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.82)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 12

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBezeled = false
        label.frame = NSRect(x: 14, y: 12, width: 312, height: 32)
        panel.contentView?.addSubview(label)

        // Position in top-right corner of the primary screen.
        if let screen = NSScreen.main {
            let sx = screen.visibleFrame.maxX - 360
            let sy = screen.visibleFrame.maxY - 76
            panel.setFrameOrigin(NSPoint(x: sx, y: sy))
        }

        panel.orderFrontRegardless()
        bannerWindow = panel

        // Auto-dismiss after 5 seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.bannerWindow?.close()
            self?.bannerWindow = nil
        }
    }

    // MARK: - Final warning modal

    private var finalWindow: NSWindow?
    private var countdownTimer: Timer?
    private var onGraceExpired: (() -> Void)?

    /// Show a full-screen blocking modal with countdown.
    /// `onExpiry` is called when the grace countdown reaches zero.
    func showFinalWarning(gracePeriodSeconds: Int, onExpiry: @escaping () -> Void) {
        // Don't show twice.
        guard finalWindow == nil else { return }
        onGraceExpired = onExpiry

        let win = NSWindow(
            contentRect: NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.backgroundColor = NSColor.black.withAlphaComponent(0.88)
        win.isOpaque = false
        win.level = .screenSaver              // Stays above everything
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.ignoresMouseEvents = false
        win.isReleasedWhenClosed = false

        let content = win.contentView!

        // Main message label.
        let titleLabel = NSTextField(wrappingLabelWithString: "Your computer time for today is finished.")
        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.backgroundColor = .clear
        titleLabel.isBezeled = false
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(titleLabel)

        // Countdown label — updated by timer.
        let countdownLabel = NSTextField(labelWithString: countdownText(gracePeriodSeconds))
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .regular)
        countdownLabel.textColor = NSColor.systemOrange
        countdownLabel.backgroundColor = .clear
        countdownLabel.isBezeled = false
        countdownLabel.alignment = .center
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(countdownLabel)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -28),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 700),

            countdownLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            countdownLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
        ])

        win.orderFrontRegardless()
        finalWindow = win

        // Countdown timer.
        var remaining = gracePeriodSeconds
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                remaining -= 1
                countdownLabel.stringValue = self.countdownText(remaining)
                if remaining <= 0 {
                    self.countdownTimer?.invalidate()
                    self.countdownTimer = nil
                    self.onGraceExpired?()
                    self.onGraceExpired = nil
                }
            }
        }
    }

    private func countdownText(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 60 {
            return "You will be logged out in \(s / 60)m \(s % 60)s."
        }
        return "You will be logged out in \(s) second\(s == 1 ? "" : "s")."
    }

    // MARK: - Exhausted-at-login modal

    /// Show the same final warning immediately (for when the child logs in with no time left).
    /// Uses a short grace period if grace was already previously started (≤ 10 seconds).
    func showExhaustedAtLogin(gracePeriodSeconds: Int, onExpiry: @escaping () -> Void) {
        showFinalWarning(gracePeriodSeconds: gracePeriodSeconds, onExpiry: onExpiry)
    }
}
