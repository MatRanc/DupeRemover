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
                    AboutWindowController.shared.show()
                }
            }
        }
    }
}

// MARK: - About window

private final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: AboutView())
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

private struct AboutView: View {
    private let appName = "Dupe Remover"
    private let appStoreID = "6770612666"
    private let feedbackEmail = "matranc03@gmail.com"

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text(appName)
                .font(.system(size: 18, weight: .semibold))

            Text(version)
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack(spacing: 4) {
                Text("Made in")
                Text("🇨🇦")
                Text("with")
                Text("❤️")
            }
            .font(.system(size: 11))

            VStack(spacing: 4) {
                Link("Source on GitHub",
                     destination: URL(string: "https://github.com/MatRanc/PhotoDuplicateFinder")!)
                Link("App icon — Flaticon",
                     destination: URL(string: "https://www.flaticon.com/free-icon/duplicate_3991529")!)
            }
            .font(.system(size: 11))

            HStack(spacing: 10) {
                Button("Rate App") { rateApp() }
                Button("Send Feedback") { sendFeedback() }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 320)
    }

    private func rateApp() {
        let url = URL(string: "macappstore://apps.apple.com/app/id\(appStoreID)?action=write-review")!
        NSWorkspace.shared.open(url)
    }

    private func sendFeedback() {
        let subject = "\(appName) Feedback"
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        let url = URL(string: "mailto:\(feedbackEmail)?subject=\(encoded)")!
        NSWorkspace.shared.open(url)
    }
}
