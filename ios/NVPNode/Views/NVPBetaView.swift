import SwiftUI

/// Full-screen "NVP Beta" control center (opened from the Worker screen like the
/// wallet). Shows distributed-mode status, live power/peers, an interactive
/// animated network graph, and the downloaded split models with live progress.
struct NVPBetaView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var pulse = false
    @State private var selectedNode: Int? = nil

    private var nodes: Int { max(1, min(app.nexusPeerCount + 1, 12)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // Status header
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(app.nvpBetaOn ? Theme.green.opacity(0.18) : Color.white.opacity(0.06)).frame(width: 52, height: 52)
                            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundColor(app.nvpBetaOn ? Theme.green : Theme.muted).font(.title2)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.nvpBetaOn ? "NVP-D actif" : "NVP-D inactif").font(.headline).foregroundColor(Theme.text)
                            Text(app.nvpBetaOn ? "Exécution répartie sur plusieurs appareils" : "Activez NVP dans Réglages")
                                .font(.caption).foregroundColor(Theme.muted)
                        }
                        Spacer()
                    }.card()

                    // Metrics
                    HStack(spacing: 10) {
                        metric("\(app.nvpPowerTops)", "TOPS")
                        metric(String(format: "%.0f", Config.deviceRamGB), "GB RAM")
                        metric("\(app.nexusPeerCount)", "pairs")
                        metric("\(app.nvpServedModels.count)", "modèles")
                    }

                    // Interactive animated network graph
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Réseau NVP").font(.subheadline).bold().foregroundColor(Theme.text)
                        GeometryReader { geo in
                            let w = geo.size.width, h = geo.size.height
                            let cx = w / 2, cy = h / 2, r = min(w, h) / 2 - 26
                            ZStack {
                                ForEach(0..<nodes, id: \.self) { i in
                                    let p = point(i, nodes, cx, cy, r)
                                    Path { $0.move(to: CGPoint(x: cx, y: cy)); $0.addLine(to: p) }
                                        .stroke(Theme.gold.opacity(pulse ? 0.5 : 0.18), lineWidth: 1.5)
                                }
                                ForEach(0..<nodes, id: \.self) { i in
                                    let p = point(i, nodes, cx, cy, r)
                                    Circle().fill(selectedNode == i ? Theme.gold : Theme.green)
                                        .frame(width: selectedNode == i ? 18 : 13, height: selectedNode == i ? 18 : 13)
                                        .position(p).opacity(pulse ? 1 : 0.7)
                                        .onTapGesture { selectedNode = (selectedNode == i ? nil : i) }
                                }
                                ZStack {
                                    Circle().stroke(Theme.gold.opacity(0.4), lineWidth: 2).frame(width: pulse ? 78 : 60, height: pulse ? 78 : 60)
                                    Circle().fill(Theme.gold).frame(width: 44, height: 44)
                                    Image(systemName: "bolt.fill").foregroundColor(Theme.onAccent)
                                }.position(x: cx, y: cy)
                            }
                        }.frame(height: 250)
                        if let n = selectedNode {
                            Text(n == 0 ? "Cet appareil (orchestrateur possible)" : "Pair #\(n) — sert des shards")
                                .font(.caption).foregroundColor(Theme.muted)
                        }
                    }.card()

                    // Downloaded split models + live progress
                    NexusDownloadView()
                }.padding()
            }
            .background(Theme.bg)
            .navigationTitle("NVP Beta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { dismiss() } } }
            .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true } }
        }
    }

    private func metric(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.title3).bold().foregroundColor(Theme.text)
            Text(l).font(.caption2).foregroundColor(Theme.muted)
        }.frame(maxWidth: .infinity).padding(.vertical, 12).background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func point(_ i: Int, _ count: Int, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPoint {
        let a = (2 * Double.pi * Double(i) / Double(count)) - Double.pi / 2
        return CGPoint(x: cx + r * CGFloat(cos(a)), y: cy + r * CGFloat(sin(a)))
    }
}
