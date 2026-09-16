import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)     // keeps it out of the Dock and Cmd-Tab

let delegate = AppDelegate()            // top-level bindings in main.swift are globals, so this holds a strong reference
app.delegate = delegate
app.run()
