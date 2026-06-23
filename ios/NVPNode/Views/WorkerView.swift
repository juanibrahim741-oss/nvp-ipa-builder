import SwiftUI

struct WorkerView: View {
    @EnvironmentObject var app: AppState
    @State private var showNVP = false

    var body: some View {
        content.fullScreenCover(isPresented: $showNVP) { NVPBetaView().environmentObject(app) }
    }

    private var bannerColor: Color {
        switch app.deviceState.statusBanner.color {
        case "green": return Theme.green
        case "red": return Theme.red
        default: return Theme.gold
        }
    }

    private var isLive: Bool { app.isWorker && app.deviceState.canWork }

    private var content: some View {
        ScrollView {
            VStack(spacing: 18) {
                // Header
                HStack {
                    Text("NVP").font(.title2).bold().foregroundColor(Theme.gold)
                    Text("Worker").font(.title2).bold().foregroundColor(Theme.text)
                    Spacer()
                    StatusPill(live: isLive, text: app.status)
                }
                .padding(.top, 8)

                // Balance hero
                VStack(spacing: 4) {
                    Text("Total balance").font(.caption).foregroundColor(Theme.muted)
                    Text(Format.usd(app.balance))
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundColor(Theme.gold)
                    Text("+\(Format.usd(app.creditsToday)) today")
                        .font(.footnote).foregroundColor(Theme.green)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(
                    LinearGradient(colors: [Theme.elev2, Theme.elev], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))

                // Big toggle card
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(isLive ? Theme.green.opacity(0.18) : Color.white.opacity(0.06))
                                .frame(width: 52, height: 52)
                            Image(systemName: "bolt.fill")
                                .foregroundColor(isLive ? Theme.green : Theme.muted)
                                .font(.title2)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.isWorker ? "Worker is ON" : "Become a worker")
                                .font(.headline).foregroundColor(Theme.text)
                            Text(app.isWorker ? "Earning while open" : "Earn by running AI")
                                .font(.caption).foregroundColor(Theme.muted)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { app.isWorker }, set: { app.setWorker($0) }))
                            .labelsHidden()
                            .tint(Theme.green)
                    }
                    Divider().background(Color.white.opacity(0.06))
                    HStack(spacing: 8) {
                        Circle().fill(bannerColor).frame(width: 9, height: 9)
                        Text(app.deviceState.statusBanner.text)
                            .font(.footnote).foregroundColor(Theme.muted)
                        Spacer()
                    }
                }
                .card()

                // Connection + model status
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(app.connected ? Theme.green : Theme.red).frame(width: 9, height: 9)
                        Text(app.connected ? "Coordinator connected" : "Coordinator unreachable — set URL in Settings")
                            .font(.footnote).foregroundColor(app.connected ? Theme.muted : Theme.red)
                        Spacer()
                    }
                    if app.nvpEnabled {
                        HStack(spacing: 6) {
                            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundColor(Theme.gold)
                            Text("NVP Protocol ON — answers split across devices (torrent-style)")
                                .font(.caption2).foregroundColor(Theme.gold)
                            Spacer()
                        }
                    }
                    Divider().background(Color.white.opacity(0.06))
                    if app.nvpBetaOn { nvpStatus } else { localModelStatus }
                }
                .card()

                // Stats grid
                HStack(spacing: 12) {
                    StatCard(icon: "tray.full.fill", label: "Jobs today", value: "\(app.jobsToday)")
                    StatCard(icon: "speedometer", label: "Speed", value: String(format: "%.0f tok/s", app.tokensPerSec))
                }
                HStack(spacing: 12) {
                    StatCard(icon: "line.3.horizontal.decrease.circle.fill", label: "Queue", value: "\(app.queueDepth)")
                    StatCard(icon: "timer", label: "Last latency", value: "\(app.lastLatencyMs) ms")
                }
                HStack(spacing: 12) {
                    StatCard(icon: "bolt.batteryblock.fill", label: "Charging", value: app.deviceState.isCharging ? "Yes" : "No")
                    StatCard(icon: "thermometer.medium", label: "Thermal", value: thermalLabel)
                }

                if let err = app.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.red)
                        Text(err).font(.caption).foregroundColor(Theme.red)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }
            }
            .padding()
        }
    }

    // Local (single-device) model status — shown only when NVP mode is OFF.
    private var localModelStatus: some View {
        let installed = ModelStore.isInstalled(Config.effectiveModelId)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundColor(installed ? Theme.green : Theme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Config.effectiveModelId).font(.subheadline)
                        .foregroundColor(installed ? Theme.green : Theme.text)
                    if app.isPreloading {
                        Text(app.loadingIntoMemory
                             ? "Loading into memory… (1-2 min)"
                             : String(format: "%.0f / %.0f MB · %.1f MB/s", app.downloadMB, app.downloadTotalMB, app.downloadSpeedMBs))
                            .font(.caption2).foregroundColor(Theme.muted)
                    } else if installed {
                        Text(String(format: "Downloaded ✓ · %.1f GB", ModelStore.sizeOnDiskGB(Config.effectiveModelId)))
                            .font(.caption2).foregroundColor(Theme.green)
                    } else {
                        Text("Not downloaded").font(.caption2).foregroundColor(Theme.muted)
                    }
                }
                Spacer()
                if !app.isPreloading {
                    Button(installed ? "Launch" : "Download") { app.preloadModel(Config.workerModelId) }
                        .font(.footnote).bold().foregroundColor(Theme.onAccent)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(installed ? Theme.green : Theme.accent).clipShape(Capsule())
                }
            }
            if app.isPreloading {
                ProgressView(value: app.loadingIntoMemory ? 1 : app.loadProgress).tint(Theme.gold)
            }
        }
    }

    // NVP-D mode status — distributed only; local model is disabled.
    private var nvpStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundColor(Theme.gold)
                Text("Mode NVP-D actif").font(.subheadline).bold().foregroundColor(Theme.gold)
                Spacer()
                Text("Modèle local désactivé").font(.caption2).foregroundColor(Theme.muted)
            }
            HStack(spacing: 10) {
                nvpMetric("\(app.nvpPowerTops)", "TOPS")
                nvpMetric(String(format: "%.0f", Config.deviceRamGB), "GB RAM")
                nvpMetric("\(app.nexusPeerCount)", "pairs")
                nvpMetric("\(app.nvpServedModels.count)", "modèles")
            }
            Text("Le worker sert et exécute uniquement des shards NVP-D.")
                .font(.caption2).foregroundColor(Theme.muted)
            Button { showNVP = true } label: {
                HStack { Image(systemName: "rectangle.3.group.fill"); Text("Ouvrir NVP Beta") }
                    .font(.subheadline).bold().foregroundColor(Theme.onAccent)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Theme.gold).clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func nvpMetric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).foregroundColor(Theme.text)
            Text(label).font(.caption2).foregroundColor(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var thermalLabel: String {
        switch app.deviceState.thermal {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "—"
        }
    }
}

private struct StatusPill: View {
    let live: Bool
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(live ? Theme.green : Theme.muted).frame(width: 8, height: 8)
            Text(live ? "LIVE" : text.uppercased())
                .font(.caption2).bold()
                .foregroundColor(live ? Theme.green : Theme.muted)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
    }
}

private struct StatCard: View {
    let icon: String
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundColor(Theme.gold).font(.subheadline)
            Text(value).font(.title3).bold().foregroundColor(Theme.text)
            Text(label).font(.caption2).foregroundColor(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
