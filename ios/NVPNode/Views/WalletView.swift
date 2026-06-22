import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

// MARK: - Ninise-inspired palette (light, gradient, rounded)
// Design adapted from github.com/Ninise/ios_crypto_wallet_app.
private enum Nin {
    static let bg = Color(hex: "#F5F5F5")
    static let text = Color(hex: "#2B2D41")
    static let green = Color(hex: "#04B761")
    static let card = Color.white
    static let muted = Color(hex: "#8A8CA0")
    static let grad = [Color(hex: "#7A17D7"), Color(hex: "#ED74CD"), Color(hex: "#EBB5A3")]
    static let nvpGrad = [Color(hex: "#7A17D7"), Color(hex: "#6A32CF")]
    static let ethGrad = [Color(hex: "#383838"), Color(hex: "#161717")]
    static func font(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: size, weight: w, design: .rounded) }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0; Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255, g = Double((int >> 8) & 0xFF) / 255, b = Double(int & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// NVP Wallet — real non-custodial wallet (Base Sepolia), Ninise-style UI.
struct WalletView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var wallet = NVPWallet()

    var body: some View {
        NavigationStack {
            Group {
                if wallet.hasWallet { NinHome(wallet: wallet) }
                else { NinOnboarding(wallet: wallet) }
            }
            .background(Nin.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
        }
        .environmentObject(app)
        .tint(Nin.green)
    }
}

// MARK: - Onboarding (Welcome → Secret phrase → Confirm)

private struct NinOnboarding: View {
    @ObservedObject var wallet: NVPWallet
    @State private var words: [String] = []
    @State private var confirmed = false
    @State private var importing = false
    @State private var importText = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(LinearGradient(colors: Nin.grad, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 150)
                    VStack(spacing: 6) {
                        Image(systemName: "wallet.pass.fill").font(.system(size: 34)).foregroundColor(.white)
                        Text("NVP Wallet").font(Nin.font(24, .bold)).foregroundColor(.white)
                        Text("Your keys, your crypto").font(Nin.font(13)).foregroundColor(.white.opacity(0.9))
                    }
                }

                if words.isEmpty && !importing {
                    Text("A real testnet wallet. You alone hold the 12-word recovery phrase — keep it secret and safe.")
                        .font(Nin.font(15)).foregroundColor(Nin.muted)
                    ninButton("Create a new wallet", "plus.circle.fill") {
                        if let w = wallet.create() { words = w } else { error = "Could not create wallet" }
                    }
                    Button { importing = true } label: {
                        Text("I already have a recovery phrase").font(Nin.font(15, .medium)).foregroundColor(Nin.text)
                            .frame(maxWidth: .infinity).padding().background(Nin.card).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }

                if !words.isEmpty {
                    Text("Your recovery phrase").font(Nin.font(18, .bold)).foregroundColor(Nin.text)
                    phraseGrid(words)
                    Button { UIPasteboard.general.string = words.joined(separator: " ") } label: {
                        Label("Copy", systemImage: "doc.on.doc").font(Nin.font(13, .medium)).foregroundColor(Nin.green)
                    }
                    Toggle(isOn: $confirmed) { Text("I saved my phrase safely").font(Nin.font(15)).foregroundColor(Nin.text) }
                        .tint(Nin.green)
                    ninButton("Open my wallet", "checkmark.seal.fill", enabled: confirmed) { wallet.confirmCreate() }
                }

                if importing {
                    Text("Enter your recovery phrase").font(Nin.font(18, .bold)).foregroundColor(Nin.text)
                    TextField("12 or 24 words", text: $importText, axis: .vertical)
                        .lineLimit(3...5).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(Nin.font(15)).padding().background(Nin.card).clipShape(RoundedRectangle(cornerRadius: 16))
                    ninButton("Import wallet", "square.and.arrow.down.fill") {
                        if wallet.importMnemonic(importText) { } else { error = "Invalid recovery phrase" }
                    }
                    Button { importing = false } label: { Text("Cancel").font(Nin.font(15)).foregroundColor(Nin.muted) }
                }

                if let error { Text(error).font(Nin.font(13)).foregroundColor(.red) }
            }
            .padding()
        }
    }
}

// MARK: - Home

