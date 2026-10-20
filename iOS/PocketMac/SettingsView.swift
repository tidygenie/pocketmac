import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = AppStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Picture") {
                    Picker("Quality", selection: $store.settings.quality) {
                        ForEach(StreamQuality.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Frame rate", selection: $store.settings.fps) {
                        Text("30 fps").tag(UInt8(30))
                        Text("60 fps").tag(UInt8(60))
                    }
                    Toggle("HEVC (sharper text, recommended)", isOn: $store.settings.useHEVC)
                    Toggle("Battery saver in Low Power Mode", isOn: $store.settings.autoSaverOnLowPower)
                    Picker("Screen when lid is closed", selection: $store.settings.lidFit) {
                        ForEach(LidDisplayFit.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                }

                Section {
                    Picker("Touch mode", selection: $store.settings.inputMode) {
                        ForEach(InputMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text("Trackpad speed")
                        Slider(value: $store.settings.trackpadSpeed, in: 0.4...2.5)
                    }
                    Toggle("Reverse scrolling", isOn: $store.settings.reverseScroll)
                    Toggle("Haptic feedback", isOn: $store.settings.haptics)
                } header: { Text("Control") } footer: {
                    Text("Trackpad: slide to move the pointer, tap to click, tap-then-slide to drag, two fingers to scroll or right-click (tap), pinch to zoom.\nTouch: tap where you want to click, long-press for right-click.\nBoth: three-finger swipe changes Spaces / Mission Control; three-finger tap shows the keyboard.")
                }

                Section("While connected") {
                    Toggle("Keep iPhone screen on", isOn: $store.settings.keepScreenOn)
                    Toggle("Copy Mac clipboard to iPhone automatically", isOn: $store.settings.clipboardSync)
                }

                Section("Security") {
                    LabeledContent("This iPhone's key", value: String(DeviceID.pretty(DeviceID.from(publicKey: store.identity.publicKey.rawRepresentation)).prefix(9)) + "…")
                    Text("Every session is end-to-end encrypted (X25519 + AES-256-GCM) directly between this iPhone and your Mac — no server in between. The Mac only accepts the iPhone it paired with, and the saved login is locked behind Face ID.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Connecting from anywhere") {
                    Text("Same Wi-Fi, or nearby with no Wi-Fi: found automatically.\n\nDifferent networks (mobile data, other Wi-Fi): install Tailscale on the Mac and this iPhone, sign in with the same account, and put the Mac's Tailscale name or 100.x address in the Mac's “Internet address”. Tailscale only helps the two devices find each other; the picture and your input still go straight between them, encrypted twice.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
