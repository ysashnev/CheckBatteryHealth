import AppKit
import Combine
import SwiftUI

@main
struct CheckBatteryHealthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Увесь інтерфейс — у рядку меню (AppDelegate); вікон у застосунку немає.
        Settings { EmptyView() }
    }
}

/// Іконка в рядку меню і спливне вікно. Замість SwiftUI MenuBarExtra — NSPopover:
/// він підлаштовує розмір під вміст в обидва боки (MenuBarExtra не зменшується).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = BluetoothManager()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
        }

        let host = NSHostingController(rootView: MenuContentView().environmentObject(manager))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        // objectWillChange приходить до зміни — оновлюємо на наступному циклі.
        cancellable = manager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
        updateStatusItem()

        LaunchAtLogin.enableOnFirstLaunch()
        Notifier.requestAuthorization()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if manager.isPoweredOn, !manager.isScanning { manager.startScan() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let status = MenuBarStatus(manager: manager)
        button.image = MenuBarIcon.image(level: status.lowestSoc, mode: status.mode,
                                         alert: status.isLow)
        button.title = " " + status.title
    }
}

/// Що показати в рядку меню. Іконка — найнижчий заряд серед підключених
/// акумуляторів і значок: ⚡ — заряджається, ↓ — розряджається.
struct MenuBarStatus {
    let manager: BluetoothManager

    private var readings: [BatteryReading] {
        manager.links.filter(\.isConnected).map(\.reading)
    }

    var title: String {
        let parts = readings.compactMap { reading -> String? in
            guard let soc = reading.soc else { return nil }
            var text = "\(Int(soc.rounded()))%"
            if manager.showTimeInMenuBar,
               let hours = reading.hoursToEmpty ?? reading.hoursToFull {
                text += " \(Fmt.duration(hours: hours))"
            }
            if manager.showPowerInMenuBar, reading.mode != .idle,
               let power = Fmt.power(reading.power) {
                text += " \(power)"
            }
            return text
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    var lowestSoc: Double? {
        readings.compactMap(\.soc).min()
    }

    /// Заряд нижче порогу попередження і акумулятор не заряджається.
    var isLow: Bool {
        readings.contains { manager.isLow($0) }
    }

    /// Розряд важливіший за заряд: якщо хоч один акумулятор розряджається — показуємо це.
    var mode: BatteryReading.Mode {
        let modes = readings.map(\.mode)
        if modes.contains(.discharging) { return .discharging }
        if modes.contains(.charging) { return .charging }
        return .idle
    }
}

enum MenuBarIcon {
    /// `alert` — низький заряд: іконка червона замість шаблонної (чорно-білої).
    static func image(level soc: Double?, mode: BatteryReading.Mode,
                      alert: Bool = false) -> NSImage {
        let badge: NSImage? = switch mode {
        case .charging: symbol("bolt.fill")
        case .discharging: symbol("arrow.down")
        case .idle: nil
        }

        let body = NSSize(width: 21, height: 15)
        let spacing: CGFloat = 1.5
        let badgeWidth = badge.map { $0.size.width + spacing } ?? 0
        let size = NSSize(width: body.width + badgeWidth, height: 16)

        let image = NSImage(size: size, flipped: false) { _ in
            (alert ? NSColor.systemRed : NSColor.black).set()
            drawAccumulator(in: NSRect(x: 0, y: (size.height - body.height) / 2,
                                       width: body.width, height: body.height),
                            level: soc.map { min(max($0 / 100, 0), 1) })
            if let badge {
                let badge = alert ? tinted(badge, .systemRed) : badge
                badge.draw(in: NSRect(x: body.width + spacing,
                                      y: (size.height - badge.size.height) / 2,
                                      width: badge.size.width, height: badge.size.height))
            }
            return true
        }
        image.isTemplate = !alert
        return image
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// Акумулятор: корпус, дві клеми зверху і заповнення знизу за рівнем заряду.
    private static func drawAccumulator(in rect: NSRect, level: Double?) {
        let line: CGFloat = 1.3
        let terminalHeight: CGFloat = 2.5
        let case_ = NSRect(x: rect.minX + line / 2, y: rect.minY + line / 2,
                           width: rect.width - line,
                           height: rect.height - terminalHeight - line)
        let outline = NSBezierPath(roundedRect: case_, xRadius: 2, yRadius: 2)
        outline.lineWidth = line
        outline.stroke()

        let terminalWidth: CGFloat = 4
        for x in [rect.minX + 3.5, rect.maxX - 3.5 - terminalWidth] {
            NSBezierPath(roundedRect: NSRect(x: x, y: case_.maxY, width: terminalWidth,
                                             height: terminalHeight + line / 2),
                         xRadius: 0.8, yRadius: 0.8).fill()
        }

        guard let level, level > 0 else { return }
        let inner = case_.insetBy(dx: line + 1, dy: line + 1)
        let fill = NSRect(x: inner.minX, y: inner.minY, width: inner.width,
                          height: max(inner.height * level, 1))
        NSBezierPath(roundedRect: fill, xRadius: 0.8, yRadius: 0.8).fill()
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
    }
}