private struct NinHome: View {
    @ObservedObject var wallet: NVPWallet
    @EnvironmentObject var app: AppState
    @State private var showSend = false
    @State private var showReceive = false
    @State private var showPhrase = false
    @State private var status: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                // Gradient balance header
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(LinearGradient(colors: Nin.grad, startPoint: .topLeading, endPoint: .bottomTrailing))
                    VStack(spacing: 6) {
                        Text("Total balance").font(Nin.font(13)).foregroundColor(.white.opacity(0.9))
                        Text("$" + String(format: "%.2f", wallet.nvpBalance)).font(Nin.font(40, .bold)).foregroundColor(.white)
                        Text(String(format: "%.4f NVP", wallet.nvpBalance)).font(Nin.font(13)).foregroundColor(.white.opacity(0.9))
                    }.padding(.vertical, 26)
                }
                .frame(height: 170)

                // Actions
                HStack(spacing: 12) {
                    ninAction("Receive", "qrcode") { showReceive = true }
                    ninAction("Send", "paperplane.fill") { showSend = true }
                }

                // Assets
                VStack(spacing: 10) {
                    assetRow("NVP", "1 NVP = $1.00", wallet.nvpBalance, "n.circle.fill", Nin.nvpGrad)
                    assetRow("ETH", "gas · Base Sepolia", wallet.ethBalance, "e.circle.fill", Nin.ethGrad)
                }

                // Earnings → wallet
                VStack(alignment: .leading, spacing: 10) {
                    Text("Earnings").font(Nin.font(17, .bold)).foregroundColor(Nin.text)
                    Text("You earned \(Format.usd(app.balance)) running AI. Withdraw it as real NVP to this wallet.")
                        .font(Nin.font(13)).foregroundColor(Nin.muted)
                    ninButton("Withdraw earnings", "arrow.down.circle.fill", enabled: app.balance > 0) {
                        Task {
                            status = "Sending on-chain…"
                            if let tx = await app.withdrawEarnings(amount: nil), !tx.isEmpty {
                                status = "Withdrawn ✓ \(tx.prefix(10))…"
                                try? await Task.sleep(nanoseconds: 6_000_000_000); await wallet.refresh()
                            } else { status = app.errorMessage ?? "Withdrawal failed" }
                        }
                    }
                }.ninCard()

                // Address
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your address").font(Nin.font(17, .bold)).foregroundColor(Nin.text)
                    HStack {
                        Text(wallet.address ?? "—").font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Nin.muted).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { UIPasteboard.general.string = wallet.address } label: {
                            Image(systemName: "doc.on.doc").foregroundColor(Nin.green)
                        }
                    }
                    if let a = wallet.address, let u = URL(string: "\(Config.chainExplorer)/address/\(a)") {
                        Link("View on explorer ↗", destination: u).font(Nin.font(12, .medium)).foregroundColor(Nin.green)
                    }
                }.ninCard()

                Button { showPhrase = true } label: {
                    Text("Reveal recovery phrase").font(Nin.font(13)).foregroundColor(Nin.muted)
                }
                if let status { Text(status).font(Nin.font(12)).foregroundColor(Nin.green).multilineTextAlignment(.center) }
            }
            .padding()
        }
        .task {
            if let a = wallet.address { _ = await app.linkWalletAddress(a) }
            await wallet.refresh()
        }
        .refreshable { await wallet.refresh() }
        .sheet(isPresented: $showSend) { NinSend(wallet: wallet) }
        .sheet(isPresented: $showReceive) { NinReceive(address: wallet.address ?? "") }
        .sheet(isPresented: $showPhrase) { NinPhrase(words: wallet.mnemonicWords()) }
    }

    private func assetRow(_ sym: String, _ sub: String, _ bal: Double, _ icon: String, _ grad: [Color]) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: grad, startPoint: .top, endPoint: .bottom)).frame(width: 42, height: 42)
                Image(systemName: icon).foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(sym).font(Nin.font(16, .bold)).foregroundColor(Nin.text)
                Text(sub).font(Nin.font(12)).foregroundColor(Nin.muted)
            }
            Spacer()
            Text(String(format: sym == "ETH" ? "%.5f" : "%.4f", bal)).font(Nin.font(15, .medium)).foregroundColor(Nin.text)
        }.ninCard()
    }

    private func ninAction(_ t: String, _ icon: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            VStack(spacing: 6) { Image(systemName: icon).font(.title3); Text(t).font(Nin.font(13, .medium)) }
                .frame(maxWidth: .infinity).padding(.vertical, 16).foregroundColor(Nin.text)
                .background(Nin.card).clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }
}

