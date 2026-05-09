//
//  main.swift
//  simple-middle-click
//
//  Created by june on 2026/5/9.
//

import AppKit

private func bootLog(_ message: String) {
    let line = "[SimpleMiddleClick][main] \(message)"
    NSLog("%@", line)
    print(line)
    if let data = "\(line)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private let appDelegate = AppDelegate()
private let application = NSApplication.shared

bootLog("main.swift started")
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
bootLog("delegate assigned; entering NSApplication.run")
application.run()
