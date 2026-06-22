import Foundation
import UIKit

/// Tracks the runtime conditions that gate worker activity (docs/01 + docs/04):
/// foreground only, recommend charging, throttle on heat.
@MainActor
final class DeviceState: ObservableObject {
    @Published var isForeground = true
    @Published var isCharging = false
    @Published var thermal: ProcessInfo.ThermalState = .nominal

    /// True when it's safe + sensible for the worker to run. We only stop on a
    /// CRITICAL thermal state (not "serious"), so normal warmth doesn't pause work.
    var canWork: Bool { isForeground && thermal != .critical }

    private var observers: [NSObjectProtocol] = []

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()

        let nc = NotificationCenter.default
        func observe(_ name: Notification.Name, _ block: @escaping @MainActor () -> Void) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { block() }
            })
        }
        observe(UIDevice.batteryStateDidChangeNotification) { [weak self] in self?.refresh() }
        observe(ProcessInfo.thermalStateDidChangeNotification) { [weak self] in self?.refresh() }
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] in self?.isForeground = false }
        observe(UIApplication.willEnterForegroundNotification) { [weak self] in
            self?.isForeground = true
            self?.refresh()
        }
    }

    func refresh() {
        let state = UIDevice.current.batteryState
        isCharging = (state == .charging || state == .full)
        thermal = ProcessInfo.processInfo.thermalState
    }

    var statusBanner: (text: String, color: String) {
        if !isForeground { return ("Paused — app in background", "red") }
        if thermal == .critical { return ("Paused — device too hot, cooling down", "red") }
        if isCharging { return ("Active — foreground & charging", "green") }
        return ("Active on battery — plug in to keep earning", "gold")
    }
}
