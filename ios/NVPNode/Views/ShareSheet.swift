import SwiftUI
import UIKit

/// Bridges UIActivityViewController so we can share/save a file (recovery key).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Write the recovery text to a temporary .txt file and return its URL (so the
/// share sheet offers "Save to Files").
func writeRecoveryFile(_ contents: String) -> URL? {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nvp-recovery-key.txt")
    do {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    } catch {
        return nil
    }
}
