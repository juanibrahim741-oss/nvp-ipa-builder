import SwiftUI

/// Live, animated view of the network: how many workers are online (nodes + lines
/// pulsing toward a central hub), and an animated activity panel that reacts when
/// this device loads the model, receives a job, and runs inference.
struct NetworkView: View {
    @EnvironmentObject var app: AppState
    @State private var pulse = false

    private var onlineNodes: Int { max(0, min(app.networkOnline, 14)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // Headline counts
                    HStack(spacing: 12) {
                        StatPill(value: "\(app.networkOnline)", label: "online", accent: Theme.green)
                        StatPill(value: "\(app.networkTotal)", label: "devices", accent: Theme.text)
                        StatPill(value: "\(app.networkTops)", label: "TOPS", accent: Theme.gold)
                    }

                    // Radial network graph
                    GeometryReader { geo in
                        let w = geo.size.width
                        let h = geo.size.height
                        let cx = w / 2, cy = h / 2
                        let r = min(w, h) / 2 - 34
                        ZStack {
                            // connecting lines
                            ForEach(0..<onlineNodes, id: \.self) { i in
                                let p = nodePoint(i, count: onlineNodes, cx: cx, cy: cy, r: r)
                                Path { path in
                                    path.move(to: CGPoint(x: cx, y: cy))
                                    path.addLine(to: p)
                                }
                                .stroke(Theme.gold.opacity(pulse ? 0.5 : 0.15), lineWidth: 1.5)
                            }
                            // worker nodes
                            ForEach(0..<onlineNodes, id: \.self) { i in
                                let p = nodePoint(i, count: onlineNodes, cx: cx, cy: cy, r: r)
                                Circle()
                                    .fill(Theme.green)
                                    .frame(width: 14, height: 14)
                                    .position(p)
                                    .opacity(pulse ? 1 : 0.7)
                            }
                            // central hub (you / coordinator)
                            ZStack {
                                Circle()
                                    .stroke(Theme.gold.opacity(0.4), lineWidth: 2)
                                    .frame(width: pulse ? 86 : 64, height: pulse ? 86 : 64)
                                Circle().fill(Theme.gold).frame(width: 46, height: 46)
                                Image(systemName: "bolt.fill").foregroundColor(Theme.onAccent)
                            }
                            .position(x: cx, y: cy)

                            if onlineNodes == 0 {
                                Text("No workers online")
                                    .font(.caption).foregroundColor(Theme.muted)
                                    .position(x: cx, y: cy + r + 14)
                            }
                        }
                    }
                    .frame(height: 280)
                    .card()

                    // Live activity panel
                    activityCard

                    // NVP-D split mode: download distributed-model shards (animated)
                    NexusDownloadView()

                    Text("Split mode (NVP-D) distributes one model across devices. Download a model's shards above to join.")
                        .font(.caption2).foregroundColor(Theme.muted).multilineTextAlignment(.center)
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("Network")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
            }
        }
    }

    private var activityCard: some View {
        let a = app.activity
        let (icon, label, color): (String, String, Color) = {
            switch a {
            case .idle: return ("moon.zzz.fill", "Idle — turn worker ON", Theme.muted)
            case .loadingModel: return ("arrow.down.circle.fill", "Loading model…", Theme.gold)
            case .waiting: return ("antenna.radiowaves.left.and.right", "Waiting for a job…", Theme.green)
            case .receivedJob: return ("tray.and.arrow.down.fill", "Job received!", Theme.gold)
            case .inferring: return ("brain.head.profile", "Running AI…", Theme.green)
            case .submitting: return ("arrow.up.circle.fill", "Submitting result…", Theme.gold)
            }
        }()
        let busy = a == .loadingModel || a == .inferring || a == .receivedJob || a == .submitting
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundColor(color).font(.title2)
                    .scaleEffect(busy && pulse ? 1.15 : 1.0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.headline).foregroundColor(Theme.text)
                    if a == .loadingModel {
                        Text("Downloading / loading… \(Int(app.loadProgress * 100))%")
                            .font(.caption).foregroundColor(Theme.muted)
                    } else {
                        Text("\(String(format: "%.1f", app.liveTokps)) tokens/sec across the network")
                            .font(.caption).foregroundColor(Theme.muted)
                    }
                }
                Spacer()
            }
            // Indeterminate activity bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.elev2).frame(height: 6)
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * (busy ? 0.6 : 0.0), height: 6)
                        .offset(x: busy ? (pulse ? geo.size.width * 0.4 : -geo.size.width * 0.1) : 0)
                        .opacity(busy ? 1 : 0)
                }
            }
            .frame(height: 6)
        }
        .card()
    }

    private func nodePoint(_ i: Int, count: Int, cx: CGFloat, cy: CGFloat, r: CGFloat) -> CGPoint {
        guard count > 0 else { return CGPoint(x: cx, y: cy) }
        let angle = (2 * Double.pi * Double(i) / Double(count)) - Double.pi / 2
        return CGPoint(x: cx + r * CGFloat(cos(angle)), y: cy + r * CGFloat(sin(angle)))
    }
}

private struct StatPill: View {
    let value: String
    let label: String
    let accent: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3).bold().foregroundColor(accent)
            Text(label).font(.caption2).foregroundColor(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .card()
    }
}
