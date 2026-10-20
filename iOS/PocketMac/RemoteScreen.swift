import SwiftUI
import UIKit

struct RemoteViewRepresentable: UIViewControllerRepresentable {
    let session: RemoteSession
    func makeUIViewController(context: Context) -> RemoteViewController { RemoteViewController(session: session) }
    func updateUIViewController(_ vc: RemoteViewController, context: Context) {}
}

struct RemoteScreen: View {
    @ObservedObject var session: RemoteSession
    @ObservedObject private var store = AppStore.shared
    @ObservedObject private var nav = NavModel.shared

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            RemoteViewRepresentable(session: session)
                .ignoresSafeArea()

            if session.phase != .connected {
                PhaseOverlay(session: session)
            }

            if session.phase == .connected {
                Toolbar(session: session)
                    .padding(.top, 6)
            }

            if let t = session.toast {
                Text(t)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 64)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.toast)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .preferredColorScheme(.dark)
    }
}

private struct PhaseOverlay: View {
    @ObservedObject var session: RemoteSession
    @ObservedObject private var nav = NavModel.shared

    var body: some View {
        VStack(spacing: 16) {
            switch session.phase {
            case .connecting(let text):
                ProgressView().controlSize(.large).tint(.white)
                Text(text).foregroundStyle(.white.opacity(0.9))
                Button("Cancel") { nav.closeSession() }.buttonStyle(.bordered)

            case .needsPassword(let message):
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.tint)
                Text(session.mac.name).font(.title3.bold())
                if let message { Text(message).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center) }
                SecureField("Mac host password", text: $session.passwordInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .submitLabel(.go)
                    .onSubmit { session.submitPassword() }
                Toggle("Remember with Face ID", isOn: $session.rememberPassword).frame(maxWidth: 320)
                HStack {
                    Button("Cancel") { nav.closeSession() }.buttonStyle(.bordered)
                    Button("Connect") { session.submitPassword() }.buttonStyle(.borderedProminent)
                        .disabled(session.passwordInput.isEmpty)
                }

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                Text(message).multilineTextAlignment(.center).foregroundStyle(.white).frame(maxWidth: 420)
                HStack {
                    Button("Close") { nav.closeSession() }.buttonStyle(.bordered)
                    Button("Try again") { session.retry() }.buttonStyle(.borderedProminent)
                }

            case .connected:
                EmptyView()
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Toolbar: View {
    @ObservedObject var session: RemoteSession
    @ObservedObject private var store = AppStore.shared
    @ObservedObject private var nav = NavModel.shared

    var body: some View {
        if session.toolbarOpen {
            HStack(spacing: 4) {
                button("chevron.up") { session.toolbarOpen = false }
                button(session.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard") {
                    session.controls.toggleKeyboard?()
                }
                button(store.settings.inputMode.icon) {
                    store.settings.inputMode = store.settings.inputMode == .trackpad ? .touch : .trackpad
                    session.showToast("\(store.settings.inputMode.label) mode")
                }
                actionsMenu
                clipboardMenu
                streamMenu
                if session.zoomed { button("arrow.down.right.and.arrow.up.left") { session.controls.resetZoom?() } }
                statusText
                button("xmark") { nav.closeSession() }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
        } else {
            Button { session.toolbarOpen = true } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 44, height: 22)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func button(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium)).frame(width: 36, height: 32)
        }
        .foregroundStyle(.white)
    }

    private var statusText: some View {
        let s = session.status
        var parts = [String]()
        if let s, s.battery >= 0 { parts.append("\(s.charging || s.onAC ? "⚡︎" : "")\(s.battery)%") }
        if session.rttMs >= 0 { parts.append("\(session.rttMs) ms") }
        parts.append("\(session.fps) fps")
        return Text(parts.joined(separator: " · "))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 4)
            .lineLimit(1)
    }

    private func act(_ a: QuickAction) { session.send(.action(a)) }

    private var actionsMenu: some View {
        Menu {
            Section("Mac") {
                Button { act(.spotlight) } label: { Label("Spotlight", systemImage: "magnifyingglass") }
                Button { act(.missionControl) } label: { Label("Mission Control", systemImage: "rectangle.3.group") }
                Button { act(.appSwitcher) } label: { Label("Switch app (⌘Tab)", systemImage: "square.on.square") }
                Button { act(.showDesktop) } label: { Label("Show desktop", systemImage: "menubar.dock.rectangle") }
                Button { act(.screenshot) } label: { Label("Screenshot to Desktop", systemImage: "camera.viewfinder") }
                Button { act(.forceQuit) } label: { Label("Force quit…", systemImage: "xmark.octagon") }
            }
            Section("Media") {
                Button { act(.playPause) } label: { Label("Play / Pause", systemImage: "playpause") }
                Button { act(.nextTrack) } label: { Label("Next", systemImage: "forward") }
                Button { act(.previousTrack) } label: { Label("Previous", systemImage: "backward") }
                Button { act(.volumeUp) } label: { Label("Volume up", systemImage: "speaker.plus") }
                Button { act(.volumeDown) } label: { Label("Volume down", systemImage: "speaker.minus") }
                Button { act(.mute) } label: { Label("Mute", systemImage: "speaker.slash") }
            }
            Section("Power") {
                Button { act(.wakeDisplay) } label: { Label("Wake screen", systemImage: "sun.max") }
                Button { act(.sleepDisplay) } label: { Label("Turn off screen", systemImage: "moon") }
                Button { act(.lockScreen) } label: { Label("Lock Mac", systemImage: "lock") }
                if let s = session.status {
                    if s.lidMode {
                        Button { act(.lidModeOff) } label: { Label("Allow sleep with lid closed", systemImage: "laptopcomputer.slash") }
                    } else {
                        Button { act(.lidModeOn) } label: { Label("Keep awake with lid closed", systemImage: "laptopcomputer") }
                    }
                }
                Button(role: .destructive) { act(.sleepMac) } label: { Label("Sleep Mac", systemImage: "powersleep") }
            }
        } label: {
            Image(systemName: "bolt.fill").font(.system(size: 16, weight: .medium)).frame(width: 36, height: 32)
        }
        .foregroundStyle(.white)
    }

    private var clipboardMenu: some View {
        Menu {
            Button {
                _ = session.sendClipboardToMac(andPaste: false)
            } label: { Label("Send iPhone clipboard to Mac", systemImage: "arrow.up.doc.on.clipboard") }
            Button {
                if session.sendClipboardToMac(andPaste: true) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        session.send(.key(code: 55, down: true, flags: ModifierFlag.command))
                        session.send(.key(code: 9, down: true, flags: ModifierFlag.command))
                        session.send(.key(code: 9, down: false, flags: ModifierFlag.command))
                        session.send(.key(code: 55, down: false, flags: 0))
                    }
                }
            } label: { Label("Paste iPhone clipboard on Mac", systemImage: "doc.on.clipboard") }
            if let t = session.lastMacClipboard {
                Button {
                    UIPasteboard.general.string = t
                    session.showToast("Copied to iPhone")
                } label: { Label("Copy Mac clipboard: “\(t.prefix(30))”", systemImage: "arrow.down.doc") }
            }
        } label: {
            Image(systemName: "doc.on.clipboard").font(.system(size: 16, weight: .medium)).frame(width: 36, height: 32)
        }
        .foregroundStyle(.white)
    }

    private var streamMenu: some View {
        Menu {
            Picker("Quality", selection: Binding(get: { store.settings.quality }, set: {
                store.settings.quality = $0; session.updateStream()
            })) {
                ForEach(StreamQuality.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Frame rate", selection: Binding(get: { store.settings.fps }, set: {
                store.settings.fps = $0; session.updateStream()
            })) {
                Text("30 fps (saves battery)").tag(UInt8(30))
                Text("60 fps (smoother)").tag(UInt8(60))
            }
            Picker("Screen when lid is closed", selection: Binding(get: { store.settings.lidFit }, set: {
                store.settings.lidFit = $0; session.updateStream()
            })) {
                ForEach(LidDisplayFit.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            if ProcessInfo.processInfo.isLowPowerModeEnabled && store.settings.autoSaverOnLowPower {
                Text("Low Power Mode: using Battery saver")
            }
        } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 16, weight: .medium)).frame(width: 36, height: 32)
        }
        .foregroundStyle(.white)
    }
}
