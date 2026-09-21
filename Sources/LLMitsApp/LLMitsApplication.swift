import AppKit
import SwiftUI
import LLMitsCore

@main
struct LLMitsApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model)
                .frame(width: 560, height: 500)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configurePopover()
        configureStatusItem()
        Task { await model.start() }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 420)
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp])
        item.button?.toolTip = "LLMits quota usage"
        statusItem = item
        updateStatusTitle()

        model.onStatusChange = { [weak self] in self?.updateStatusTitle() }
    }

    private func updateStatusTitle() {
        statusItem?.button?.title = model.statusTitle
        statusItem?.button?.setAccessibilityLabel("LLMits, \(model.statusAccessibilityLabel)")
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            Task { await model.refreshIfStale() }
        }
    }
}
