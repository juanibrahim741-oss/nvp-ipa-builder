import SwiftUI
import UIKit

/// NVP-D "split mode" card: lists the distributed models on the network and lets
/// the user download the CoreML shards needed to participate, with an animated
/// progress ring + per-shard chips that light up as each shard installs.
struct NexusDownloadView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var dl = NexusDownloadManager()
    @State private var models: [DistModel] = []
    @State private var active: String?
    @State private var loading = false
    @State private var autoPrepared = false
    @State private var info: String = ""

    struct DistModel: Identifiable {
        let id: String        // modelId (hash)
        let name: String      // human-readable HF id
        let shards: Int
        var installed: Int { NexusShardStore.installedShardCount(modelId: id, total: shards) }
        var ready: Bool { shards > 0 && installed == shards }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "square.stack.3d.up.fill").foregroundColor(Theme.gold)
                Text("Split mode (NVP-D)").font(.headline).foregroundColor(Theme.text)
                Spacer()
                if loading { ProgressView().scaleEffect(0.8) }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .foregroundColor(Theme.muted)
            }

            if !app.nvpBetaOn {
                Text("Activez le protocole NVP (Réglages) pour télécharger et utiliser les modèles distribués.")
                    .font(.caption).foregroundColor(Theme.muted)
            } else if models.isEmpty {
                Text("Aucun modèle distribué pour l'instant. L'admin doit en publier un — il apparaîtra ici automatiquement.")
                    .font(.caption).foregroundColor(Theme.muted)
            } else {
                Text("Protocole NVP actif — préparation des modèles distribués.")
                    .font(.caption2).foregroundColor(Theme.green)
            }

            ForEach(models) { m in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name).font(.subheadline).bold().foregroundColor(Theme.text).lineLimit(1)
                            Text("\(m.shards) shards · \(m.installed)/\(m.shards) installed")
                                .font(.caption2).foregroundColor(Theme.muted)
                        }
                        Spacer()
                        if m.ready {
                            Label("Ready", systemImage: "checkmark.seal.fill")
                                .font(.caption).foregroundColor(Theme.green)
                        } else if active == m.id && dl.busy {
                            progressRing
                        } else {
                            Button("Download") { Task { await download(m) } }
                                .font(.caption).bold()
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Theme.gold).foregroundColor(Theme.onAccent)
                                .clipShape(Capsule())
                        }
                    }
                    // Per-shard chips
                    HStack(spacing: 5) {
                        ForEach(0..<max(1, m.shards), id: \.self) { i in
                            let on = i < (active == m.id ? max(m.installed, dl.installed) : m.installed)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(on ? Theme.green : Theme.elev2)
                                .frame(height: 8)
                                .animation(.easeInOut, value: on)
                        }
                    }
                    if active == m.id && dl.busy {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dl.totalMB > 0
                                 ? String(format: "%@ · %.0f / %.0f MB", dl.status, dl.downloadedMB, dl.totalMB)
                                 : String(format: "%@ · %.0f MB", dl.status, dl.downloadedMB))
                                .font(.caption2).foregroundColor(Theme.text)
                            Text(String(format: "%.1f MB/s%@", dl.speedMBs, dl.etaSec > 0 ? " · ~\(dl.etaSec)s restantes" : ""))
                                .font(.caption2).foregroundColor(Theme.muted)
                        }
                    }
                    // Manual path: download via browser → move to folder → verify.
                    HStack(spacing: 14) {
                        Button { browser(m) } label: { Label("Navigateur", systemImage: "safari") }
                            .font(.caption2).foregroundColor(Theme.gold)
                        Button { Task { await load(); info = m.ready ? "✅ \(m.name) vérifié — prêt." : "⚠️ Shards manquants pour \(m.name) (\(m.installed)/\(m.shards))." } } label: {
                            Label("Vérifier", systemImage: "checkmark.circle")
                        }.font(.caption2).foregroundColor(Theme.green)
                    }
                }
                .padding(.vertical, 6)
                if m.id != models.last?.id { Divider().background(Theme.elev2) }
            }

            if !info.isEmpty {
                Text(info).font(.caption2).foregroundColor(Theme.text)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.elev2).clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .card()
        .onAppear { Task { await load() } }
        .onChange(of: app.nvpBetaOn) { _ in Task { await load() } }
    }

    private var progressRing: some View {
        ZStack {
            Circle().stroke(Theme.elev2, lineWidth: 4).frame(width: 34, height: 34)
            Circle().trim(from: 0, to: dl.progress)
                .stroke(Theme.gold, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 34, height: 34).rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: dl.progress)
            Text("\(Int(dl.progress * 100))").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.text)
        }
    }

    @MainActor private func load() async {
        loading = true
        let raw = await NexusClient().manifests()
        models = raw.compactMap { e in
            guard let id = e["modelId"] as? String else { return nil }
            let man = e["manifest"] as? [String: Any] ?? [:]
            let name = (man["name"] as? String) ?? id
            let shards = (man["shards"] as? [[String: Any]])?.count ?? 0
            return DistModel(id: id, name: name, shards: shards)
        }
        loading = false
        // When the NVP protocol is active, automatically prepare (download) every
        // distributed model that isn't installed yet — no manual tap needed.
        if app.nvpBetaOn && !autoPrepared {
            autoPrepared = true
            for m in models where !m.ready { await download(m) }
        }
    }

    @MainActor private func download(_ m: DistModel) async {
        active = m.id
        guard let manifest = await NexusClient().manifest(modelId: m.id),
              let plan = await dl.plan(manifest: manifest) else { active = nil; return }
        await dl.download(plan: plan)
        await load()
        active = nil
    }

    /// Open the model's GitHub Release in the browser + show move-to-folder steps.
    private func browser(_ m: DistModel) {
        Task {
            let manifest = await NexusClient().manifest(modelId: m.id)
            let shardURL = (manifest?["shards"] as? [[String: Any]])?.compactMap { $0["url"] as? String }.first
            await MainActor.run {
                if let page = shardURL.flatMap(releasePage), let u = URL(string: page) {
                    UIApplication.shared.open(u)
                } else if let s = shardURL, let u = URL(string: s) {
                    UIApplication.shared.open(u)
                } else {
                    info = "Lien indisponible — relance la synchro côté admin."; return
                }
                let dest = "\(StorageManager.displayName)/nexus/\(m.id)"
                info = "1) Télécharge les .zip depuis la page ouverte.\n2) Dans Fichiers, décompresse chaque .zip.\n3) Déplace les dossiers shard_*.mlmodelc et tokenizer dans :\n  \(dest)\n4) Appuie sur Vérifier."
            }
        }
    }

    /// `…/releases/download/<tag>/<file>` → `…/releases/tag/<tag>` (all assets).
    private func releasePage(_ assetURL: String) -> String? {
        guard let r = assetURL.range(of: "/releases/download/") else { return nil }
        let prefix = assetURL[..<r.lowerBound]
        let rest = assetURL[r.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return "\(prefix)/releases/tag/\(rest[..<slash])"
    }
}
