import SwiftUI

struct HomeView: View {
    @ObservedObject private var store = AppStore.shared
    @ObservedObject private var discovery = Discovery.shared
    @ObservedObject private var nav = NavModel.shared

    private var nearbyUnsaved: [Discovery.Found] {
        discovery.found.values.filter { f in !store.macs.contains { $0.id == f.id } }.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.macs.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "macbook.and.iphone")
                                .font(.system(size: 44))
                                .foregroundStyle(.tint)
                            Text("Control your Mac from here").font(.title3.bold())
                            Text("1. Run **PocketMac Host** on the Mac and set a password.\n2. Tap **+** and enter the Mac's ID and password.\n3. On another network? Turn on Tailscale on both and add the Mac's Tailscale address.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }

                if !store.macs.isEmpty {
                    Section("My Macs") {
                        ForEach(store.macs) { mac in
                            Button { nav.connect(mac) } label: { MacRow(mac: mac, nearby: discovery.found[mac.id] != nil) }
                                .swipeActions {
                                    Button(role: .destructive) { store.remove(mac) } label: { Label("Delete", systemImage: "trash") }
                                    Button { nav.addForm = AddMacForm(editing: mac) } label: { Label("Edit", systemImage: "pencil") }
                                        .tint(.gray)
                                }
                                .contextMenu {
                                    Button { nav.addForm = AddMacForm(editing: mac) } label: { Label("Edit", systemImage: "pencil") }
                                    Button { store.deleteCredential(for: mac.id) } label: { Label("Forget saved password", systemImage: "key.slash") }
                                    Button(role: .destructive) { store.remove(mac) } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }

                if !nearbyUnsaved.isEmpty {
                    Section("Nearby") {
                        ForEach(nearbyUnsaved) { f in
                            Button {
                                nav.addForm = AddMacForm(id: f.id, name: f.name)
                            } label: {
                                HStack {
                                    Image(systemName: "laptopcomputer").foregroundStyle(.tint)
                                    VStack(alignment: .leading) {
                                        Text(f.name).foregroundStyle(.primary)
                                        Text(DeviceID.pretty(f.id)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("Add").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("PocketMac")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { nav.showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { nav.addForm = AddMacForm() } label: { Image(systemName: "plus") }
                }
            }
        }
    }
}

private struct MacRow: View {
    let mac: SavedMac
    let nearby: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "macbook")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                Circle()
                    .fill(nearby ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 10, height: 10)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name).font(.headline).foregroundStyle(.primary)
                Text(mac.prettyID).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts = [String]()
        parts.append(nearby ? "Nearby" : (mac.internetAddress.isEmpty ? "Not nearby" : "Via \(mac.internetAddress)"))
        if let d = mac.lastConnected { parts.append("last used \(d.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }
}

/// Form state for adding / editing a Mac.
final class AddMacForm: ObservableObject, Identifiable {
    let id = UUID()
    @Published var macID: String
    @Published var name: String
    @Published var address: String
    @Published var port: String
    @Published var password = ""
    @Published var remember = true
    let editing: SavedMac?

    init(id: String = "", name: String = "") {
        macID = DeviceID.pretty(id)
        self.name = name
        address = ""
        port = String(PocketMacPort)
        editing = nil
    }

    init(editing mac: SavedMac) {
        macID = mac.prettyID
        name = mac.name
        address = mac.internetAddress
        port = String(mac.port)
        self.editing = mac
    }

    var idValid: Bool { DeviceID.isValid(macID) }

    func makeMac() -> SavedMac {
        var m = editing ?? SavedMac(id: DeviceID.normalize(macID), name: "", internetAddress: "")
        m.id = DeviceID.normalize(macID)
        m.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "My Mac" : name
        m.internetAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        m.port = UInt16(port) ?? PocketMacPort
        return m
    }
}

struct AddMacView: View {
    @ObservedObject var form: AddMacForm
    @ObservedObject private var nav = NavModel.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("XXXX-XXXX-XXXX", text: $form.macID)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    if !form.macID.isEmpty && !form.idValid {
                        Text("The ID has 12 letters/numbers. It's shown in PocketMac Host on the Mac.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: { Text("Mac ID") } footer: {
                    Text("The ID is the fingerprint of the Mac's key: the app refuses any Mac that doesn't match it.")
                }

                Section("Password") {
                    SecureField(form.editing == nil ? "Mac host password" : "Leave empty to keep saved login", text: $form.password)
                    Toggle("Remember with Face ID", isOn: $form.remember)
                }

                Section {
                    TextField("Name (optional)", text: $form.name)
                } header: { Text("Name") }

                Section {
                    TextField("e.g. naresh-macbook-air or 100.101.102.103", text: $form.address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $form.port).keyboardType(.numberPad)
                } header: { Text("Internet address (for other networks)") } footer: {
                    Text("Leave empty if you only use it on the same Wi-Fi. For anywhere-access, install Tailscale on the Mac and iPhone (same account) and paste the Mac's Tailscale name or 100.x address shown in PocketMac Host.")
                }
            }
            .navigationTitle(form.editing == nil ? "Add Mac" : "Edit Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(form.editing == nil ? "Connect" : "Save") { save() }
                        .disabled(!form.idValid || (form.editing == nil && form.password.isEmpty))
                }
            }
        }
    }

    private func save() {
        let mac = form.makeMac()
        AppStore.shared.upsert(mac)
        let pw = form.password
        let remember = form.remember
        dismiss()
        if form.editing == nil || !pw.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if !pw.isEmpty { AppStore.shared.deleteCredential(for: mac.id) }
                nav.connect(mac, password: pw.isEmpty ? nil : pw, remember: remember)
            }
        }
    }
}
