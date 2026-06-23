import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var coordinatorURL = Config.coordinatorURL
    @State private var saved = false
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    // Link account
    @State private var email = ""
    @State private var password = ""
    @State private var linking = false
    @State private var walletOn = Config.walletBetaActive
    @State private var showWallet = false
    // Persistent storage folder
    @State private var showFolderPicker = false
    @State private var storageName = StorageManager.displayName

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Persistent storage folder (survives uninstall)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dossier de stockage").font(.headline).foregroundColor(Theme.text)
                        Text("Choisissez un dossier (Fichiers / iCloud) où sont gardés les modèles locaux et les shards NVP. Les fichiers y restent même si vous désinstallez l'app — réinstallez puis re-choisissez ce dossier pour tout récupérer.")
                            .font(.caption).foregroundColor(Theme.muted)
                        HStack(spacing: 10) {
                            Image(systemName: StorageManager.isConfigured ? "folder.fill" : "folder.badge.questionmark")
                                .foregroundColor(StorageManager.isConfigured ? Theme.green : Theme.muted)
                            Text(storageName).font(.subheadline).foregroundColor(Theme.text).lineLimit(1)
                            Spacer()
                            Button(StorageManager.isConfigured ? "Changer" : "Choisir") { showFolderPicker = true }
                                .font(.footnote).bold().foregroundColor(Theme.onAccent)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Theme.accent).clipShape(Capsule())
                        }
                    }
                    .card()

                    // On-device model (price, size, install status, download)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("On-device model").font(.headline).foregroundColor(Theme.text)
                        Text("Choose what your iPhone runs, then Download it. Price = what you earn per job.")
                            .font(.caption).foregroundColor(Theme.muted)

                        // Auto
                        Button { app.setWorkerModel("auto") } label: {
                            HStack(spacing: 10) {
                                Image(systemName: Config.workerModelId == "auto" ? "largecircle.fill.circle" : "circle")
                                    .foregroundColor(Config.workerModelId == "auto" ? Theme.green : Theme.muted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Automatic (recommended)").foregroundColor(Theme.text).font(.callout)
                                    Text("Best for your device → \(Config.effectiveModelId)")
                                        .font(.caption2).foregroundColor(Theme.muted)
                                }
                                Spacer()
                                Image(systemName: "wand.and.stars").foregroundColor(Theme.gold)
                            }
                            .padding(.vertical, 6)
                        }
                        Divider().background(Theme.border)

                        ForEach(app.models) { m in
                            let supported = Config.supportedOnDevice.contains(m.id)
                            let selected = m.id == Config.workerModelId
                            let installed = supported && ModelStore.isInstalled(m.id)
                            Button {
                                if supported { app.setWorkerModel(m.id) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                        .foregroundColor(selected ? Theme.green : Theme.muted)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(m.name).foregroundColor(Theme.text).font(.callout)
                                        if !supported {
                                            Text("Not runnable on iOS yet").font(.caption2).foregroundColor(Theme.red)
                                        } else if installed {
                                            Text(String(format: "✓ Installed · %.1f GB on disk", ModelStore.sizeOnDiskGB(m.id)))
                                                .font(.caption2).foregroundColor(Theme.green)
                                        } else {
                                            Text(String(format: "Not downloaded · ~%.1f GB", Double(m.sizeMb) / 1024.0))
                                                .font(.caption2).foregroundColor(Theme.muted)
                                        }
                                    }
                                    Spacer()
                                    Text("\(Format.usd(m.creditRate))/job")
                                        .font(.caption).foregroundColor(Theme.gold)
                                }
                                .padding(.vertical, 6)
                                .opacity(supported ? 1 : 0.5)
                            }
                            .disabled(!supported)
                            Divider().background(Theme.border)
                        }
                        if app.models.isEmpty {
                            Text("Loading models…").font(.caption).foregroundColor(Theme.muted)
                        }

                        // Download / load the selected model now (visible %)
                        if app.isPreloading {
                            VStack(alignment: .leading, spacing: 6) {
                                if app.loadingIntoMemory {
                                    Text("Loading \(Config.effectiveModelId) into memory… (1-2 min)")
                                        .font(.caption).foregroundColor(Theme.gold)
                                } else {
                                    Text(String(format: "Downloading %@ — %.0f/%.0f MB · %.1f MB/s (%d%%)",
                                                Config.effectiveModelId, app.downloadMB, app.downloadTotalMB,
                                                app.downloadSpeedMBs, Int(app.loadProgress * 100)))
                                        .font(.caption).foregroundColor(Theme.gold)
                                }
                                ProgressView(value: app.loadingIntoMemory ? 1 : app.loadProgress).tint(Theme.gold)
                            }
                            .padding(.top, 4)
                        } else {
                            Button {
                                app.preloadModel(Config.workerModelId)
                            } label: {
                                Label(
                                    ModelStore.isInstalled(Config.effectiveModelId) ? "Reload model" : "Download model now",
                                    systemImage: "arrow.down.circle.fill"
                                )
                                .frame(maxWidth: .infinity).padding(10)
                                .background(Theme.accent).foregroundColor(Theme.onAccent)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .padding(.top, 4)
                        }
                    }
                    .card()

                    // NVP Beta — distributed compute (run bigger models across devices)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NVP Beta — distributed compute").font(.headline).foregroundColor(Theme.text)
                        Toggle(isOn: Binding(get: { app.nvpBetaOn }, set: { app.setNvpBeta($0) })) {
                            Text("Join the NVP network").foregroundColor(Theme.text).font(.callout)
                        }.tint(Theme.green)
                        Text("Normally your iPhone runs whole models alone. With NVP Beta, your device joins others to run a share of much bigger models (the model is split across phones). Slower per answer, but unlocks models too big for one device.")
                            .font(.caption2).foregroundColor(Theme.muted)
                        if app.nvpBetaOn {
                            HStack(spacing: 6) {
                                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundColor(Theme.gold)
                                Text(String(format: "Connected · %d peer(s) · ~%.0f GB sharable", app.nexusPeerCount, Config.deviceRamGB * 0.5))
                                    .font(.caption2).foregroundColor(Theme.gold)
                            }
                        }
                    }
                    .card()

                    // Wallet (Beta) — gated by the admin flag
                    VStack(alignment: .leading, spacing: 8) {
                        Text(app.walletActive ? "Wallet" : "Wallet (Beta)").font(.headline).foregroundColor(Theme.text)
                        if app.walletBetaEnabled {
                            Toggle(isOn: Binding(get: { walletOn }, set: { walletOn = $0; Config.walletBetaActive = $0 })) {
                                Text("Enable NVP Wallet (Beta)").foregroundColor(Theme.text).font(.callout)
                            }.tint(Theme.green)
                            Text("Get paid in NVP (1 NVP = $1). Real test-net withdrawals activate when the network is configured.")
                                .font(.caption2).foregroundColor(Theme.muted)
                            if walletOn {
                                Button { showWallet = true } label: {
                                    Label("Open Wallet", systemImage: "wallet.pass.fill")
                                        .frame(maxWidth: .infinity).padding()
                                        .background(Theme.accent).foregroundColor(Theme.onAccent)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        } else {
                            Toggle(isOn: .constant(false)) { Text("Wallet (Beta)").foregroundColor(Theme.muted) }
                                .disabled(true).tint(Theme.green)
                            Text("Disabled by admin. Your balance is safe and will return if re-enabled.")
                                .font(.caption2).foregroundColor(Theme.red)
                        }
                    }
                    .card()

                    // Recovery key
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recovery key").font(.headline).foregroundColor(Theme.text)
                        Text("Download a file with your recovery key. Keep it safe — it reconnects your account (and earnings) on another device.")
                            .font(.caption).foregroundColor(Theme.muted)
                        Button {
                            if let s = app.recoveryString, let url = writeRecoveryFile(s) {
                                shareItems = [url]
                                showShare = true
                            }
                        } label: {
                            Label("Download recovery key", systemImage: "key.fill")
                                .frame(maxWidth: .infinity).padding()
                                .background(Theme.accent).foregroundColor(Theme.onAccent)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .card()

                    // Link to chatbot account
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chatbot account").font(.headline).foregroundColor(Theme.text)
                        if let linked = app.linkedEmail {
                            Label("Linked to \(linked)", systemImage: "checkmark.seal.fill")
                                .foregroundColor(Theme.green).font(.callout)
                            Text("Your earnings show up in the chatbot’s Worker status.")
                                .font(.caption).foregroundColor(Theme.muted)
                        } else {
                            Text("Sign in with your chatbot email to see earnings on the website.")
                                .font(.caption).foregroundColor(Theme.muted)
                            TextField("Email", text: $email)
                                .textInputAutocapitalization(.never).keyboardType(.emailAddress)
                                .padding().background(Theme.elev).clipShape(RoundedRectangle(cornerRadius: 8))
                                .foregroundColor(Theme.text)
                            SecureField("Password", text: $password)
                                .padding().background(Theme.elev).clipShape(RoundedRectangle(cornerRadius: 8))
                                .foregroundColor(Theme.text)
                            Button {
                                linking = true
                                Task { _ = await app.linkAccount(email: email, password: password); linking = false }
                            } label: {
                                Text(linking ? "Linking…" : "Link account")
                                    .bold().frame(maxWidth: .infinity).padding()
                                    .background(Theme.accent).foregroundColor(Theme.onAccent)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .disabled(linking || email.isEmpty || password.isEmpty)
                        }
                    }
                    .card()

                    // Coordinator URL
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Coordinator URL").font(.headline).foregroundColor(Theme.text)
                        TextField("https://…", text: $coordinatorURL)
                            .textInputAutocapitalization(.never).keyboardType(.URL)
                            .padding().background(Theme.elev).clipShape(RoundedRectangle(cornerRadius: 8))
                            .foregroundColor(Theme.text)
                        Button("Save") {
                            Config.coordinatorURL = coordinatorURL.trimmingCharacters(in: .whitespaces)
                            app.rebuildClient()
                            saved = true
                        }
                        .foregroundColor(Theme.gold)
                        if saved { Text("Saved.").font(.caption).foregroundColor(Theme.green) }
                    }
                    .card()

                    // Device
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Device").font(.headline).foregroundColor(Theme.text)
                        row("Worker ID", app.workerId ?? "—")
                        row("Model", Config.workerModelId)
                        row("Charging", app.deviceState.isCharging ? "Yes" : "No")
                    }
                    .card()

                    Button(role: .destructive) { app.signOut() } label: {
                        Text("Sign out / reset device")
                            .frame(maxWidth: .infinity).padding()
                            .background(Theme.elev2).foregroundColor(Theme.red)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if let err = app.errorMessage {
                        Text(err).font(.caption).foregroundColor(Theme.red)
                    }
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .task { try? await app.loadModels() }
            .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
            .sheet(isPresented: $showWallet) { WalletView().environmentObject(app) }
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker { url in
                    try? StorageManager.setFolder(url)
                    storageName = StorageManager.displayName
                    showFolderPicker = false
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(Theme.muted)
            Spacer()
            Text(value).foregroundColor(Theme.text).font(.callout).lineLimit(1).truncationMode(.middle)
        }
    }
}
