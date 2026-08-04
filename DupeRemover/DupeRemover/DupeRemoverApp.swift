//
//  DupeRemoverApp.swift
//  Dupe Remover (iOS + macOS)
//
//  Finds duplicate and visually similar photos in your Photos library or in a
//  folder you pick, and moves the extras somewhere recoverable. Everything runs
//  on device.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct DupeRemoverApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Dupe Remover") {
                    AboutWindowController.shared.show()
                }
            }
        }
        #endif
    }
}

#if os(macOS)
// MARK: - About window
//
// iOS presents the same content as a sheet; on macOS it belongs in the app menu,
// which means a real window.

private final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: AboutContent().frame(width: 340).fixedSize(horizontal: false, vertical: true)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "About Dupe Remover"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
