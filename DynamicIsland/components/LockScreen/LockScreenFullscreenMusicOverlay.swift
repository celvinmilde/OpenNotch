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

import SwiftUI
import Defaults

/// Full-screen expansion of the lock screen music player — reached by
/// tapping the album art on the compact panel. Fills the entire display
/// with large album art on the left and time-synced lyrics beside it.
/// Lyrics always show here regardless of the app-wide "Show lyrics"
/// setting — this view is the dedicated lyrics experience.
struct LockScreenFullscreenMusicOverlayView: View {
    @ObservedObject private var musicManager = MusicManager.shared
    @ObservedObject private var overlayManager = FullscreenMusicOverlayWindowManager.shared
    @Default(.lockScreenFullscreenArtworkMode) private var artworkMode

    @State private var sliderValue: Double = 0
    @State private var dragging = false
    @State private var lastDragged: Date = .distantPast
    @State private var artworkPulse = false

    let onDismiss: () -> Void

    private var isProgressTimelinePaused: Bool {
        !musicManager.isPlaying || musicManager.isLiveStream || musicManager.playbackRate <= 0
    }

    /// True once there's genuinely nothing to show — no synced lines and no
    /// plain-text lyrics (as opposed to still loading). In that case the
    /// lyrics column is hidden entirely and the album art takes its place.
    private var lyricsUnavailable: Bool {
        musicManager.syncedLyrics.isEmpty
            && (musicManager.currentLyrics.isEmpty || musicManager.currentLyrics == "No lyrics found")
    }

