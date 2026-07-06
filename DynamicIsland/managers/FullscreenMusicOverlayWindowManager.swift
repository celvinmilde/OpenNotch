/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import SwiftUI
import SkyLightWindow
import IOKit.pwr_mgt
import Defaults

/// A single fixed full-screen window that shows the "expand the lock screen
/// music player to fill the entire display" view — big album art, live
/// synced lyrics with tap-to-seek, and a dynamic gradient background pulled
/// from the current track's average color.
///
/// Deliberately a single window whose frame never changes (matches
/// `screen.frame` once, at creation) — only the SwiftUI content inside
/// switches between hidden/visible. Resizing an `NSWindow` to animate
/// between a compact card and a full-screen state is janky and was already
/// ruled out during development; a fixed full-screen window with
/// content-level transitions is smooth and simple.
@MainActor
final class FullscreenMusicOverlayWindowManager: ObservableObject {
    static let shared = FullscreenMusicOverlayWindowManager()

    @Published private(set) var isShowing = false
    /// Whether the more opaque/blurred background mode is on. The fully
    /// colored/opaque look is the default every time the overlay opens —
    /// toggling it off for a session (more translucent) is intentionally
    /// NOT persisted, so the next open always starts back at full color.
    @Published var strongBackgroundEnabled = true
    var onDismiss: (() -> Void)?

    private var window: NSWindow?
    private var hasDelegated = false
    private var hideTask: Task<Void, Never>?
    /// Keeps the display from sleeping while the overlay is up — macOS
    /// applies a much shorter, separate display-blank timer while the
    /// screen is locked (independent of the System Settings display-sleep
    /// duration), so without this the screen goes dark after ~10s.
    private var displayWakeAssertionID: IOPMAssertionID = 0
    private var isHoldingDisplayAwake = false

    private init() {}

    /// Lets the standalone keyboard shortcut open/close the overlay from
    /// anywhere — not just from tapping the lock screen panel.
    func toggle() {
        if isShowing {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard MusicManager.shared.hasActiveSession else { return }
        hideTask?.cancel()
        hideTask = nil
        guard let screen = currentScreen() else { return }

        if window == nil {
            let newWindow = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            newWindow.isReleasedWhenClosed = false
            newWindow.isOpaque = false
            newWindow.backgroundColor = .clear
            newWindow.hasShadow = false
            newWindow.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            newWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            newWindow.isMovable = false
            newWindow.ignoresMouseEvents = false

            ScreenCaptureVisibilityManager.shared.register(newWindow, scope: .entireInterface)

            let hosting = NSHostingView(
                rootView: LockScreenFullscreenMusicOverlayView(onDismiss: { [weak self] in
                    self?.hide()
                })
            )
            hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            newWindow.contentView = hosting

            window = newWindow
        }

        guard let window else { return }
        window.setFrame(screen.frame, display: true)

        if !hasDelegated {
            SkyLightOperator.shared.delegateWindow(window)
            hasDelegated = true
        }

        isShowing = true
        window.orderFrontRegardless()
        beginHoldingDisplayAwake()
    }

    func hide() {
        guard isShowing else { return }
        // Flip isShowing first so the SwiftUI content fades/scales out
        // reactively, then delay the actual window order-out until that
        // animation has had time to finish.
        isShowing = false
        strongBackgroundEnabled = true
        endHoldingDisplayAwake()

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard let self, !self.isShowing else { return }
            await MainActor.run {
                self.window?.orderOut(nil)
            }
        }

        let callback = onDismiss
        onDismiss = nil
        callback?()
    }

    private func beginHoldingDisplayAwake() {
        guard !isHoldingDisplayAwake else { return }
        let reason = "Atoll fullscreen music overlay is visible" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displayWakeAssertionID
        )
        isHoldingDisplayAwake = result == kIOReturnSuccess
    }

    private func endHoldingDisplayAwake() {
        guard isHoldingDisplayAwake else { return }
        IOPMAssertionRelease(displayWakeAssertionID)
        isHoldingDisplayAwake = false
    }

    private func currentScreen() -> NSScreen? {
        LockScreenDisplayContextProvider.shared.contextSnapshot()?.screen ?? NSScreen.main
    }
}

/// The three ways the fullscreen overlay can show the album art. Ordered
/// top-to-bottom to match the press-and-hold picker on the artwork-mode
/// button (drag down through the steps to pick).
enum ArtworkDisplayMode: Int, CaseIterable, Defaults.Serializable {
    case staticImage
    case liveCanvas
    case vinyl

    var iconName: String {
        switch self {
        case .staticImage: return "photo.fill"
        case .liveCanvas: return "livephoto"
        case .vinyl: return "record.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .staticImage: return "Festbild"
        case .liveCanvas: return "Live Canvas"
        case .vinyl: return "Vinyl"
        }
    }
}
