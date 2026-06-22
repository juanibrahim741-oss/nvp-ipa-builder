import Foundation

enum Format {
    /// USD with extra precision for tiny amounts (per-job earnings are small).
    static func usd(_ n: Double) -> String {
        if n != 0 && abs(n) < 0.01 { return String(format: "$%.6f", n) }
        return String(format: "$%.2f", n)
    }
}
