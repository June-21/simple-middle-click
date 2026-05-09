//
//  SettingsController.swift
//  simple-middle-click
//
//  Created by june on 2026/5/9.
//

import AppKit
import ServiceManagement

final class SettingsController: NSObject {
    private let onLanguageChanged: () -> Void
    private var settingsWindow: NSWindow?
    private var settingsWindowDelegate: SettingsWindowDelegate?

    init(onLanguageChanged: @escaping () -> Void) {
        self.onLanguageChanged = onLanguageChanged
    }

    func show() {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }

        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 156),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.settings
        window.isReleasedWhenClosed = false
        window.contentView = makeSettingsContentView()

        let delegate = SettingsWindowDelegate { [weak self] in
            self?.settingsWindow = nil
            self?.settingsWindowDelegate = nil
        }
        window.delegate = delegate
        settingsWindowDelegate = delegate
        return window
    }

    private func makeSettingsContentView() -> NSView {
        // The settings window is intentionally minimal: app icon plus compact controls.
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 156))
        let iconView = NSImageView()
        let languageLabel = NSTextField(labelWithString: L10n.language)
        let languagePopUp = NSPopUpButton()
        let launchAtLoginButton = NSButton(checkboxWithTitle: L10n.launchAtLogin, target: self, action: #selector(launchAtLoginChanged(_:)))

        iconView.image = NSImage(named: "AppIconPreview")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        languageLabel.font = .systemFont(ofSize: 13)

        for language in AppLanguage.allCases {
            let item = NSMenuItem(title: language.localizedName, action: nil, keyEquivalent: "")
            item.representedObject = language.rawValue
            languagePopUp.menu?.addItem(item)
        }
        languagePopUp.selectItem(withTitle: AppLanguage.current.localizedName)
        languagePopUp.target = self
        languagePopUp.action = #selector(languageSelectionChanged(_:))
        launchAtLoginButton.state = LoginItemService.isEnabled ? .on : .off

        for view in [iconView, languageLabel, languagePopUp, launchAtLoginButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),

            languageLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 18),
            languageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            languageLabel.bottomAnchor.constraint(equalTo: languagePopUp.topAnchor, constant: -8),

            languagePopUp.leadingAnchor.constraint(equalTo: languageLabel.leadingAnchor),
            languagePopUp.trailingAnchor.constraint(equalTo: languageLabel.trailingAnchor),
            languagePopUp.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -4),

            launchAtLoginButton.leadingAnchor.constraint(equalTo: languageLabel.leadingAnchor),
            launchAtLoginButton.trailingAnchor.constraint(equalTo: languageLabel.trailingAnchor),
            launchAtLoginButton.topAnchor.constraint(equalTo: languagePopUp.bottomAnchor, constant: 16)
        ])

        return contentView
    }

    @objc private func languageSelectionChanged(_ sender: NSPopUpButton) {
        guard
            let languageID = sender.selectedItem?.representedObject as? String,
            let language = AppLanguage(rawValue: languageID)
        else {
            return
        }

        AppLanguage.current = language
        refreshLocalizedUI()
        onLanguageChanged()
        DebugLog.write("[settings] Language changed to \(language.rawValue)")
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let shouldEnable = sender.state == .on
        do {
            try LoginItemService.setEnabled(shouldEnable)
        } catch {
            sender.state = LoginItemService.isEnabled ? .on : .off
            DebugLog.write("[settings] Failed to update launch at login: \(error.localizedDescription)")
        }
    }

    private func refreshLocalizedUI() {
        settingsWindow?.title = L10n.settings
        settingsWindow?.contentView = makeSettingsContentView()
    }
}

enum L10n {
    static var appName: String { text("app.name") }
    static var settings: String { text("menu.settings") }
    static var quit: String { text("menu.quit") }
    static var language: String { text("settings.language") }
    static var launchAtLogin: String { text("settings.launch_at_login") }
    static var accessibilityTitle: String { text("accessibility.title") }
    static var accessibilityMessage: String { text("accessibility.message") }
    static var confirm: String { text("button.confirm") }
    static var later: String { text("button.later") }
    static var english: String { text("language.english") }
    static var simplifiedChinese: String { text("language.simplified_chinese") }
    static var japanese: String { text("language.japanese") }

    private static func text(_ key: String) -> String {
        // Resolve strings from the user-selected language instead of relying on system language.
        guard
            let path = Bundle.main.path(forResource: AppLanguage.current.rawValue, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return NSLocalizedString(key, comment: "")
        }

        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}

private enum LoginItemService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"

    private static let defaultsKey = "selectedLanguage"

    static var current: AppLanguage {
        get {
            // English is the product default when the user has not selected a language.
            if
                let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
                let language = AppLanguage(rawValue: rawValue)
            {
                return language
            }

            return .english
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var localizedName: String {
        switch self {
        case .english:
            return L10n.english
        case .simplifiedChinese:
            return L10n.simplifiedChinese
        case .japanese:
            return L10n.japanese
        }
    }
}

private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // LSUIElement apps do not have a normal app menu, so handle Command-W at the window level.
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return
        }

        super.keyDown(with: event)
    }
}

private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
