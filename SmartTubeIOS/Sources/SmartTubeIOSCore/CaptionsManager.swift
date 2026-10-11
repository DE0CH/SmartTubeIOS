import Foundation

// MARK: - CaptionsManager

/// Owns caption state: `availableCaptions`, `selectedCaption`, `currentCaptionCue`,
/// `captionCues`, and `captionFetchTask`. Fully self-contained — no delegate needed.
@MainActor
@Observable
public final class CaptionsManager {

    // MARK: - State

    public var availableCaptions: [CaptionTrack] = []
    public var selectedCaption: CaptionTrack? = nil
    public var currentCaptionCue: CaptionCue? = nil

    // Not observed (task handle, not UI state)
    @ObservationIgnored public var captionCues: [CaptionCue] = []
    @ObservationIgnored public var captionFetchTask: Task<Void, Never>? = nil

    // MARK: - Init

    public init() {}

    // MARK: - Interface

    public func reset() {
        availableCaptions = []
        selectedCaption = nil
        currentCaptionCue = nil
        captionCues = []
        captionFetchTask?.cancel()
        captionFetchTask = nil
    }

    public func cancel() {
        captionFetchTask?.cancel()
        captionFetchTask = nil
    }

    /// Selects a caption track and fetches its VTT cues. Pass `nil` to disable captions.
    /// `currentTime` is captured at call-time to update the cue immediately after fetch.
    /// With `dual` set and a Japanese track, cues are whole sentences and carry a
    /// translation once it arrives (see `DualSubtitles.swift`).
    public func selectCaption(_ track: CaptionTrack?, currentTime: TimeInterval = 0, dual: DualSubtitleOptions? = nil) {
        selectedCaption = track
        currentCaptionCue = nil
        captionCues = []
        captionFetchTask?.cancel()
        captionFetchTask = nil
        guard let track else { return }
        let timeToApply = currentTime
        if let dual, DualSubtitleOptions.applies(to: track) {
            captionFetchTask = Task { [weak self] in await self?.loadDual(track, dual, timeToApply) }
            return
        }
        captionFetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let parser = WebVTTParser()
                let cues = try await parser.fetchCues(from: track.baseURL)
                guard !Task.isCancelled else { return }
                self.captionCues = cues
                self.updateCaptionCue(for: timeToApply)
            } catch {
                // Caption fetch failed — leave cues empty
            }
        }
    }

    /// The time last passed to `updateCaptionCue`, so a translation that lands later can
    /// refresh the cue on screen.
    @ObservationIgnored private var lastCueTime: TimeInterval = 0

    private func loadDual(_ track: CaptionTrack, _ dual: DualSubtitleOptions, _ time: TimeInterval) async {
        lastCueTime = time
        guard let (data, _) = try? await URLSession.shared.data(from: Json3Captions.url(for: track)),
            !Task.isCancelled
        else { return }
        let sentences = CaptionSentences.group(Json3Captions.parse(data))
        captionCues = sentences
        updateCaptionCue(for: lastCueTime)
        guard let target = dual.translationLanguage, !sentences.isEmpty else { return }
        // Translation failures leave the Japanese line alone.
        guard let lines = try? await GoogleTranslator.shared.translate(sentences.map(\.text), to: target),
            !Task.isCancelled, lines.count == sentences.count, selectedCaption?.id == track.id
        else { return }
        captionCues = zip(sentences, lines).map { cue, line in
            CaptionCue(startTime: cue.startTime, endTime: cue.endTime, text: cue.text, translation: line)
        }
        updateCaptionCue(for: lastCueTime)
    }

    /// Updates `currentCaptionCue` for the given playback position.
    public func updateCaptionCue(for time: TimeInterval) {
        lastCueTime = time
        guard !captionCues.isEmpty else {
            currentCaptionCue = nil
            return
        }
        currentCaptionCue = captionCues.last(where: { $0.startTime <= time && $0.endTime > time })
    }
}