// MARK: - Sheets

private struct NinSend: View {
    @ObservedObject var wallet: NVPWallet
    @Environment(\.dismiss) private var dismiss
    @State private var to = ""
    @State private var amount = ""
    @State private var isNVP = true
    @State private var busy = false
    @State private var result: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("", selection: $isNVP) { Text("NVP").tag(true); Text("ETH").tag(false) }.pickerStyle(.segmented)
                    field("Recipient 0x…", $to)
                    field("Amount", $amount, decimal: true)
                    ninButton(busy ? "Sending…" : "Send", "paperplane.fill", enabled: !busy && !to.isEmpty && !amount.isEmpty) {
                        busy = true; result = nil
                        Task {
                            do { let tx = try await wallet.send(to: to, amount: amount, asset: isNVP ? .nvp : .eth)
                                 result = "Sent ✓ \(tx.prefix(12))…"; try? await Task.sleep(nanoseconds: 5_000_000_000); await wallet.refresh()
                            } catch { result = error.localizedDescription }
                            busy = false
                        }
                    }
                    if let result { Text(result).font(Nin.font(13)).foregroundColor(Nin.text) }
                }.padding()
            }
            .background(Nin.bg.ignoresSafeArea()).navigationTitle("Send").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
    private func field(_ p: String, _ b: Binding<String>, decimal: Bool = false) -> some View {
        TextField(p, text: b).textInputAutocapitalization(.never).autocorrectionDisabled()
            .keyboardType(decimal ? .decimalPad : .default).font(Nin.font(15))
            .padding().background(Nin.card).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct NinReceive: View {
    let address: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let img = qrImage(address) {
                    Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 220, height: 220).padding().background(Nin.card).clipShape(RoundedRectangle(cornerRadius: 20))
                }
                Text(address).font(.system(size: 12, design: .monospaced)).foregroundColor(Nin.muted)
                    .multilineTextAlignment(.center).padding(.horizontal)
                Button { UIPasteboard.general.string = address } label: {
                    Label("Copy address", systemImage: "doc.on.doc").font(Nin.font(15, .medium)).foregroundColor(Nin.green)
                }
                Text("Send NVP (Base Sepolia) here. Need gas? Use the Coinbase faucet for testnet ETH.")
                    .font(Nin.font(12)).foregroundColor(Nin.muted).multilineTextAlignment(.center).padding(.horizontal)
                Spacer()
            }.padding().frame(maxWidth: .infinity).background(Nin.bg.ignoresSafeArea())
            .navigationTitle("Receive").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

private struct NinPhrase: View {
    let words: [String]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Text("Never share this phrase. Anyone with it controls your NVP.")
                        .font(Nin.font(13)).foregroundColor(.red).multilineTextAlignment(.center)
                    phraseGrid(words)
                    Button { UIPasteboard.general.string = words.joined(separator: " ") } label: {
                        Label("Copy", systemImage: "doc.on.doc").font(Nin.font(13, .medium)).foregroundColor(Nin.green)
                    }
                }.padding()
            }
            .background(Nin.bg.ignoresSafeArea()).navigationTitle("Recovery phrase").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

// MARK: - shared helpers

private func phraseGrid(_ words: [String]) -> some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
        ForEach(Array(words.enumerated()), id: \.offset) { i, w in
            HStack(spacing: 4) {
                Text("\(i + 1)").font(Nin.font(11)).foregroundColor(Nin.muted)
                Text(w).font(Nin.font(14, .medium)).foregroundColor(Nin.text)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

private func ninButton(_ title: String, _ icon: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Label(title, systemImage: icon).font(Nin.font(16, .bold))
            .frame(maxWidth: .infinity).padding()
            .background(Nin.green).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 16))
    }.disabled(!enabled).opacity(enabled ? 1 : 0.5)
}

private extension View {
    func ninCard() -> some View {
        self.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

private func qrImage(_ string: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
    let ctx = CIContext()
    guard let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
    return UIImage(cgImage: cg)
}
