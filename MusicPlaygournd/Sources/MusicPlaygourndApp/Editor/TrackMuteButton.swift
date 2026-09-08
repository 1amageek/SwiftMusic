import SwiftUI

struct TrackMuteButton: View {
    let name: String
    let muted: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: muted == true ? "speaker.slash.fill" : "speaker.wave.2")
                .font(.system(size: 11))
                .foregroundStyle(muted == true ? Color.orange : Color.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(muted == nil)
        .help("\(muted == true ? "Unmute" : "Mute") \(name)")
        .accessibilityLabel("\(muted == true ? "Unmute" : "Mute") \(name)")
        .accessibilityValue(muted == true ? "Muted" : "Unmuted")
    }
}
