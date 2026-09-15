import AppKit
import SwiftUI

/// Settings and first-run windows. An accessory app has no Dock icon, so both have
/// to explicitly pull themselves forward.
final class AppWindows {

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func showSettings(store: SettingsStore, onTestDrop: @escaping () -> Void) {
        if let w = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "DiscoBreak"
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(rootView: SettingsView(store: store, onTestDrop: onTestDrop))
        settingsWindow = w

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Shown once, ever. This is the fix for "I didn't know how to quit it" —
    /// the MVP gave no hint that the menu bar item existed.
    func showOnboardingIfNeeded() {
        let key = "DiscoBreak.hasOnboarded"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Welcome to DiscoBreak"
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(rootView: OnboardingView())
        onboardingWindow = w

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

private struct OnboardingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: MenuBarIcon.make(size: 34))
                VStack(alignment: .leading) {
                    Text("DiscoBreak").font(.title2).bold()
                    Text("A five second party, on demand.").foregroundStyle(.secondary)
                }
            }

            Divider()

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hover your notch").bold()
                    Text("Move the pointer to the top centre of the screen. The ball drops and the music starts. Move away and it all goes back up.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } icon: { Image(systemName: "cursorarrow.rays") }

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Everything else lives in the menu bar").bold()
                    Text("Look for the mirror ball icon up there. Settings, a test drop, and quitting are all in that menu.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } icon: { Image(systemName: "menubar.arrow.up.rectangle") }

            Spacer()
        }
        .padding(24)
        .frame(width: 420, height: 300, alignment: .topLeading)
    }
}
