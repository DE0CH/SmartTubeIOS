import SmartTubeIOSCore
import SwiftUI

// MARK: - Dual subtitle rows (caption picker)

extension PlayerView {

    /// The caption picker's dual-subtitle controls: the translation line's language and
    /// furigana. Shown when dual subtitles are on and the video has a Japanese track.
    @ViewBuilder var dualSubtitleRows: some View {
        if store.settings.dualSubtitlesEnabled,
            vm.availableCaptions.contains(where: DualSubtitleOptions.applies(to:))
        {
            Text("Japanese subtitles")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 6)
            ForEach(DualSubtitleOptions.translationChoices, id: \.code) { choice in
                dualRow(
                    title: "Translation: \(choice.label)",
                    checked: store.settings.dualTranslationLanguage == choice.code,
                    id: "player.captionPicker.translation.\(choice.code.isEmpty ? "off" : choice.code)"
                ) {
                    store.settings.dualTranslationLanguage = choice.code
                    applyDualSettingChange()
                }
            }
            dualRow(title: "Furigana", checked: store.settings.furiganaEnabled, id: "player.captionPicker.furigana") {
                store.settings.furiganaEnabled.toggle()
            }
        }
    }

    private func dualRow(title: String, checked: Bool, id: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack {
                    Text(title).foregroundStyle(.primary)
                    Spacer()
                    if checked {
                        Image(systemName: AppSymbol.checkmark)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
            Divider()
        }
    }

    /// Pushes the new settings into the player and reloads the Japanese track with them.
    private func applyDualSettingChange() {
        vm.updateSettings(store.settings)
        vm.reloadSelectedCaption()
    }
}
