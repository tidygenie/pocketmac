import SwiftUI
import UIKit

@main
struct PocketMacApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// App-wide navigation state (kept in an ObservableObject rather than @State).
final class NavModel: ObservableObject {
    static let shared = NavModel()
    @Published var session: RemoteSession?
    @Published var addForm: AddMacForm?
    @Published var showSettings = false

    func connect(_ mac: SavedMac, password: String? = nil, remember: Bool = true) {
        session?.disconnect()
        let s = RemoteSession(mac: mac)
        s.rememberPassword = remember
        session = s
        s.start(password: password)
    }

    func closeSession() {
        session?.disconnect()
        session = nil
    }
}

struct RootView: View {
    @ObservedObject private var nav = NavModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HomeView()
            .fullScreenCover(item: $nav.session) { s in
                RemoteScreen(session: s)
            }
            .sheet(item: $nav.addForm) { form in
                AddMacView(form: form)
            }
            .sheet(isPresented: $nav.showSettings) {
                SettingsView()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    nav.session?.suspend()
                    Discovery.shared.stop()
                case .active:
                    Discovery.shared.start()
                    nav.session?.resume()
                default: break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                DispatchQueue.main.async { nav.session?.updateStream() }
            }
            .onAppear {
                Discovery.shared.start()
                DebugHooks.autoconnectIfRequested()
            }
    }
}
