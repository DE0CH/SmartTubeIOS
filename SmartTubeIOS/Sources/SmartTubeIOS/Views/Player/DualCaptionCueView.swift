import SmartTubeIOSCore
import SwiftUI

// MARK: - DualCaptionCueView

/// A caption cue as two lines: the Japanese sentence (with furigana above the kanji when
/// `furigana` is on) and, under it, its translation. Cues without a translation, or from
/// non-Japanese tracks, look like `CaptionCueView`.
public struct DualCaptionCueView: View {
    public let cue: CaptionCue
    public let furigana: Bool

    private var fontSize: CGFloat {
        #if os(tvOS)
        40
        #else
        19
        #endif
    }

    private var screenHorizontalPadding: CGFloat {
        #if os(tvOS)
        80
        #else
        16
        #endif
    }

    public init(cue: CaptionCue, furigana: Bool) {
        self.cue = cue
        self.furigana = furigana
    }

    public var body: some View {
        VStack(spacing: fontSize * 0.25) {
            line {
                if furigana && Furigana.hasKanji(cue.text) {
                    RubyText(segments: Furigana.segments(cue.text), fontSize: fontSize)
                } else {
                    Text(cue.text)
                        .font(.system(size: fontSize, weight: .semibold))
                        .multilineTextAlignment(.center)
                }
            }
            .accessibilityIdentifier("player.captionCue")
            if let translation = cue.translation, !translation.isEmpty {
                line {
                    Text(translation)
                        .font(.system(size: fontSize * 0.78, weight: .medium))
                        .multilineTextAlignment(.center)
                }
                .accessibilityIdentifier("player.captionCue.translation")
            }
        }
        .padding(.horizontal, screenHorizontalPadding)
    }

    private func line<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundStyle(.white)
            .padding(.horizontal, fontSize * 0.5)
            .padding(.vertical, fontSize * 0.2)
            .background(Color.black.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
    }
}

// MARK: - RubyText

/// Japanese text with readings stacked above the kanji. Each run is a word; lines wrap
/// between words and are centred.
struct RubyText: View {
    let segments: [FuriganaSegment]
    let fontSize: CGFloat

    var body: some View {
        CenteredFlowLayout {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                VStack(spacing: 0) {
                    // Runs without a reading keep an empty one so every base sits on the same line.
                    Text(seg.reading ?? " ")
                        .font(.system(size: fontSize * 0.5, weight: .medium))
                        .foregroundStyle(Color(red: 1, green: 0.88, blue: 0.54))
                        .lineLimit(1)
                        .fixedSize()
                    Text(seg.text)
                        .font(.system(size: fontSize, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segments.map(\.text).joined())
    }
}

/// Lays subviews out left to right, wrapping to a new line when the width runs out, with
/// each line centred.
struct CenteredFlowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.midX - row.width / 2
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width
            }
            y += row.height
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !row.indices.isEmpty && row.width + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.indices.append(i)
            row.width += size.width
            row.height = max(row.height, size.height)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
