#if canImport(UIKit)
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

/// Renders the dual caption view (furigana + translation) to PNG. When the test runner gets
/// `DUAL_SNAPSHOT_DIR` (CI passes `TEST_RUNNER_DUAL_SNAPSHOT_DIR`), the images are written
/// there so the layout can be looked at; the assertions only check that something rendered.
@Suite("DualCaptionCueView snapshot")
struct DualCaptionCueViewSnapshotTests {

    static let cue = CaptionCue(
        startTime: 0, endTime: 4, text: "上高地に向かうシャトルバス乗り場は朝からこの混雑ぶり。",
        translation: "The shuttle bus stop for Kamikochi was this crowded from the morning.")

    @MainActor
    func render(_ view: some View, width: CGFloat, name: String) throws -> UIImage {
        let renderer = ImageRenderer(
            content: view.frame(width: width).padding(.vertical, 20).background(Color(white: 0.25)))
        renderer.scale = 2
        let image = try #require(renderer.uiImage)
        if let dir = ProcessInfo.processInfo.environment["DUAL_SNAPSHOT_DIR"], let png = image.pngData() {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return image
    }

    @Test("furigana + translation renders on a phone-width player")
    @MainActor func phone() throws {
        let image = try render(DualCaptionCueView(cue: Self.cue, furigana: true), width: 390, name: "dual-phone")
        #expect(image.size.width == 390)
        #expect(image.size.height > 80)  // two lines, the Japanese one with readings above
    }

    @Test("without furigana or translation it is a single caption line")
    @MainActor func plain() throws {
        let cue = CaptionCue(startTime: 0, endTime: 4, text: Self.cue.text)
        let image = try render(DualCaptionCueView(cue: cue, furigana: false), width: 390, name: "plain-phone")
        #expect(image.size.height > 20)
    }
}
#endif
