import Foundation
import WalletCore

/// Real non-custodial NVP wallet (Base Sepolia testnet).
///
/// Keys come from a BIP39 mnemonic via Trust Wallet Core (the same crypto core
/// Gem Wallet uses). The mnemonic is stored in the iOS Keychain. Balances are
/// read over JSON-RPC; sends are signed locally (WalletCore) and broadcast via
/// eth_sendRawTransaction. NVP is an ERC-20; ETH is the gas token.
@MainActor
final class NVPWallet: ObservableObject {
    static let mnemonicKey = "nvp_mnemonic"

    @Published var address: String?
    @Published var ethBalance: Double = 0
    @Published var nvpBalance: Double = 0
    @Published var busy = false
    @Published var lastError: String?

    /// A freshly generated phrase awaiting the user's "I saved it" confirmation —
    /// not persisted yet, so the view stays on the backup screen.
    private var pendingMnemonic: String?

    var hasWallet: Bool { KeychainStore.get(Self.mnemonicKey) != nil }

    init() { loadAddress() }

    private func hdWallet() -> HDWallet? {
        guard let phrase = KeychainStore.get(Self.mnemonicKey) else { return nil }
        return HDWallet(mnemonic: phrase, passphrase: "")
    }

    private func loadAddress() {
        address = hdWallet()?.getAddressForCoin(coin: .ethereum)
    }

    /// Generate a new wallet and return its 12 words — but DON'T persist yet
    /// (call confirmCreate() once the user has backed it up).
    func create() -> [String]? {
        guard let wallet = HDWallet(strength: 128, passphrase: "") else { return nil }
        pendingMnemonic = wallet.mnemonic
        return wallet.mnemonic.split(separator: " ").map(String.init)
    }

    /// Persist the pending wallet after the user confirms they saved the phrase.
    func confirmCreate() {
        guard let m = pendingMnemonic else { return }
        KeychainStore.set(m, for: Self.mnemonicKey)
        pendingMnemonic = nil
        loadAddress()
    }

    /// Import an existing wallet from a mnemonic. Returns false if invalid.
    func importMnemonic(_ phrase: String) -> Bool {
        let clean = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
        guard Mnemonic.isValid(mnemonic: clean), HDWallet(mnemonic: clean, passphrase: "") != nil else { return false }
        KeychainStore.set(clean, for: Self.mnemonicKey)
        loadAddress()
        return true
    }

    /// The recovery phrase words (for the backup screen).
    func mnemonicWords() -> [String] {
        (KeychainStore.get(Self.mnemonicKey) ?? "").split(separator: " ").map(String.init)
    }

    func deleteWallet() {
        KeychainStore.delete(Self.mnemonicKey)
        address = nil; ethBalance = 0; nvpBalance = 0
    }

    func refresh() async {
        guard let addr = address else { return }
        do {
            async let eth = EthRPC.getBalanceHex(addr)
            async let nvp = EthRPC.erc20BalanceHex(contract: Config.nvpContractAddress, address: addr)
            ethBalance = Hex.weiHexToDouble(try await eth)
            nvpBalance = Hex.weiHexToDouble(try await nvp)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    enum Asset { case nvp, eth }

    /// Sign + broadcast a transfer. Returns the tx hash.
    func send(to recipient: String, amount: String, asset: Asset) async throws -> String {
        guard let wallet = hdWallet(), let from = address else { throw EthRPC.RPCError(message: "No wallet") }
        guard let digits = Hex.amountToWeiDigits(amount), digits != "0" else { throw EthRPC.RPCError(message: "Invalid amount") }
        let amountBE = Hex.decimalDigitsToBE(digits)
        let key = wallet.getKeyForCoin(coin: .ethereum)

        let nonce = try await EthRPC.transactionCount(from)
        let gp = try await EthRPC.gasPriceWei()
        let priority: UInt64 = 1_000_000_000 // 1 gwei tip
        let maxFee = max(gp &* 2, priority &+ 1_000_000_000)
        let isERC20 = (asset == .nvp)
        let gasLimit: UInt64 = isERC20 ? 120_000 : 21_000

        let input = EthereumSigningInput.with {
            $0.chainID = Hex.minimalBE(UInt64(Config.chainId))
            $0.nonce = Hex.minimalBE(nonce)
            $0.txMode = .enveloped
            $0.maxFeePerGas = Hex.minimalBE(maxFee)
            $0.maxInclusionFeePerGas = Hex.minimalBE(priority)
            $0.gasLimit = Hex.minimalBE(gasLimit)
            $0.privateKey = key.data
            if isERC20 {
                $0.toAddress = Config.nvpContractAddress
                $0.transaction = EthereumTransaction.with {
                    $0.erc20Transfer = EthereumTransaction.ERC20Transfer.with {
                        $0.to = recipient
                        $0.amount = amountBE
                    }
                }
            } else {
                $0.toAddress = recipient
                $0.transaction = EthereumTransaction.with {
                    $0.transfer = EthereumTransaction.Transfer.with { $0.amount = amountBE }
                }
            }
        }

        let output: EthereumSigningOutput = AnySigner.sign(input: input, coin: .ethereum)
        guard !output.encoded.isEmpty else { throw EthRPC.RPCError(message: "Signing failed") }
        let raw = Hex.toHexString(output.encoded)
        return try await EthRPC.sendRawTransaction(raw)
    }
}
