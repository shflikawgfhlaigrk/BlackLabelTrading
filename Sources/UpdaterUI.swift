// Black Label Trading — updater UI + self-replace (AppKit; runs only on the Dev-ID build).
//
// Separated from Updater.swift so the pure update logic stays headless + unit-tested. This file owns
// the user-facing dialog ("Update available → Install / Later"), the launch/daily/menu triggers, and
// the detached helper that swaps the bundle and relaunches after the app quits.
import AppKit

@MainActor
enum UpdaterUI {

    // MARK: Triggers

    /// "Check for Updates…" menu action. Always reports something (update prompt OR "up to date" OR error).
    static func checkInteractively() {
        Task {
            do {
                if let m = try await Updater.checkForUpdate() {
                    presentPrompt(m)
                } else {
                    info(title: "You're up to date",
                         body: "Black Label Trading \(Updater.currentVersionString()) is the latest version.")
                }
            } catch {
                info(title: "Couldn't check for updates",
                     body: error.localizedDescription)
            }
        }
    }

    /// Silent background check (on launch + daily). Only surfaces UI if an update is actually available.
    static func checkInBackgroundIfDue() {
        guard Updater.dueForBackgroundCheck() else { return }
        Task {
            if let m = try? await Updater.checkForUpdate() { presentPrompt(m) }
        }
    }

    // MARK: Dialog

    static func presentPrompt(_ m: UpdateManifest) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = "Update available — \(m.latestVersion ?? "build \(m.latestBuild)")"
        a.informativeText = (m.releaseNotes?.isEmpty == false ? m.releaseNotes! : "A new version of Black Label Trading is ready to install.")
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { runInstall(m) }
    }

    // MARK: Install flow

    private static func runInstall(_ m: UpdateManifest) {
        // Lightweight progress alert (modeless) while we download + verify.
        let progress = NSAlert()
        progress.messageText = "Updating…"
        progress.informativeText = "Downloading and verifying the new version. The app will relaunch."
        let win = progress.window
        win.makeKeyAndOrderFront(nil)

        Task {
            do {
                let stagedApp = try await Updater.stage(m)
                win.orderOut(nil)
                try performSwapAndRelaunch(stagedApp: stagedApp)
                // performSwapAndRelaunch terminates the app; control should not return.
            } catch {
                win.orderOut(nil)
                info(title: "Update not installed", body: "Nothing on your Mac was changed.\n\n\(error.localizedDescription)")
            }
        }
    }

    /// Writes a detached helper that waits for THIS process to exit, atomically swaps the installed
    /// bundle with the verified staged build, and relaunches it. Then quits the app.
    /// Requires the non-sandboxed Dev-ID build (sandbox blocks the helper + the write to the install path).
    static func performSwapAndRelaunch(stagedApp: URL,
                                       installedApp: URL = Bundle.main.bundleURL) throws {
        let installed = installedApp.path
        let staged = stagedApp.path
        let backup = installed + ".old"
        let pid = ProcessInfo.processInfo.processIdentifier

        // The helper is intentionally tiny + dependency-free. Double-quote every path (bundle names
        // contain spaces). On any failure it restores the backup so the user is never left with no app.
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(backup)"
        mv "\(installed)" "\(backup)" || exit 1
        if ! mv "\(staged)" "\(installed)"; then
          mv "\(backup)" "\(installed)"
          exit 1
        fi
        rm -rf "\(backup)"
        xattr -dr com.apple.quarantine "\(installed)" 2>/dev/null
        open "\(installed)"
        """

        let helper = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bltd-update-helper-\(UUID().uuidString).sh")
        do {
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        } catch {
            throw UpdaterError.install("couldn't write installer helper: \(error.localizedDescription)")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [helper.path]
        do { try p.run() } catch { throw UpdaterError.install("couldn't launch installer helper: \(error.localizedDescription)") }

        // Hand off to the helper and quit so it can replace us.
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    static func info(title: String, body: String) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