    var body: some View {
        ZStack {
            // Tapping anywhere that isn't one of the interactive controls
            // below (album art, title, empty space) dismisses the overlay —
            // buttons/slider/lyrics rows have their own gestures and consume
            // the tap before it reaches this layer. A downward swipe on the
            // same layer also dismisses.
            backgroundGradient
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    onDismiss()
                }
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            if value.translation.height > 80 {
                                onDismiss()
                            }
                        }
                )

            VStack(spacing: 0) {
                topBar

                HStack(alignment: .center, spacing: 64) {
                    albumArt(size: lyricsUnavailable ? 420 : 400)
                        .scaleEffect(artworkPulse ? 1.04 : 1)
                        .allowsHitTesting(false)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .onChange(of: musicManager.songTitle) { _, _ in
                            // A quick pulse right at the moment the track
                            // changes, on top of the background crossfade.
                            withAnimation(.easeOut(duration: 0.18)) {
                                artworkPulse = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                withAnimation(.easeIn(duration: 0.25)) {
                                    artworkPulse = false
                                }
                            }
                        }

                    // Lyrics keep their own tap-to-seek gesture — only the
                    // album art (no gesture of its own) lets taps fall
                    // through to the background dismiss layer.
                    if !lyricsUnavailable {
                        LyricsColumn(musicManager: musicManager, isPaused: isProgressTimelinePaused)
                            .frame(maxWidth: 480, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 64)

                VStack(spacing: 16) {
                    titleAndArtist
                        .allowsHitTesting(false)
                    progressBar
                    transportControls
                }
                .frame(maxWidth: 560)
                .padding(.bottom, 56)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(overlayManager.isShowing ? 1 : 0.94, anchor: .center)
        .opacity(overlayManager.isShowing ? 1 : 0)
        .animation(.easeOut(duration: 0.24), value: overlayManager.isShowing)
        .onAppear {
            sliderValue = musicManager.estimatedPlaybackPosition()
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()

            ArtworkModePicker(mode: $artworkMode)

            Button {
                overlayManager.strongBackgroundEnabled.toggle()
            } label: {
                Image(systemName: overlayManager.strongBackgroundEnabled ? "circle.righthalf.filled" : "circle.lefthalf.filled")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Hintergrund durchsichtiger machen")
        }
        .padding(.top, 28)
        .padding(.horizontal, 24)
    }

    private var backgroundGradient: some View {
        let base = Color(nsColor: musicManager.avgColor)
        let strong = overlayManager.strongBackgroundEnabled
        let topOpacity: Double = strong ? 0.94 : 0.55
        let midOpacity: Double = strong ? 0.99 : 0.92

        return ZStack {
            Rectangle().fill(.black)
                .opacity(strong ? 1 : 0)

            Rectangle().fill(.ultraThickMaterial)
                .opacity(strong ? 1 : 0)

            LinearGradient(
                colors: [
                    base.opacity(topOpacity),
                    Color.black.opacity(midOpacity),
                    Color.black
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        // Cross-fades both on track-color change and when switching
        // between the full-color and translucent background modes —
        // a slow, deliberate transition rather than a hard cut.
        .animation(.easeInOut(duration: 0.45), value: musicManager.avgColor)
        .animation(.easeInOut(duration: 0.7), value: strong)
    }

    @ViewBuilder
    private func albumArt(size: CGFloat) -> some View {
        Group {
            switch artworkMode {
            case .staticImage:
                Image(nsImage: musicManager.albumArt)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            case .liveCanvas:
                Group {
                    if let url = musicManager.videoArtworkURL {
                        DynamicIslandArtworkVideoView(url: url, videoGravity: .resizeAspectFill)
                    } else {
                        Image(nsImage: musicManager.albumArt)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            case .vinyl:
                VinylRecordView(musicManager: musicManager)
                    .frame(width: size, height: size)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 16)
        .animation(.easeInOut(duration: 0.3), value: size)
    }

    private var titleAndArtist: some View {
        VStack(spacing: 6) {
            Text(musicManager.songTitle.isEmpty ? "No Music Playing" : musicManager.songTitle)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(musicManager.artistName.isEmpty ? "Unknown Artist" : musicManager.artistName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)

                visualizer(height: 14)
            }
        }
    }

    @ViewBuilder
    private func visualizer(height: CGFloat) -> some View {
        let width = CGFloat(Defaults[.visualizerBarCount]) * 3
        if Defaults[.useMusicVisualizer], musicManager.isPlaying {
            Rectangle()
                .fill(Color.white.opacity(0.8))
                .mask {
                    AudioVisualizerView(isPlaying: .constant(musicManager.isPlaying))
                        .frame(width: width, height: height)
                }
                .frame(width: width, height: height)
        }
    }

    private var progressBar: some View {
        TimelineView(.animation(paused: isProgressTimelinePaused)) { timeline in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: Binding(
                    get: { musicManager.songDuration },
                    set: { musicManager.songDuration = $0 }
                ),
                lastDragged: $lastDragged,
                color: musicManager.avgColor,
                dragging: $dragging,
                currentDate: timeline.date,
                timestampDate: musicManager.timestampDate,
                elapsedTime: musicManager.elapsedTime,
                playbackRate: musicManager.playbackRate,
                isPlaying: musicManager.isPlaying,
                isLiveStream: musicManager.isLiveStream,
                onValueChange: { newValue in
                    musicManager.seek(to: newValue)
                },
                labelLayout: .inline,
                trailingLabel: .remaining,
                restingTrackHeight: 7,
                draggingTrackHeight: 11
            )
        }
    }

    private var transportControls: some View {
        HStack(spacing: 36) {
            HoverButton(icon: "backward.fill", iconColor: .white, scale: .medium) {
                musicManager.previousTrack()
            }

            HoverButton(
                icon: musicManager.isPlaying ? "pause.fill" : "play.fill",
                iconColor: .white,
                scale: .large
            ) {
                musicManager.togglePlay()
            }

            HoverButton(icon: "forward.fill", iconColor: .white, scale: .medium) {
                musicManager.nextTrack()
            }
        }
    }
}

/// Scrolling, time-synced lyrics with tap-to-seek — the current line is
/// highlighted and the list auto-scrolls to keep it centered. Driven by
/// `TimelineView` (via `isPaused`) so the highlighted line advances
/// continuously while playing instead of only on discrete track updates.
private struct LyricsColumn: View {
    @ObservedObject var musicManager: MusicManager
    let isPaused: Bool

    var body: some View {
        TimelineView(.animation(paused: isPaused)) { timeline in
            let currentTime = musicManager.estimatedPlaybackPosition(at: timeline.date)
            let currentLineID = currentLineID(at: currentTime)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        if musicManager.syncedLyrics.isEmpty {
                            Text(musicManager.currentLyrics)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white.opacity(0.6))
                        } else {
                            ForEach(musicManager.syncedLyrics) { line in
                                let isCurrent = line.id == currentLineID
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: isCurrent ? 22 : 18, weight: isCurrent ? .bold : .medium))
                                    .foregroundColor(.white.opacity(isCurrent ? 1 : 0.4))
                                    .id(line.id)
                                    .onTapGesture {
                                        musicManager.seek(to: line.timestamp)
                                    }
                            }
                        }
                    }
                    .padding(.vertical, 220)
                }
                .onChange(of: currentLineID) { _, newID in
                    guard let newID else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.12),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func currentLineID(at time: TimeInterval) -> UUID? {
        let lines = musicManager.syncedLyrics
        guard !lines.isEmpty else { return nil }
        var current = lines.first
        for line in lines where line.timestamp <= time {
            current = line
        }
        return current?.id
    }
}

/// Renders the album art as a spinning vinyl record — rotation is derived
/// directly from the playback position (via `TimelineView`, same mechanism
/// as the lyrics sync), so it naturally freezes when paused and never
/// drifts out of sync.
private struct VinylRecordView: View {
    @ObservedObject var musicManager: MusicManager

    private let rotationPeriod: Double = 6 // seconds per full turn — decorative, not real RPM

    var body: some View {
        TimelineView(.animation(paused: !musicManager.isPlaying)) { timeline in
            let elapsed = musicManager.estimatedPlaybackPosition(at: timeline.date)
            let angle = elapsed.truncatingRemainder(dividingBy: rotationPeriod) / rotationPeriod * 360

            ZStack {
                Circle().fill(Color.black)

                Image(nsImage: musicManager.albumArt)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(Circle())
                    .padding(30)

                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    .padding(30)

                Circle()
                    .fill(Color.black)
                    .frame(width: 34, height: 34)

                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 7, height: 7)
            }
            .rotationEffect(.degrees(angle))
        }
    }
}

/// Press-and-hold the artwork-mode button, then drag down through two steps
/// to pick between the three display modes (Festbild / Live Canvas / Vinyl).
/// Collapsed, it looks exactly like a normal circular icon button; holding
/// it reveals the other two options stacked below so you can drag onto one.
private struct ArtworkModePicker: View {
    @Binding var mode: ArtworkDisplayMode

    @State private var isExpanded = false
    @State private var pendingMode: ArtworkDisplayMode = .staticImage

    private let buttonSize: CGFloat = 44
    private let rowSpacing: CGFloat = 6
    private let stepDistance: CGFloat = 40 // drag distance (points) per step

    var body: some View {
        VStack(spacing: rowSpacing) {
            ForEach(ArtworkDisplayMode.allCases, id: \.rawValue) { option in
                if isExpanded || option == mode {
                    icon(for: option, highlighted: option == (isExpanded ? pendingMode : mode))
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: buttonSize / 2, style: .continuous)
                .fill(Color.white.opacity(0.12))
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isExpanded)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isExpanded {
                        isExpanded = true
                        pendingMode = mode
                    }
                    let steps = Int((max(0, value.translation.height) / stepDistance).rounded())
                    let clamped = min(ArtworkDisplayMode.allCases.count - 1, max(0, steps))
                    pendingMode = ArtworkDisplayMode(rawValue: clamped) ?? .staticImage
                }
                .onEnded { _ in
                    mode = pendingMode
                    isExpanded = false
                }
        )
        .help("Gedrückt halten und nach unten ziehen: Festbild / Live Canvas / Vinyl")
    }

    private func icon(for option: ArtworkDisplayMode, highlighted: Bool) -> some View {
        Image(systemName: option.iconName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white.opacity(highlighted ? 1 : 0.4))
            .frame(width: buttonSize - 12, height: buttonSize - 12)
            .scaleEffect(highlighted ? 1.1 : 0.9)
    }
}
