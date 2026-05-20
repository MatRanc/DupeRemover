//
//  PhotoDuplicateFinderApp.swift
//  PhotoDuplicateFinder
//
//  Created by Mathieu Rancourt on 2026-05-03.
//

import SwiftUI
import AppKit

@main
struct PhotoDuplicateFinderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Dupe Remover") {
                    showAboutPanel()
                }
            }
        }
    }
}

private func showAboutPanel() {
    let body = NSMutableAttributedString()
    let base: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.labelColor
    ]

    body.append(NSAttributedString(string: "Duplicate Photo Finder and Remover\n\n", attributes: base))

    body.append(NSAttributedString(string: "Source: ", attributes: base))
    body.append(NSAttributedString(
        string: "github.com/MatRanc/PhotoDuplicateFinder\n\n",
        attributes: base.merging([.link: URL(string: "https://github.com/MatRanc/PhotoDuplicateFinder")!]) { $1 }
    ))

    body.append(NSAttributedString(string: "App icon: ", attributes: base))
    body.append(NSAttributedString(
        string: "Flaticon — duplicate icon",
        attributes: base.merging([.link: URL(string: "https://www.flaticon.com/free-icon/duplicate_3991529")!]) { $1 }
    ))

    NSApp.orderFrontStandardAboutPanel(options: [
        NSApplication.AboutPanelOptionKey.credits: body
    ])
}
