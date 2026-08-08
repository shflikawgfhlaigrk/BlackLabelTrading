// Black Label Trading — updater UI + self-replace (AppKit; runs only on the Dev-ID build).
//
// Separated from Updater.swift so the pure update logic stays headless + unit-tested. This file owns
// the user-facing dialog ("Update available → Install / Later"), the launch/daily/menu triggers, and
// the detached helper that swaps the bundle and relaunches after the app quits.
import AppKit
import CoreFoundation
import Darwin

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
        scheduleDeferredBackupCleanup()
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
                try performSwapAndRelaunch(stagedApp: stagedApp, manifest: m)
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
                                       manifest: UpdateManifest,
                                       installedApp: URL = Bundle.main.bundleURL) throws {
        // Re-check immediately before handoff so a direct caller cannot bypass stage(), and so a
        // staged bundle modified between download and the click fails before the current app exits.
        try Updater.validateInstallCandidate(manifest, currentBuild: Updater.currentBuild())
        try Updater.verifyDistribution(appURL: stagedApp, against: manifest)

        let installed = installedApp.path
        let staged = stagedApp.path
        let backup = installed + ".update-backup-\(UUID().uuidString)"
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                                 in: .userDomainMask).first else {
            throw UpdaterError.install("couldn't locate Application Support")
        }
        let support = applicationSupport.appendingPathComponent("Black Label Trading",
                                                                 isDirectory: true).path
        let configuredBackend = FeedClient.configuredBaseURL()
        let recoveryBackendMode: String
        let recoveryBackendPort: Int
        if let localPort = FeedClient.bundledBackendPort(for: configuredBackend) {
            recoveryBackendMode = "bundled"
            recoveryBackendPort = localPort
        } else {
            recoveryBackendMode = "external"
            recoveryBackendPort = 0
        }

        // Paths are process arguments, never interpolated into shell source. After the move the helper
        // repeats the identity, signature, Gatekeeper, and staple checks at the final path. Quarantine
        // is deliberately preserved; there is no xattr deletion anywhere in the update path.
        let script = """
        #!/bin/sh
        set -u
        pid="$1"
        installed="$2"
        staged="$3"
        backup="$4"
        expected_bundle_id="$5"
        expected_product="$6"
        expected_build="$7"
        expected_team="$8"
        expected_executable="$9"
        support="${10}"
        expected_backend_mode="${11}"
        expected_backend_port="${12}"
        case "$expected_backend_mode" in
          bundled)
            case "$expected_backend_port" in
              ""|*[!0-9]*) exit 2 ;;
            esac
            [ "$expected_backend_port" -ge 1 ] && [ "$expected_backend_port" -le 65535 ] || exit 2
            teardown_port="$expected_backend_port"
            ;;
          external)
            [ "$expected_backend_port" = "0" ] || exit 2
            teardown_port=8793
            ;;
          *) exit 2 ;;
        esac
        backup_active=0
        app_waiter=""
        marker_active=0
        watchdog_pid=""
        state=""
        pending="$support/update-backup.pending"

        mark_state() {
          [ -n "$state" ] || return 0
          if ! printf '%s\n' "$1" >"$state.tmp.$$" ||
             ! /bin/mv "$state.tmp.$$" "$state"; then
            /bin/rm -f "$state.tmp.$$"
            return 1
          fi
        }

        clear_pending_if_ours() {
          if [ "$marker_active" -eq 1 ]; then
            /bin/rm -f "$pending"
            marker_active=0
          fi
          /bin/rm -f "$pending.tmp.$$"
        }

        waiter_is_running() {
          [ -n "$app_waiter" ] || return 1
          /bin/kill -0 "$app_waiter" 2>/dev/null || return 1
          waiter_state="$(/bin/ps -p "$app_waiter" -o stat= 2>/dev/null || true)"
          case "$waiter_state" in
            *Z*) return 1 ;;
          esac
          [ -n "$waiter_state" ]
        }

        rollback() {
          if [ "$backup_active" -eq 1 ]; then
            if waiter_is_running; then
              /usr/bin/osascript -e "tell application id \\"$expected_bundle_id\\" to quit" >/dev/null 2>&1 || true
              for _ in 1 2 3 4 5; do
                waiter_is_running || break
                /bin/sleep 1
              done
              if waiter_is_running; then
                /bin/rm -f "$0"
                exit 2
              fi
            fi
            if [ -n "$app_waiter" ]; then
              wait "$app_waiter" 2>/dev/null || true
            fi
            app_waiter=""
            new_backend="$installed/Contents/Resources/backend"
            if [ -f "$new_backend/launch-backend.sh" ] && [ -x "$new_backend/python3" ]; then
              if ! /usr/bin/env "BLTD_SUPPORT_DIR=$support" "BLTD_PYTHON=$new_backend/python3" "BLTD_BUILD=$expected_build" "BLTD_PORT=$teardown_port" "BLTD_OWNED_BACKEND_DIR=$new_backend" /bin/bash "$new_backend/launch-backend.sh" --stop-owned >>"$support/update-helper.log" 2>&1; then
                /bin/rm -f "$0"
                exit 2
              fi
            fi
            /bin/rm -rf "$installed"
            if ! /bin/mv "$backup" "$installed"; then
              /bin/rm -f "$0"
              exit 2
            fi
          fi
          clear_pending_if_ours
          mark_state rolled-back || true
          /usr/bin/open "$installed" >/dev/null 2>&1 || true
          /bin/rm -f "$0"
          exit 1
        }
        trap rollback HUP INT TERM

        while /bin/kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.2; done
        staged_backend="$staged/Contents/Resources/backend"
        /bin/mkdir -p "$support" || rollback
        [ -x "$staged_backend/python3" ] || rollback
        [ -f "$staged_backend/launch-backend.sh" ] || rollback
        if ! /usr/bin/env "BLTD_SUPPORT_DIR=$support" "BLTD_PYTHON=$staged_backend/python3" "BLTD_BUILD=$expected_build" "BLTD_PORT=$teardown_port" "BLTD_OWNED_BACKEND_DIR=$installed/Contents/Resources/backend" /bin/bash "$staged_backend/launch-backend.sh" --stop-owned >>"$support/update-helper.log" 2>&1; then
          rollback
        fi
        [ ! -e "$pending" ] || rollback
        state="$support/update-helper.state.$$"
        mark_state pending || rollback

        # A second detached process owns transaction recovery if this helper is killed without
        # running its traps. It never commits an update; it only observes our terminal state or
        # restores the exact sibling backup after our PID disappears.
        /usr/bin/nohup /bin/sh -c '
          parent="$1"; state="$2"; installed="$3"; backup="$4"; pending="$5"
          support="$6"; expected_build="$7"; teardown_port="$8"; expected_bundle_id="$9"
          expected_executable="${10}"
          while /bin/kill -0 "$parent" 2>/dev/null; do /bin/sleep 0.2; done
          status="$(/bin/cat "$state" 2>/dev/null || true)"
          case "$status" in
            committed)
              /bin/rm -rf "$backup"
              /bin/rm -f "$pending" "$state"
              exit 0
              ;;
            rolled-back)
              /bin/rm -f "$state"
              exit 0
              ;;
          esac
          if [ ! -d "$backup" ]; then
            /usr/bin/open "$installed" >/dev/null 2>&1 || true
            /bin/rm -f "$state"
            exit 0
          fi
          /usr/bin/osascript -e "tell application id \\"$expected_bundle_id\\" to quit" >/dev/null 2>&1 || true
          installed_gui="$installed/Contents/MacOS/$expected_executable"
          gui_is_running() {
            process_snapshot="$state.processes"
            /bin/ps -axo command= >"$process_snapshot" 2>/dev/null || return 1
            running=1
            while IFS= read -r command; do
              case "$command" in
                "$installed_gui"|"$installed_gui "*) running=0; break ;;
              esac
            done <"$process_snapshot"
            /bin/rm -f "$process_snapshot"
            return "$running"
          }
          for _ in 1 2 3 4 5 6 7 8 9 10; do
            gui_is_running || break
            /bin/sleep 0.5
          done
          gui_is_running && exit 2
          new_backend="$installed/Contents/Resources/backend"
          if [ -f "$new_backend/launch-backend.sh" ] && [ -x "$new_backend/python3" ]; then
            if ! /usr/bin/env "BLTD_SUPPORT_DIR=$support" "BLTD_PYTHON=$new_backend/python3" "BLTD_BUILD=$expected_build" "BLTD_PORT=$teardown_port" "BLTD_OWNED_BACKEND_DIR=$new_backend" /bin/bash "$new_backend/launch-backend.sh" --stop-owned >>"$support/update-helper.log" 2>&1; then
              exit 2
            fi
          fi
          /bin/rm -rf "$installed"
          /bin/mv "$backup" "$installed" || exit 2
          /bin/rm -f "$pending"
          printf "%s\n" rolled-back >"$state"
          /usr/bin/open "$installed" >/dev/null 2>&1 || true
          /bin/rm -f "$state"
        ' bltd-update-watchdog "$$" "$state" "$installed" "$backup" "$pending" \
          "$support" "$expected_build" "$teardown_port" "$expected_bundle_id" \
          "$expected_executable" \
          >>"$support/update-helper.log" 2>&1 &
        watchdog_pid=$!
        /bin/sleep 0.1
        /bin/kill -0 "$watchdog_pid" 2>/dev/null || rollback

        if ! /bin/mv "$installed" "$backup"; then
          /usr/bin/open "$installed" >/dev/null 2>&1 || true
          mark_state rolled-back || true
          /bin/rm -f "$0"
          exit 1
        fi
        backup_active=1
        /bin/mv "$staged" "$installed" || rollback

        plist="$installed/Contents/Info.plist"
        read_plist() {
          /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null
        }
        [ "$(read_plist CFBundleIdentifier)" = "$expected_bundle_id" ] || rollback
        [ "$(read_plist CFBundleDisplayName)" = "$expected_product" ] || rollback
        [ "$(read_plist CFBundleName)" = "$expected_product" ] || rollback
        [ "$(read_plist CFBundleExecutable)" = "$expected_executable" ] || rollback
        [ "$(read_plist CFBundleVersion)" = "$expected_build" ] || rollback
        /usr/bin/xattr -p com.apple.quarantine "$installed" >/dev/null 2>&1 || rollback

        /usr/bin/codesign --verify --deep --strict --all-architectures "$installed" >/dev/null 2>&1 || rollback
        codesign_info="$(/usr/bin/codesign --display --verbose=4 "$installed" 2>&1)" || rollback
        actual_team="$(printf '%s\n' "$codesign_info" | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
        [ "$actual_team" = "$expected_team" ] || rollback

        gatekeeper_output="$(/usr/sbin/spctl --assess --type execute --verbose=4 "$installed" 2>&1)" || rollback
        printf '%s\n' "$gatekeeper_output" | /usr/bin/grep -Fqx 'source=Notarized Developer ID' || rollback
        /usr/bin/stapler validate -v "$installed" >/dev/null 2>&1 || rollback
        /usr/bin/xattr -p com.apple.quarantine "$installed" >/dev/null 2>&1 || rollback

        # Publish the recovery pointer before launch. The new app can therefore schedule its
        # fallback cleanup on its very first callback, with no open/marker race.
        [ ! -e "$pending" ] || rollback
        if ! /usr/bin/env "BLTD_PYCACHE_ROOT=$support/pycache" \
          "$installed/Contents/Resources/backend/python3" - \
          "$pending.tmp.$$" "$backup" "$$" "$expected_build" \
          "$watchdog_pid" "$state" "$expected_backend_mode" "$expected_backend_port" <<'PY'
        import json
        import os
        import sys

        marker = {
            "version": 1,
            "helperPID": int(sys.argv[3]),
            "watchdogPID": int(sys.argv[5]),
            "statePath": sys.argv[6],
            "backupPath": sys.argv[2],
            "expectedBuild": int(sys.argv[4]),
            "backendMode": sys.argv[7],
            "backendPort": int(sys.argv[8]),
        }
        with open(sys.argv[1], "x", encoding="utf-8") as handle:
            json.dump(marker, handle, separators=(",", ":"))
            handle.write("\\n")
        os.chmod(sys.argv[1], 0o600)
        PY
        then
          rollback
        fi
        if ! /bin/mv "$pending.tmp.$$" "$pending"; then
          rollback
        fi
        marker_active=1

        health_is_expected() {
          [ "$expected_backend_mode" = "external" ] && return 0
          /usr/bin/env "BLTD_PYCACHE_ROOT=$support/pycache" \
            "$installed/Contents/Resources/backend/python3" - \
            "$expected_build" "$installed/Contents/Resources/backend/bltd_api.py" \
            "$expected_backend_port" <<'PY' >/dev/null 2>&1
        import json
        import os
        import sys
        import urllib.request

        try:
            port = int(sys.argv[3])
            if not 1 <= port <= 65535:
                raise ValueError("port")
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=0.6) as response:
                body = json.load(response)
            capabilities = body.get("capabilities") or {}
            good = (
                body.get("ok") is True
                and body.get("service") == "black-label-trading"
                and str(body.get("build")) == sys.argv[1]
                and body.get("runtimeContract") == "bltd-signals-only-runtime-v1"
                and os.path.realpath(str(body.get("backendScript") or "")) == os.path.realpath(sys.argv[2])
                and capabilities.get("signals") is True
                and capabilities.get("execution") is False
                and capabilities.get("optimizerCompute") is False
            )
        except Exception:
            good = False
        raise SystemExit(0 if good else 1)
        PY
        }

        /usr/bin/open -n -W "$installed" >>"$support/update-helper.log" 2>&1 &
        app_waiter=$!
        if [ "$expected_backend_mode" = "bundled" ]; then
          installed_backend="$installed/Contents/Resources/backend"
          if ! /usr/bin/env "BLTD_SUPPORT_DIR=$support" "BLTD_PYTHON=$installed_backend/python3" "BLTD_BUILD=$expected_build" "BLTD_PORT=$expected_backend_port" "BLTD_OWNED_BACKEND_DIR=$installed_backend" /bin/bash "$installed_backend/launch-backend.sh" --bg >>"$support/update-helper.log" 2>&1; then
            rollback
          fi
        fi
        stable_seconds=30
        elapsed=0
        while [ "$elapsed" -lt "$stable_seconds" ]; do
          if ! waiter_is_running; then
            wait "$app_waiter" 2>/dev/null || true
            app_waiter=""
            rollback
          fi
          /bin/sleep 1
          elapsed=$((elapsed + 1))
        done
        health_is_expected || rollback

        # The new GUI stayed alive for the full window and its exact b27 backend acknowledged the
        # fail-closed runtime contract. Stop only the `open -W` waiter; the app keeps running.
        /bin/kill -TERM "$app_waiter" 2>/dev/null || true
        wait "$app_waiter" 2>/dev/null || true
        app_waiter=""
        mark_state committed || rollback
        trap - HUP INT TERM
        backup_active=0
        /bin/rm -rf "$backup"
        clear_pending_if_ours
        /bin/rm -f "$0"
        """

        let helper = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bltd-update-helper-\(UUID().uuidString).sh")
        do {
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        } catch {
            throw UpdaterError.install("couldn't write installer helper: \(error.localizedDescription)")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.environment = Updater.sanitizedToolEnvironment()
        p.arguments = [
            helper.path,
            String(pid),
            installed,
            staged,
            backup,
            Updater.bundleIdentifier,
            Updater.productName,
            String(manifest.latestBuild),
            Updater.teamID,
            Updater.executableName,
            support,
            recoveryBackendMode,
            String(recoveryBackendPort)
        ]
        do { try p.run() } catch { throw UpdaterError.install("couldn't launch installer helper: \(error.localizedDescription)") }

        // Hand off to the helper and quit so it can replace us.
        NSApp.terminate(nil)
    }

    /// The helper normally owns the 30-second stable-launch acknowledgement and automatic rollback.
    /// This is the recovery fallback if the helper itself exits after publishing its marker: a new
    /// app instance must remain alive for 30 seconds before it may delete the retained backup.
    private static func scheduleDeferredBackupCleanup() {
        guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                                 in: .userDomainMask).first else {
            return
        }
        let marker = applicationSupport
            .appendingPathComponent("Black Label Trading", isDirectory: true)
            .appendingPathComponent("update-backup.pending")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        Task {
            // The detached helper owns the first 30 seconds. Wait beyond that window so this
            // fallback cannot race its final health check or rollback decision.
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled,
                  let markerData = try? Data(contentsOf: marker),
                  let recovery = try? JSONDecoder().decode(
                    UpdateRecoveryMarker.self, from: markerData) else {
                return
            }
            let current = Bundle.main.bundleURL.standardizedFileURL
            let backup = URL(fileURLWithPath: recovery.backupPath).standardizedFileURL
            let stateURL = URL(fileURLWithPath: recovery.statePath).standardizedFileURL
            let expectedPrefix = current.lastPathComponent + ".update-backup-"
            guard backup.deletingLastPathComponent() == current.deletingLastPathComponent(),
                  backup.lastPathComponent.hasPrefix(expectedPrefix),
                  stateURL.deletingLastPathComponent() == marker.deletingLastPathComponent(),
                  stateURL.lastPathComponent.hasPrefix("update-helper.state."),
                  let state = try? String(contentsOf: stateURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) else {
                return
            }
            let helperAlive = recoveryHelperIsAlive(recovery.helperPID)
            let watchdogAlive = recoveryHelperIsAlive(recovery.watchdogPID)
            guard !helperAlive, !watchdogAlive else { return }
            let acknowledged = await recoveryBackendAcknowledged(recovery)
            guard UpdateRecoveryPolicy.mayDeleteBackup(
                    marker: recovery,
                    currentBuild: Updater.currentBuild(),
                    helperIsAlive: helperAlive,
                    watchdogIsAlive: watchdogAlive,
                    transactionCommitted: state == "committed",
                    backendAcknowledged: acknowledged) else {
                return
            }
            do {
                if FileManager.default.fileExists(atPath: backup.path) {
                    try FileManager.default.removeItem(at: backup)
                }
                try FileManager.default.removeItem(at: marker)
            } catch {
                // Retain both paths so a later stable launch can retry.
            }
        }
    }

    private static func recoveryHelperIsAlive(_ rawPID: Int) -> Bool {
        guard rawPID > 1, rawPID <= Int(Int32.max) else { return false }
        errno = 0
        return Darwin.kill(pid_t(rawPID), 0) == 0 || errno == EPERM
    }

    private static func recoveryBackendAcknowledged(
        _ recovery: UpdateRecoveryMarker) async -> Bool {
        if recovery.backendMode == "external" {
            return recovery.backendPort == 0
        }
        guard recovery.backendMode == "bundled",
              (1...65_535).contains(recovery.backendPort),
              let script = Bundle.main.resourceURL?
                .appendingPathComponent("backend/bltd_api.py")
                .standardizedFileURL
                .resolvingSymlinksInPath(),
              let url = URL(string: "http://127.0.0.1:\(recovery.backendPort)/health") else {
            return false
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.0
        configuration.waitsForConnectivity = false
        do {
            let (data, response) = try await URLSession(configuration: configuration).data(from: url)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  exactJSONBoolean(object["ok"]) == true,
                  object["service"] as? String == "black-label-trading",
                  String(describing: object["build"] ?? "") == String(recovery.expectedBuild),
                  object["runtimeContract"] as? String == "bltd-signals-only-runtime-v1",
                  let backendScript = object["backendScript"] as? String,
                  URL(fileURLWithPath: backendScript).standardizedFileURL
                    .resolvingSymlinksInPath() == script,
                  let capabilities = object["capabilities"] as? [String: Any],
                  exactJSONBoolean(capabilities["signals"]) == true,
                  exactJSONBoolean(capabilities["execution"]) == false,
                  exactJSONBoolean(capabilities["optimizerCompute"]) == false else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private static func exactJSONBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
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
