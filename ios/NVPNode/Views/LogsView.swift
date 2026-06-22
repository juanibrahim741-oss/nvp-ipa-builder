import SwiftUI
import UIKit

struct LogsView: View {
    @ObservedObject private var logs = LogStore.shared

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .info: return Theme.muted
        case .success: return Theme.green
        case .warn: return Theme.gold
        case .error: return Theme.red
        }
    }

    private let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if logs.entries.isEmpty {
                            Text("No activity yet. Turn the worker ON to see live logs.")
                                .foregroundColor(Theme.muted)
                                .padding(.top, 40)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(logs.entries) { e in
                            HStack(alignment: .top, spacing: 8) {
                                Text(timeFmt.string(from: e.time))
                                    .foregroundColor(Theme.muted)
                                Text(e.message)
                                    .foregroundColor(color(e.level))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .id(e.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: logs.entries.count) {
                    if let last = logs.entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            .background(Theme.bg)
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Copy all") { UIPasteboard.general.string = logs.text }
                        Button("Clear", role: .destructive) { logs.clear() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}
