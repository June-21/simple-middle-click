//
//  simple_middle_clickApp.swift
//  simple-middle-click
//
//  Created by june on 2026/5/9.
//

import AppKit
import ApplicationServices
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "wuqiyue.simple-middle-click", category: "app")
    private var statusItem: NSStatusItem?
    private var touchMonitor: ThreeFingerTapMonitor?
    private var accessibilityAuthorizationTimer: Timer?
    private var didRequestRestartAfterAuthorization = false
    private lazy var settingsController = SettingsController(onLanguageChanged: { [weak self] in
        self?.refreshLocalizedUI()
    })

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("Simple Middle Click did finish launching")
        log("Bundle path: \(Bundle.main.bundleURL.path)")
        NSApp.setActivationPolicy(.accessory)
        // System Settings uses the bundle icon when listing this app for Accessibility permission.
        NSApp.applicationIconImage = NSImage(named: "AppIconPreview")
        log("Activation policy set to accessory")

        installStatusItem()
        requestAccessibilityPermissionIfNeeded()
        startMiddleClickMonitor()
    }

    private func startMiddleClickMonitor() {
        guard let monitor = ThreeFingerTapMonitor(onTap: {
            MiddleMouse.click()
        }) else {
            log("Failed to initialize ThreeFingerTapMonitor")
            return
        }

        monitor.start()
        touchMonitor = monitor
        log("ThreeFingerTapMonitor started")
    }

    private func requestAccessibilityPermissionIfNeeded() {
        let trusted = AXIsProcessTrusted()
        log("Accessibility trusted: \(trusted)")
        guard !trusted else {
            return
        }

        showAccessibilityPermissionIntro()
    }

    private func showAccessibilityPermissionIntro() {
        let alert = NSAlert()
        alert.messageText = L10n.accessibilityTitle
        alert.informativeText = L10n.accessibilityMessage
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.confirm)
        alert.addButton(withTitle: L10n.later)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
            startAccessibilityAuthorizationMonitor()
        }
    }

    private func openAccessibilitySettings() {
        log("Opening Accessibility privacy settings")
        // Keep both URL schemes because Apple changed System Settings panes across macOS releases.
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]

        for urlString in urls {
            guard let url = URL(string: urlString), NSWorkspace.shared.open(url) else {
                continue
            }

            return
        }
    }

    private func startAccessibilityAuthorizationMonitor() {
        accessibilityAuthorizationTimer?.invalidate()
        accessibilityAuthorizationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else {
                return
            }

            timer.invalidate()
            self?.accessibilityAuthorizationTimer = nil
            self?.restartAppAfterAccessibilityAuthorization()
        }
    }

    private func restartAppAfterAccessibilityAuthorization() {
        guard !didRequestRestartAfterAuthorization else {
            return
        }

        didRequestRestartAfterAuthorization = true
        log("Accessibility authorization detected; restarting app")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]

        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            log("Failed to restart app after authorization: \(error.localizedDescription)")
        }
    }

    private func installStatusItem() {
        log("Installing status item")
        // Use a template SF Symbol so the menu bar icon adapts to light and dark menu bars.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = statusBarImage()
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = L10n.appName
            log("Status item button configured with title: \(button.title), has image: \(button.image != nil)")
        } else {
            log("Status item button is nil")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L10n.settings, action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L10n.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
        log("Status item installed")
    }

    private func refreshLocalizedUI() {
        // Rebuild visible UI after the in-app language setting changes.
        statusItem?.button?.toolTip = L10n.appName
        if let menu = statusItem?.menu {
            menu.items.first?.title = L10n.settings
            menu.items.last?.title = L10n.quit
        }
    }

    private func statusBarImage() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            log("AppIcon.icns missing; loaded fallback template symbol")
            let fallback = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: L10n.appName)
            fallback?.isTemplate = true
            return fallback
        }

        let image = NSImage(contentsOf: url)
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = false
        log("Loaded AppIcon.icns for status bar")
        return image
    }

    @objc private func showSettings() {
        log("Settings menu item clicked")
        settingsController.show()
        log("Settings window shown")
    }

    private func log(_ message: String) {
        let line = "[SimpleMiddleClick] \(message)"
        logger.notice("\(line, privacy: .public)")
        NSLog("%@", line)
        print(line)
        if let data = "\(line)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
