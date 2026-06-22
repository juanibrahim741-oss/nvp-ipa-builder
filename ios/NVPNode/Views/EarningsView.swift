import SwiftUI

struct EarningsView: View {
    @EnvironmentObject var app: AppState
    @State private var showPayout = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Text("Balance").font(.caption).foregroundColor(Theme.muted)
                        Text(Format.usd(app.balance))
                            .font(.system(size: 40, weight: .bold)).foregroundColor(Theme.gold)
                        Text("\(app.jobsDone) jobs done").font(.caption).foregroundColor(Theme.muted)
                    }
                    .frame(maxWidth: .infinity).card()

                    Button { showPayout = true } label: {
                        Text("Request a withdrawal")
                            .bold().frame(maxWidth: .infinity).padding()
                            .background(Theme.gold).foregroundColor(Theme.bg)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    EarningsChart(entries: app.ledger)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("History").font(.headline).foregroundColor(Theme.text)
                        if app.ledger.isEmpty {
                            Text("No entries yet.").font(.caption).foregroundColor(Theme.muted)
                        }
                        ForEach(app.ledger) { e in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(e.type.capitalized).foregroundColor(Theme.text)
                                    Text(e.createdAt.prefix(10)).font(.caption2).foregroundColor(Theme.muted)
                                }
                                Spacer()
                                Text((e.amount >= 0 ? "+" : "") + Format.usd(e.amount))
                                    .foregroundColor(e.amount >= 0 ? Theme.green : Theme.red)
                            }
                            .padding(.vertical, 6)
                            Divider().background(Color.white.opacity(0.05))
                        }
                    }
                    .card()
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("Earnings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPayout) { PayoutView() }
            .task { await app.refreshEarnings() }
            .refreshable { await app.refreshEarnings() }
        }
    }
}

/// Tiny cumulative-credits sparkline (no external charting dependency).
struct EarningsChart: View {
    let entries: [LedgerEntry]

    private var cumulative: [Double] {
        // oldest -> newest cumulative sum of earn entries
        let earns = entries.reversed().map { $0.amount }
        var total = 0.0
        return earns.map { total += $0; return total }
    }

    var body: some View {
        let points = cumulative
        return VStack(alignment: .leading, spacing: 8) {
            Text("Cumulative credits").font(.headline).foregroundColor(Theme.text)
            GeometryReader { geo in
                if points.count > 1, let maxV = points.max(), maxV > 0 {
                    Path { p in
                        for (i, v) in points.enumerated() {
                            let x = geo.size.width * CGFloat(i) / CGFloat(points.count - 1)
                            let y = geo.size.height * (1 - CGFloat(v / maxV))
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                            else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(Theme.gold, lineWidth: 2)
                } else {
                    Text("Not enough data yet").font(.caption).foregroundColor(Theme.muted)
                }
            }
            .frame(height: 90)
        }
        .card()
    }
}
