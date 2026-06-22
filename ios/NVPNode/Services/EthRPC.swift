import Foundation

/// Minimal Ethereum JSON-RPC client + numeric helpers for the NVP wallet.
/// Talks to Base Sepolia over HTTPS (Config.chainRpcUrl).
enum EthRPC {
    struct RPCError: LocalizedError { let message: String; var errorDescription: String? { message } }

    private static func call(_ method: String, _ params: [Any]) async throws -> Any {
        guard let url = URL(string: Config.chainRpcUrl) else { throw RPCError(message: "Bad RPC URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let err = obj["error"] as? [String: Any] {
            throw RPCError(message: (err["message"] as? String) ?? "RPC error")
        }
        guard let result = obj["result"] else { throw RPCError(message: "No result") }
        return result
    }

    private static func hexResult(_ method: String, _ params: [Any]) async throws -> String {
        guard let s = try await call(method, params) as? String else { throw RPCError(message: "Bad result") }
        return s
    }

    // MARK: reads

    /// Native ETH balance (wei) as a hex string.
    static func getBalanceHex(_ address: String) async throws -> String {
        try await hexResult("eth_getBalance", [address, "latest"])
    }

    /// ERC-20 balanceOf via eth_call. Returns hex (wei).
    static func erc20BalanceHex(contract: String, address: String) async throws -> String {
        // selector balanceOf(address) = 0x70a08231 + 32-byte padded address
        let addr = address.lowercased().replacingOccurrences(of: "0x", with: "")
        let data = "0x70a08231" + String(repeating: "0", count: 64 - addr.count) + addr
        return try await hexResult("eth_call", [["to": contract, "data": data], "latest"])
    }

    static func transactionCount(_ address: String) async throws -> UInt64 {
        Hex.toUInt64(try await hexResult("eth_getTransactionCount", [address, "pending"]))
    }

    static func gasPriceWei() async throws -> UInt64 {
        Hex.toUInt64(try await hexResult("eth_gasPrice", []))
    }

    static func sendRawTransaction(_ rawHex: String) async throws -> String {
        try await hexResult("eth_sendRawTransaction", [rawHex])
    }
}

/// Hex + big-integer (decimal-string) helpers. 256-bit values exceed UInt64, so
/// amounts are handled as decimal strings → minimal big-endian bytes.
enum Hex {
    static func toUInt64(_ hex: String) -> UInt64 {
        UInt64(hex.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
    }

    /// Hex wei → human Double (for display only; precision-lossy but fine for UI).
    static func weiHexToDouble(_ hex: String) -> Double {
        let s = hex.replacingOccurrences(of: "0x", with: "")
        if s.isEmpty { return 0 }
        // Parse via Decimal to avoid UInt64 overflow on 256-bit values.
        var acc = Decimal(0)
        let sixteen = Decimal(16)
        for ch in s {
            guard let d = ch.hexDigitValue else { continue }
            acc = acc * sixteen + Decimal(d)
        }
        return NSDecimalNumber(decimal: acc).doubleValue / 1e18
    }

    /// UInt64 → minimal big-endian Data (empty stays single 0 byte).
    static func minimalBE(_ v: UInt64) -> Data {
        if v == 0 { return Data([0]) }
        var bytes: [UInt8] = []
        var x = v
        while x > 0 { bytes.insert(UInt8(x & 0xff), at: 0); x >>= 8 }
        return Data(bytes)
    }

    /// Human token amount string (e.g. "2.5") → wei decimal-digit string.
    static func amountToWeiDigits(_ amount: String, decimals: Int = 18) -> String? {
        let parts = amount.trimmingCharacters(in: .whitespaces).split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = String(parts.first ?? "0").filter { $0.isNumber }
        var frac = parts.count > 1 ? String(parts[1]).filter { $0.isNumber } : ""
        if frac.count > decimals { frac = String(frac.prefix(decimals)) }
        frac += String(repeating: "0", count: decimals - frac.count)
        let digits = (intPart + frac).drop(while: { $0 == "0" })
        let s = String(digits)
        return s.isEmpty ? "0" : s
    }

    /// Decimal-digit string → minimal big-endian Data (validated against Python ref).
    static func decimalDigitsToBE(_ digits: String) -> Data {
        var b: [UInt8] = [0]
        for ch in digits {
            guard let d = ch.wholeNumberValue, d >= 0, d <= 9 else { continue }
            // b = b * 10
            var carry = 0
            for k in stride(from: b.count - 1, through: 0, by: -1) {
                let v = Int(b[k]) * 10 + carry
                b[k] = UInt8(v & 0xff)
                carry = v >> 8
            }
            while carry > 0 { b.insert(UInt8(carry & 0xff), at: 0); carry >>= 8 }
            // b = b + d
            carry = d
            for k in stride(from: b.count - 1, through: 0, by: -1) {
                let v = Int(b[k]) + carry
                b[k] = UInt8(v & 0xff)
                carry = v >> 8
                if carry == 0 { break }
            }
            while carry > 0 { b.insert(UInt8(carry & 0xff), at: 0); carry >>= 8 }
        }
        while b.count > 1 && b[0] == 0 { b.removeFirst() }
        return Data(b)
    }

    static func toHexString(_ data: Data) -> String {
        "0x" + data.map { String(format: "%02x", $0) }.joined()
    }
}
