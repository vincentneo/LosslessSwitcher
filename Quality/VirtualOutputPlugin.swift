//
//  VirtualOutputPlugin.swift
//  LosslessSwitcher
//
//  Install, update and remove the Renderer Engine's virtual output device: the HAL plug-in
//  LSOutput.driver (source: HALPlugin/), shipped in the app's Resources and installed to
//  /Library/Audio/Plug-Ins/HAL. Both need an administrator password (one prompt) and restart
//  coreaudiod, which interrupts all audio for a moment. The caller stops the engine first so the
//  DAC and the default output are handed back before the device goes away.
//

import AppKit
import CoreAudio
import Foundation

final class VirtualOutputPlugin: ObservableObject {

    static let shared = VirtualOutputPlugin()

    static let installPath = "/Library/Audio/Plug-Ins/HAL/LSOutput.driver"

    enum State: Equatable {
        case notInstalled
        case installed(version: String)
        case outdated(installed: String, bundled: String)
    }

    @Published private(set) var state: State = .notInstalled
    @Published private(set) var busy = false
    /// The last install/remove failure, for the menu.
    @Published private(set) var lastError: String?

    private var listener: AudioObjectPropertyListenerBlock?

    private init() {
        refresh()
        // the device list changes when coreaudiod restarts or the plug-in loads
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
    }

    var bundledURL: URL? { Bundle.main.url(forResource: "LSOutput", withExtension: "driver") }

    /// CFBundleShortVersionString (CFBundleVersion) of a plug-in bundle.
    static func version(of url: URL) -> (short: String, build: Int)? {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else { return nil }
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
        return (short, build)
    }

    func refresh() {
        let installed = Self.version(of: URL(fileURLWithPath: Self.installPath))
        let bundled = bundledURL.flatMap { Self.version(of: $0) }
        let new: State
        if let i = installed {
            if let b = bundled, b.build > i.build {
                new = .outdated(installed: i.short, bundled: b.short)
            } else {
                new = .installed(version: i.short)
            }
        } else {
            new = .notInstalled
        }
        if Thread.isMainThread { state = new } else { DispatchQueue.main.async { self.state = new } }
    }

    /// Installs (or replaces) the bundled plug-in. Runs `done` on the main thread with success.
    func install(done: @escaping (Bool) -> Void) {
        guard let src = bundledURL else {
            lastError = "This build has no LSOutput.driver in its Resources."
            done(false)
            return
        }
        let dst = Self.installPath
        // coreaudiod loads plug-ins as _coreaudiod: everything must be world-readable (a build made
        // under umask 027 shipped Info.plist 0640, and the device never appeared)
        run(shell: "rm -rf \(q(dst)) && /usr/bin/ditto \(q(src.path)) \(q(dst)) && /usr/sbin/chown -R root:wheel \(q(dst)) && /bin/chmod -R a+rX \(q(dst)) && /usr/bin/killall coreaudiod",
            prompt: "LosslessSwitcher wants to install its virtual output device. Audio restarts for a moment.",
            done: done)
    }

    func remove(done: @escaping (Bool) -> Void) {
        run(shell: "rm -rf \(q(Self.installPath)) && /usr/bin/killall coreaudiod",
            prompt: "LosslessSwitcher wants to remove its virtual output device. Audio restarts for a moment.",
            done: done)
    }

    /// One administrator prompt; then waits for coreaudiod to be back (up to 10 s).
    private func run(shell: String, prompt: String, done: @escaping (Bool) -> Void) {
        busy = true
        lastError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let source = "do shell script \"\(Self.escape(shell))\" with administrator privileges with prompt \"\(Self.escape(prompt))\""
            var err: NSDictionary?
            let ok = NSAppleScript(source: source)?.executeAndReturnError(&err) != nil
            if ok {
                // coreaudiod restarts under launchd; wait until it lists devices again
                let end = Date().addingTimeInterval(10)
                Thread.sleep(forTimeInterval: 1)
                while Date() < end, !Self.halResponds() { Thread.sleep(forTimeInterval: 0.2) }
                Thread.sleep(forTimeInterval: 0.5)
            }
            let message = err.map { ($0[NSAppleScript.errorMessage] as? String) ?? "\($0)" }
            DispatchQueue.main.async {
                self.busy = false
                // -128: the user cancelled the password prompt
                if !ok, (err?[NSAppleScript.errorNumber] as? Int) != -128 { self.lastError = message }
                self.refresh()
                print("[VirtualOutputPlugin] \(ok ? "done" : "failed: \(message ?? "?")")")
                done(ok)
            }
        }
    }

    private static func halResponds() -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr && size > 0
    }

    /// Single-quoted for the shell.
    private func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Escaped for an AppleScript string literal.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
