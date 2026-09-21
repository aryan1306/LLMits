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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindowController: NSWindowController?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        configurePopover()
        configureStatusItem()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        Task { await model.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        model.stop()
    }

    @objc private func didWake() {
        model.refreshAfterWake()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 420)
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))
    }

    func popoverDidShow(_ notification: Notification) {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.popover.contentViewController?.view.window {
                self.popover.performClose(nil)
            }
            return event
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
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

    private func showSettings() {
        popover.performClose(nil)

        if settingsWindowController == nil {
            let contentView = SettingsView(model: model)
                .frame(width: 560, height: 500)
            let window = NSWindow(contentViewController: NSHostingController(rootView: contentView))
            window.title = "LLMits Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }
}
