import SwiftUI

struct PayoutView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var busy = false
    @State private var done = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Available balance: \(Format.usd(app.balance))")
                        .foregroundColor(Theme.muted)

                    VStack(alignment: .leading) {
                        Text("Amount (USD)").font(.caption).foregroundColor(Theme.muted)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .padding().background(Theme.elev)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .foregroundColor(Theme.text)
                    }
                    Text("Method: manual (v0). This creates a withdrawal request in status “requested”; no real transfer happens yet.")
                        .font(.caption).foregroundColor(Theme.muted)

                    if done {
                        Text("✅ Request submitted (status: requested).").foregroundColor(Theme.green)
                    }

                    Button {
                        guard let amount = Double(amountText), amount > 0 else { return }
                        busy = true
                        Task {
                            let ok = await app.requestPayout(amount: amount)
                            busy = false
                            if ok { done = true }
                        }
                    } label: {
                        Text(busy ? "Submitting…" : "Confirm withdrawal")
                            .bold().frame(maxWidth: .infinity).padding()
                            .background(Theme.gold).foregroundColor(Theme.bg)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(busy || Double(amountText) == nil)

                    if !app.payoutsList.isEmpty {
                        Text("Past requests").font(.headline).foregroundColor(Theme.text)
                        ForEach(app.payoutsList) { p in
                            HStack {
                                Text(Format.usd(p.amount)).foregroundColor(Theme.text)
                                Spacer()
                                Text(p.status).font(.caption).foregroundColor(Theme.muted)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("Withdraw")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
