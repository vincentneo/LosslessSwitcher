//
//  VirtualDeviceEngine.swift
//  LosslessSwitcher
//
//  Exclusive Mode, virtual-device path. Music plays to "LosslessSwitcher" (the virtual device), a HAL plug-in
//  (LSOutput.driver in /Library/Audio/Plug-Ins/HAL) that loops its output mix back to its input.
//  IOProc A reads that input into a ring; IOProc B plays the ring directly on the DAC, which this
//  engine hogs and puts in a non-mixable (integer) format. The virtual device's clock is steered to
//  the DAC's through the plug-in's rate scalar property ('LSrs'), so nothing is resampled and the
//  ring's fill stays put. While the engine runs the virtual device is the default output; the DAC
//  is the device that was the default before (restored on stop, never to the virtual device).
//
//  Rate switches (Music can't be made to wait from the device side, so it is paused and rewound):
//  - Music sets up a local next track's decoder 8-12 s early and logs its rate. If it differs, the
//    "boundary latch" is armed 1.5 s before the current track's end: A marks the ring at the first
//    10 ms of exact zeros (Music's inter-track zeros) and B stops there.
//  - On the new track's Playing: pause Music, switch the virtual device (~0.02 s) and the DAC (B
//    keeps it running with silence; waitUntilReady), drop everything in the ring (the new track's
//    wrong-rate start and the pause fade), rewind Music to where the play started, play.
//  - A play from paused/stopped waits at the ring's "gate" (A marks the first nonzero frame) until
//    the new track's rate is known, so a wrong-rate start never reaches the DAC.
//  Same-rate changes, gapless albums and pause/resume pass through untouched.
//  Volume keys: the virtual device's volume and mute drive the DAC's own controls (VolumeForwarder).
//  Measurements and the test history are summarized in the pull request that added it.
//
//  Needs Microphone (reading the virtual device's input) and Automation (Music) permissions.
//

import AppKit
import AVFoundation
import CoreAudio
import Foundation
import SimplyCoreAudio
import Synchronization
import SwiftUI
import UserNotifications

final class VirtualDeviceEngine {

    static let deviceUID = "LSOutput_UID" // shown as "LosslessSwitcher" (plug-in 1.1+; 1.0: "LosslessSwitcher Output")
    static let pluginPath = "/Library/Audio/Plug-Ins/HAL/LSOutput.driver"
    private static let dacUIDKey = "RendererDACUID"
    private static let kRateScalar: AudioObjectPropertySelector = 0x4C53_7273 // 'LSrs'
    /// 'LSac': the renderer's pid while it plays the device out (0 = none). Plug-in 1.1+ can be the
    /// default output only while it is set, and clears it when that process stops being a client.
    private static let kAttached: AudioObjectPropertySelector = 0x4C53_6163

    /// The plug-in's device, if the HAL has it.
    static func findDevice() -> AudioObjectID? {
        CA.devices().first { CA.string($0, kAudioDevicePropertyDeviceUID) == deviceUID }
    }

    /// Set while the engine owns the output (virtual device default, DAC hogged non-mixable),
    /// cleared on a clean stop: still set at launch = the last run died.
    private static let ownsOutputKey = "RendererEngineOwnsOutput"
    private static let recoveryNoteKey = "RendererRecoveryNote"

    /// After a crash or a kill: the HAL releases the hog, but the DAC stays in its non-mixable format
    /// (unusable for everything else) and the default output is the virtual device (plug-in 1.0) or
    /// whatever coreaudiod fell back to (1.1: MacBook Pro Speakers in the kill test). Give the DAC its
    /// mixable format back and make it the default again. Harmless when the engine starts next.
    static func recoverOutput() {
        let volumeNote = VolumeForwarder.recover()
        let unclean = UserDefaults.standard.bool(forKey: ownsOutputKey)
        let ls = findDevice()
        let current = CA.defaultOutput()
        guard unclean || (ls != nil && current == ls) else {
            if let volumeNote { UserDefaults.standard.set("[Exclusive Mode] " + volumeNote, forKey: recoveryNoteKey) }
            return
        }
        let saved = UserDefaults.standard.string(forKey: dacUIDKey).flatMap { uid in CA.devices().first { CA.string($0, kAudioDevicePropertyDeviceUID) == uid } }
        guard let dac = saved ?? ls.flatMap({ fallbackOutput(excluding: $0) }) else { return }
        var msg = "[Exclusive Mode] recovering the output after \(unclean ? "an unclean exit" : "a default left on the virtual device"): DAC \(CA.string(dac, kAudioObjectPropertyName))"
        if CA.hogOwner(dac) == -1 { msg += ", mixable \(CA.setMixable(dac))" }
        if current != dac { msg += ", default output (was \(CA.string(current, kAudioObjectPropertyName))) \(CA.setDefaultOutput(dac))" }
        if let volumeNote { msg += "; " + volumeNote }
        print(msg)
        UserDefaults.standard.set(msg, forKey: recoveryNoteKey) // the next engine run logs it
        UserDefaults.standard.removeObject(forKey: ownsOutputKey)
    }

    /// The device the system would pick: built-in output first, else any other output.
    static func fallbackOutput(excluding ls: AudioObjectID) -> AudioObjectID? {
        let outs = CA.devices().filter { $0 != ls && CA.hasOutput($0) && CA.string($0, kAudioDevicePropertyDeviceUID) != deviceUID }
        return outs.first { CA.transport($0) == kAudioDeviceTransportTypeBuiltIn } ?? outs.first
    }

    private unowned let outputDevices: OutputDevices

    // main thread
    private var observer: NSObjectProtocol?
    private var thread: Thread?
    private var logProcess: Process?
    private var finished: DispatchSemaphore?

    // inbox, under inboxLock: main thread / log reader -> engine thread
    private let inboxLock = NSLock()
    private var infoInbox: [(Date, [AnyHashable: Any])] = []
    private var lineInbox: [(Date, String)] = []
    private var stopRequested = false

    // engine thread
    private var ls = AudioObjectID(0)
    private var dac = AudioObjectID(0)
    private var dacUID = ""
    private var defaultBefore = AudioObjectID(0) // the default output before the engine took it; restored on stop
    private var dacOut = AudioStreamID(0)
    private var procA: AudioDeviceIOProcID?
    private var procB: AudioDeviceIOProcID?
    private var hogged = false
    private var nonMixable = false
    private var curRate: Float64 = 0
    private var playing = false
    private var lastTrackID: Int64?
    private var decoderRates: [(date: Date, rate: Float64, bits: Int?, lossless: Bool)] = []
    private var lossyTrackAt: Date?
    private var pendingUpgrade: (rate: Float64, bits: Int?)?
    private var armAt: Date?
    private var armedAt: Date?
    private var lateArmAt: Date? // a pre-roll line that came early: arm again 1.5 s before the end
    private var latchedAt: Date?
    private var gatePending = false
    private var lastNewTrackAt: Date?
    private var awaiting: (name: String, tPlay: Date, until: Date)? // a new track whose decoder line hasn't come yet
    private var gateMarkedAt: Date?
    private var gateWaitsForMusic = false // after Music quit: the gate waits longer for its Playing
    private var regateOnSilence = false   // the gate let another sound through: close it when that ends
    private var musicPID: pid_t = 0
    // idle step-aside: Music not playing for RendererIdleSeconds -> DAC and default output given back
    private var steppedAside = false
    private var idleSince: Date?
    private var resumeInfo: (info: [AnyHashable: Any], at: Date)?
    private var musicListWrong = false

    /// NSRunningApplication once said Music wasn't running while it played on as the same process
    /// (Babyface bench, twice; the "quit" held its audio at the gate for 4 s and dropped the next
    /// track's decoder line). Its pid decides: Music quit only when that process is gone.
    private func musicRunning() -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first {
            musicPID = app.processIdentifier; musicListWrong = false
            return true
        }
        guard musicPID > 0, kill(musicPID, 0) == 0 || errno == EPERM else { musicPID = 0; return false }
        if !musicListWrong { musicListWrong = true; log("NSRunningApplication lists no Music, but pid \(musicPID) is alive: still running") }
        return true
    }
    private var strayMarkerAt: Date?
    private var setUpAt: Date?
    private var inputSeen = false
    private var inRoutine = false
    private var switches = 0
    private var scripts: RendererScripts!
    private let log = RendererLog()
    private let targetFill: Int
    // clock lock (PLL on the phase between the two devices' time lines)
    private let tau = 5.0
    private var phase0: Double?
    private var dacScalarEst = 0.0, integ = 0.0, lsScalar = 1.0
    private var lockAfterCycles = (0, 0)
    private var waitingForScalar = false
    private var refillAsked = false
    private var scriptRate: Float64 = 0 // the rate the user's script (Scripting menu) last heard
    private var overshootLogged: Bool?
    private var ticksPerSec = 0.0

    // shared with the IO threads
    private let ring = VRing(frames: 1 << 20)
    private let stampA = VStamp(), stampB = VStamp()
    private let marker = Atomic<Int>(-1)      // ring position B doesn't read past; -1 none
    private let atBoundary = Atomic<Int>(0)   // B reached the marker
    private let command = Atomic<Int>(0)      // engine -> B: 1 go on past the marker, 2 flush and refill
    private let latchZeros = Atomic<Int>(0)   // > 0: latch armed, zero run (frames) that marks the boundary
    private let gate = Atomic<Int>(0)         // 1: A marks the ring at the first nonzero frame
    private let trimIdle = Atomic<Int>(0)     // 1: Music isn't playing; B keeps the ring at the target
    private let lastNZ = Atomic<Int>(0)       // ring position after the last nonzero frame A wrote
    private let outFormat = Atomic<Int>(0)    // packed OutFormat for B; 0 = mute
    private let formatDirty = Atomic<Int>(0)
    private let refill = Atomic<Int>(0)       // engine -> B: output silence until the ring is back at the target
    private let dropInput = Atomic<Int>(0)    // 1: A doesn't fill the ring (inside a switch; Music is paused)  // listener -> engine: the DAC's format changed
    private var writtenFormat = AudioStreamBasicDescription()
    private var formatListener: AudioObjectPropertyListenerBlock?
    private var listenedStream = AudioStreamID(0)
    private let listenerQueue = DispatchQueue(label: "RendererEngine.formatListener")
    private lazy var volume = VolumeForwarder(log: { [unowned self] in self.log($0) })
    private var settingsCheckDue = true
    private let aCycles = Atomic<Int>(0), bCycles = Atomic<Int>(0)
    private let inFrames = Atomic<Int>(0), outFrames = Atomic<Int>(0)
    private let outSegmentAt = Atomic<Int>(-1) // B: outFrames where a flush took effect
    // IO-thread-only
    private var zeroRun = 0
    private var bPlaying = false
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: VirtualDeviceEngine.maxFrames * 2)
    private static let maxFrames = 16384
    private var recorder: VRecorder?

    init(outputDevices: OutputDevices) {
        self.outputDevices = outputDevices
        let t = UserDefaults.standard.integer(forKey: "RendererTargetFrames")
        targetFill = t > 0 ? t : 2048
        scratch.initialize(repeating: 0, count: Self.maxFrames * 2)
    }

    deinit { scratch.deallocate() }

    // MARK: - Lifecycle (main thread)

    var isRunning: Bool { thread != nil }

    func start() {
        guard thread == nil else { return }
        print("[Exclusive Mode] virtual-device engine: start requested")
        inboxLock.lock(); stopRequested = false; infoInbox = []; lineInbox = []; inboxLock.unlock()
        observer = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.inboxLock.lock(); self.infoInbox.append((Date(), note.userInfo ?? [:])); self.inboxLock.unlock()
        }
        startDecoderLog()
        let done = DispatchSemaphore(value: 0)
        finished = done
        let t = Thread { [weak self] in
            self?.run()
            done.signal()
        }
        t.name = "RendererEngine (virtual device)"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    /// Stops the IO, gives the DAC back (mixable, hog released) and restores the default output.
    /// Waits for a switch in progress (up to 20 s).
    func stop() {
        guard thread != nil else { return }
        inboxLock.lock(); stopRequested = true; inboxLock.unlock()
        if finished?.wait(timeout: .now() + 20) == .timedOut {
            print("[Exclusive Mode] engine thread did not stop within 20 s")
            Self.recoverOutput()
        }
        thread = nil
        finished = nil
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        logProcess?.terminate()
        logProcess = nil
    }

    private func startDecoderLog() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--predicate", "process == \"Music\" AND eventMessage CONTAINS \"Input format:\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var partial = "" // only touched by the serial readability handler
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self, let chunk = String(data: h.availableData, encoding: .utf8), !chunk.isEmpty else { return }
            partial += chunk
            var lines = partial.components(separatedBy: "\n")
            partial = lines.removeLast()
            let now = Date()
            self.inboxLock.lock(); self.lineInbox += lines.map { (now, $0) }; self.inboxLock.unlock()
        }
        do { try p.run(); logProcess = p } catch { print("[Exclusive Mode] could not start log stream: \(error)") }
    }

    // MARK: - Engine thread

    private var shouldStop: Bool { inboxLock.lock(); defer { inboxLock.unlock() }; return stopRequested }

    private func run() {
        log.start()
        log("engine started (virtual device)")
        if let note = UserDefaults.standard.string(forKey: Self.recoveryNoteKey) {
            log(note.replacingOccurrences(of: "[Exclusive Mode] ", with: "at launch: "))
            UserDefaults.standard.removeObject(forKey: Self.recoveryNoteKey)
        }
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        ticksPerSec = 1e9 * Double(tb.denom) / Double(tb.numer)
        scripts = RendererScripts()
        recorder = VRecorder.fromDefaults(log: { [unowned self] in self.log($0) })
        guard checkMicrophone() else {
            log("engine idle until it is turned off; the output is unchanged")
            while !shouldStop { Thread.sleep(forTimeInterval: 0.1) }
            log.close()
            return
        }
        guard setUp() else {
            log("setup failed; engine idle until it is turned off")
            while !shouldStop { Thread.sleep(forTimeInterval: 0.1) }
            log.close()
            return
        }
        var lastCheck = Date(), lastPLL = Date(), lastStatus = Date(), lastFormatCheck = Date()
        while !shouldStop {
            pump()
            recorder?.drain()
            let now = Date()
            if now.timeIntervalSince(lastCheck) >= 1 { lastCheck = now; checkDevicesAndMusic() }
            tickLatchAndGate()
            if formatDirty.load(ordering: .acquiring) != 0 || now.timeIntervalSince(lastFormatCheck) >= 1 { lastFormatCheck = now; checkFormat() }
            if let up = pendingUpgrade, playing, !inRoutine {
                pendingUpgrade = nil
                if let r = neededRate(up.rate) {
                    log("lossless decoder at \(up.rate) Hz after a lossy start; switching again")
                    switchRate(r, name: "(lossless upgrade)", tPlay: Date())
                }
            }
            if now.timeIntervalSince(lastPLL) >= 0.5 { lastPLL = now; pll() }
            if playing { idleSince = nil } else if idleSince == nil { idleSince = now }
            let isp = OvershootProtection.shared.isOn
            if isp != overshootLogged {
                if overshootLogged != nil || isp { log("inter-sample overshoot protection \(isp ? "on: output -3.0 dB, not bit-perfect" : "off: output unchanged")") }
                overshootLogged = isp
            }
            if let r = resumeInfo { resumeInfo = nil; resumeFromIdle(r.info, at: r.at) }
            if !steppedAside, !inRoutine, !playing, let since = idleSince, UserDefaults.standard.bool(forKey: Defaults.kRendererReleaseWhenIdle) {
                let limit = max(UserDefaults.standard.double(forKey: "RendererIdleSeconds"), 0) > 0 ? UserDefaults.standard.double(forKey: "RendererIdleSeconds") : 60
                if now.timeIntervalSince(since) >= limit { stepAside(after: limit) }
            }
            if !inRoutine, settingsCheckDue || MusicSettingsCheck.shared.recheck.exchange(0, ordering: .acquiringAndReleasing) != 0 {
                settingsCheckDue = false
                MusicSettingsCheck.shared.check(scripts, musicRunning: musicRunning(), log: { [unowned self] in self.log($0) })
            }
            if now.timeIntervalSince(lastStatus) >= 30 {
                lastStatus = now
                log("\(Int(curRate)) Hz fill \(ring.fill) scalar \(String(format: "%.9f", lsScalar)) under \(ring.underruns.load(ordering: .relaxed)) over \(ring.overruns.load(ordering: .relaxed))")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        tearDown(restoreDefault: true, resumeMusic: true)
        MusicSettingsCheck.shared.clear()
        recorder?.finish()
        log("engine stopped")
        log.close()
    }

    /// Reading the virtual device's input needs the Microphone permission. Nothing is touched until
    /// it is answered: on the first launch of a new copy (Babyface bench) the default was already the
    /// virtual device while the prompt was open, each HAL call on its input blocked ~60 s, and setup
    /// failed after 3.5 min of silence. Without the permission the engine stays idle and the output
    /// is left as it was.
    private func checkMicrophone() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            log("microphone permission: granted")
            return true
        case .notDetermined:
            log("microphone permission: not determined; asking, and leaving the output alone until it is answered")
            final class Answer: @unchecked Sendable { var granted = false }
            let answer = Answer(), done = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { ok in answer.granted = ok; done.signal() }
            while done.wait(timeout: .now() + 0.2) == .timedOut {
                if shouldStop { log("turned off while the microphone prompt was open"); return false }
            }
            log("microphone permission \(answer.granted ? "granted" : "denied")")
            return answer.granted
        default:
            log("microphone permission DENIED: the engine can't read the virtual device. Allow LosslessSwitcher in System Settings > Privacy & Security > Microphone, then turn the engine off and on.")
            return false
        }
    }

    /// Drains the inbox; call instead of sleeping while waiting for Music's notifications.
    private func pump() {
        inboxLock.lock()
        let infos = infoInbox, lines = lineInbox
        infoInbox = []; lineInbox = []
        inboxLock.unlock()
        // in arrival order: a track's decoder line usually comes just before its Playing
        var events = infos.map { (at: $0.0, info: Optional($0.1), line: String?.none) } + lines.map { (at: $0.0, info: nil, line: Optional($0.1)) }
        events.sort { $0.at < $1.at }
        for e in events {
            if let info = e.info { handleInfo(info, at: e.at) } else if let line = e.line { handleLine(line, at: e.at) }
        }
    }

    private func wait(_ seconds: TimeInterval, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            pump()
            recorder?.drain()
            Thread.sleep(forTimeInterval: 0.005)
        }
        return done()
    }

    // MARK: - Setup and teardown

    private func setUp() -> Bool {
        guard let l = Self.findDevice() else { log("virtual device not found"); return false }
        ls = l
        guard let d = chooseDAC() else { log("no output device to play to"); return false }
        let wasPlaying = musicPlaying()
        if wasPlaying {
            _ = scripts.pause()
            _ = wait(1) { !self.playing }
        }
        // a play while the DAC comes up (up to 12 s) waits at the gate
        playing = false
        gatePending = true; gateMarkedAt = nil; gate.store(1, ordering: .releasing); trimIdle.store(1, ordering: .releasing)
        attach(true)
        UserDefaults.standard.set(true, forKey: Self.ownsOutputKey)
        if CA.defaultOutput() != ls { defaultBefore = CA.defaultOutput() }
        if CA.defaultOutput() != ls { log("default output -> virtual device: \(CA.setDefaultOutput(ls))") }
        guard startLS(), setUpDAC(d) else {
            tearDown(restoreDefault: true, resumeMusic: wasPlaying)
            return false
        }
        if wasPlaying { playChecked() }
        return true
    }

    /// The device chosen in the menu's Selected Device, if one is chosen and present (never the
    /// virtual device). The engine plays to it instead of the default output.
    private func selectedDAC() -> AudioObjectID? {
        guard let uid = Defaults.shared.selectedDeviceUID, uid != Self.deviceUID else { return nil }
        return CA.devices().first { CA.string($0, kAudioDevicePropertyDeviceUID) == uid && CA.hasOutput($0) }
    }

    /// The Selected Device, else the device Music played to before: the default output, or the saved
    /// DAC if the default is already the virtual device (an earlier run didn't restore it), or the
    /// system's fallback.
    private func chooseDAC() -> AudioObjectID? {
        if let s = selectedDAC() { return s }
        let d = CA.defaultOutput()
        if d != ls, d != 0 { return d }
        if let uid = UserDefaults.standard.string(forKey: Self.dacUIDKey),
           let saved = CA.devices().first(where: { CA.string($0, kAudioDevicePropertyDeviceUID) == uid }) { return saved }
        return Self.fallbackOutput(excluding: ls)
    }

    /// IOProc A: the virtual device's loopback input -> ring.
    private func startLS() -> Bool {
        var st = CA.setScalar(ls, 1.0, Self.kRateScalar)
        lsScalar = 1
        log("virtual device \(ls) @ \(CA.nominal(ls)) Hz; scalar reset \(st)")
        var proc: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&proc, ls, nil) { [unowned self] _, inInput, inTime, _, _ in
            self.renderA(inInput, inTime)
        }
        guard st == noErr, let proc else { log("IOProc A: \(st)"); return false }
        procA = proc
        log("A: output streams off: \(CA.streamUsageOff(ls, proc, kAudioObjectPropertyScopeOutput))")
        st = AudioDeviceStart(ls, proc)
        log("start A: \(st)")
        return st == noErr
    }

    /// Hog + non-mixable on the DAC, virtual device at the DAC's rate, IOProc B on the DAC.
    private func setUpDAC(_ d: AudioObjectID) -> Bool {
        dac = d
        dacUID = CA.string(d, kAudioDevicePropertyDeviceUID)
        UserDefaults.standard.set(dacUID, forKey: Self.dacUIDKey)
        guard let s = CA.streams(d, kAudioObjectPropertyScopeOutput).first else { log("DAC has no output stream"); return false }
        dacOut = s
        log("DAC \(CA.string(d, kAudioObjectPropertyName)) (\(dacUID)) @ \(CA.nominal(d)) Hz, hog owner \(CA.hogOwner(d)), my pid \(getpid())")
        var me = getpid()
        var a = CA.addr(kAudioDevicePropertyHogMode)
        let st = AudioObjectSetPropertyData(d, &a, 0, nil, 4, &me)
        hogged = CA.hogOwner(d) == getpid()
        log("hog DAC: \(st), \(hogged ? "hogged" : "NOT hogged (shared mode, mixable)")")
        RendererOutput.shared.set(dacName: CA.string(d, kAudioObjectPropertyName))
        let rate = CA.nominal(d)
        if !CA.nominalRates(ls).contains(rate) { log("virtual device can't run at \(rate) Hz; Music will be resampled into it") }
        applyRate(rate)
        var proc: AudioDeviceIOProcID?
        let cst = AudioDeviceCreateIOProcIDWithBlock(&proc, d, nil) { [unowned self] _, _, _, outOutput, outTime in
            self.renderB(outOutput, outTime)
        }
        guard cst == noErr, let proc else { log("IOProc B: \(cst)"); return false }
        procB = proc
        log("B: DAC inputs off: \(CA.streamUsageOff(d, proc, kAudioObjectPropertyScopeInput))")
        bPlaying = false
        outFormat.store(0, ordering: .releasing) // muted until the format is confirmed
        let bst = AudioDeviceStart(d, proc)
        log("start B: \(bst)")
        if bst == noErr, let target = dacFormat(curRate) {
            let t = Date()
            let ready = DeviceFormat.waitUntilReady(d, format: target, checkBitDepth: true, timeout: 12, stalled: { AudioDeviceStop(d, proc); AudioDeviceStart(d, proc) })
            log("DAC \(ready ? "ready" : "NOT ready") after \(ms(t)): \(CA.formats(dacOut))")
        }
        updateOutFormat()
        listenForFormatChanges()
        volume.start(virtual: ls, dac: d)
        setUpAt = Date(); inputSeen = false
        recorder?.segmentOut(outFrames.load(ordering: .acquiring), curRate)
        recorder?.segmentIn(inFrames.load(ordering: .acquiring), curRate)
        resetLock()
        return bst == noErr
    }

    /// Sets both devices to `rate` (the DAC in its best format for it) without waiting for the DAC.
    private func applyRate(_ rate: Float64) {
        if CA.nominal(ls) != rate, CA.nominalRates(ls).contains(rate) {
            let st = CA.setNominal(ls, rate)
            let ok = waitPlain(2) { CA.nominal(self.ls) == rate }
            log("virtual device -> \(Int(rate)): \(st)\(ok ? "" : " (NOT confirmed)")")
        }
        if let f = dacFormat(rate) {
            var pf = f
            var a = CA.addr(kAudioStreamPropertyPhysicalFormat)
            let st = AudioObjectSetPropertyData(dacOut, &a, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &pf)
            nonMixable = f.mFormatFlags & kAudioFormatFlagIsNonMixable != 0
            log("DAC format -> \(CA.fmt(f)): \(st)")
            runUserScript(rate, bits: Int(f.mBitsPerChannel))
        } else if CA.nominal(dac) != rate {
            log("DAC has no listed format at \(rate) Hz; nominal rate -> \(CA.setNominal(dac, rate))")
            runUserScript(rate, bits: nil)
        }
        curRate = rate
    }

    /// Scripting menu: the regular path runs the user's script (rate, bit depth) when it sets a new
    /// rate; the engine owns rate changes while it runs, so it does the same, once per new rate.
    private func runUserScript(_ rate: Float64, bits: Int?) {
        guard rate != scriptRate else { return }
        scriptRate = rate
        guard let path = Defaults.shared.shellScriptPath else { return }
        log("script: \(path) \(Int(rate))\(bits.map { " \($0)" } ?? "")")
        let devices = outputDevices
        DispatchQueue.main.async { devices.runUserScript(rate, bitDepth: bits) }
    }

    /// Non-mixable first when hogged (exclusive integer output), then the most bits.
    private func dacFormat(_ rate: Float64) -> AudioStreamBasicDescription? {
        let all = CA.availablePhysicalFormats(dacOut).filter {
            $0.mFormat.mFormatID == kAudioFormatLinearPCM && ($0.mFormat.mSampleRate == rate || ($0.mSampleRateRange.mMinimum <= rate && rate <= $0.mSampleRateRange.mMaximum))
        }.map { r -> AudioStreamBasicDescription in var f = r.mFormat; f.mSampleRate = rate; return f }
        let usable = hogged ? all : all.filter { $0.mFormatFlags & kAudioFormatFlagIsNonMixable == 0 }
        return usable.max { a, b in
            let na = a.mFormatFlags & kAudioFormatFlagIsNonMixable != 0, nb = b.mFormatFlags & kAudioFormatFlagIsNonMixable != 0
            if na != nb { return !na }
            return a.mBitsPerChannel < b.mBitsPerChannel
        }
    }

    /// What B writes: the IOProc sees the stream's virtual format. Right after a physical format
    /// change the virtual format can still be the old one (in the first build it read float32 while
    /// the MT 48 already ran int32 non-mixable, and B wrote float bits into an integer stream), so B
    /// stays muted (outFormat 0) until the virtual format agrees with the physical one: equal when
    /// non-mixable, float32 at the same rate when mixable.
    private func updateOutFormat() {
        outFormat.store(0, ordering: .releasing)
        formatDirty.store(0, ordering: .releasing)
        var pf = AudioStreamBasicDescription(), vf = AudioStreamBasicDescription()
        let end = Date().addingTimeInterval(3)
        var confirmed = false
        while Date() < end {
            (pf, vf) = CA.physicalAndVirtual(dacOut)
            let nm = pf.mFormatFlags & kAudioFormatFlagIsNonMixable != 0
            confirmed = pf.mSampleRate == vf.mSampleRate && pf.mSampleRate == curRate && (nm
                ? vf.mFormatFlags == pf.mFormatFlags && vf.mBitsPerChannel == pf.mBitsPerChannel && vf.mBytesPerFrame == pf.mBytesPerFrame
                : vf.mFormatFlags & kAudioFormatFlagIsFloat != 0 && vf.mBitsPerChannel == 32)
            if confirmed { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard confirmed else {
            log("B MUTED: DAC format not settled (phys \(CA.fmt(pf)) / virt \(CA.fmt(vf)), expected \(Int(curRate)) Hz)")
            return
        }
        var ch = [UInt32](repeating: 0, count: 2)
        var a = CA.addr(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
        var z = UInt32(8)
        let stereo = AudioObjectGetPropertyData(dac, &a, 0, nil, &z, &ch) == noErr && ch[0] >= 1 && ch[1] >= 1 ? (Int(ch[0]) - 1, Int(ch[1]) - 1) : (0, 1)
        let f = OutFormat(asbd: vf, left: stereo.0, right: stereo.1)
        writtenFormat = vf
        outFormat.store(f.packed, ordering: .releasing)
        log("B writes \(f) (virtual format \(CA.fmt(vf)))")
    }

    /// Any change of the DAC stream's format mutes B at once; the engine thread re-confirms it.
    private func listenForFormatChanges() {
        var a = CA.addr(kAudioStreamPropertyVirtualFormat)
        let stream = dacOut
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let cur = self.outFormat.load(ordering: .acquiring)
            guard cur != 0 else { return } // already muted
            let now = OutFormat(packed: cur)
            let (pf, vf) = CA.physicalAndVirtual(stream)
            let fresh = OutFormat(asbd: vf, left: now.left, right: now.right)
            // B's format still describes the buffers (and the physical side agrees): nothing to do
            if fresh.packed == cur && pf.mSampleRate == vf.mSampleRate { return }
            self.outFormat.store(0, ordering: .releasing)
            self.formatDirty.store(1, ordering: .releasing)
        }
        formatListener = block
        listenedStream = dacOut
        let st = AudioObjectAddPropertyListenerBlock(dacOut, &a, listenerQueue, block)
        a = CA.addr(kAudioStreamPropertyPhysicalFormat)
        let st2 = AudioObjectAddPropertyListenerBlock(dacOut, &a, listenerQueue, block)
        log("format listeners: \(st) \(st2)")
    }

    private func removeFormatListener() {
        guard let block = formatListener else { return }
        var a = CA.addr(kAudioStreamPropertyVirtualFormat)
        AudioObjectRemovePropertyListenerBlock(listenedStream, &a, listenerQueue, block)
        a = CA.addr(kAudioStreamPropertyPhysicalFormat)
        AudioObjectRemovePropertyListenerBlock(listenedStream, &a, listenerQueue, block)
        formatListener = nil
    }

    /// Engine thread: a format change seen by the listener (or the periodic check) is re-confirmed.
    private func checkFormat() {
        guard procB != nil, !inRoutine else { return }
        let (_, vf) = CA.physicalAndVirtual(dacOut)
        let changed = formatDirty.load(ordering: .acquiring) != 0 || !CA.same(vf, writtenFormat)
        guard changed else { return }
        log("DAC format changed (virt \(CA.fmt(vf))); B muted, re-confirming")
        outFormat.store(0, ordering: .releasing)
        curRate = CA.nominal(dac)
        updateOutFormat()
    }

    private func tearDownDAC() {
        volume.stop()
        removeFormatListener()
        outFormat.store(0, ordering: .releasing)
        if let p = procB {
            AudioDeviceStop(dac, p)
            AudioDeviceDestroyIOProcID(dac, p)
            procB = nil
        }
        if nonMixable {
            log("DAC mixable again: \(CA.setMixable(dac))")
            nonMixable = false
        }
        if hogged {
            var none = pid_t(-1)
            var a = CA.addr(kAudioDevicePropertyHogMode)
            let st = AudioObjectSetPropertyData(dac, &a, 0, nil, 4, &none)
            log("hog released: \(st), owner \(CA.hogOwner(dac))")
            hogged = false
        }
        RendererOutput.shared.set(dacName: nil)
    }

    /// Every exit path: IO stopped, DAC mixable and released, scalar reset, default output restored.
    private func tearDown(restoreDefault: Bool, resumeMusic: Bool) {
        let wasPlaying = resumeMusic && musicPlaying()
        if wasPlaying { _ = scripts.pause(); _ = wait(1) { !self.playing } }
        if let p = procA {
            AudioDeviceStop(ls, p)
            AudioDeviceDestroyIOProcID(ls, p)
            procA = nil
        }
        tearDownDAC()
        if ls != 0 { log("virtual device scalar reset: \(CA.setScalar(ls, 1.0, Self.kRateScalar))") }
        // the default the user had (with a Selected Device the DAC can be another device)
        let back = defaultBefore != 0 && defaultBefore != ls && CA.hasOutput(defaultBefore) ? defaultBefore : dac
        if restoreDefault, back != 0, back != ls, CA.defaultOutput() == ls {
            log("default output restored to \(CA.string(back, kAudioObjectPropertyName)): \(CA.setDefaultOutput(back))")
            // coreaudiod re-evaluates its preferred default after the hog release and format change,
            // with the virtual device still first in its list (the update is asynchronous): in trial
            // m3 it put the virtual device back 48 ms after the restore. Hold the restore for 3 s.
            var resets = 0
            let end = Date().addingTimeInterval(3)
            while Date() < end {
                Thread.sleep(forTimeInterval: 0.05)
                if CA.defaultOutput() == ls {
                    resets += 1
                    log("coreaudiod put the virtual device back as the default; restoring again: \(CA.setDefaultOutput(back))")
                }
            }
            log("default output after 3 s: \(CA.string(CA.defaultOutput(), kAudioObjectPropertyName))\(resets > 0 ? " (\(resets) re-restores)" : "")")
        }
        if restoreDefault {
            attach(false)
            UserDefaults.standard.removeObject(forKey: Self.ownsOutputKey)
        }
        if wasPlaying { playChecked() }
    }

    /// True with plug-in 1.0 (no 'LSac': nothing to lose).
    private func isAttached() -> Bool {
        var a = CA.addr(Self.kAttached)
        guard ls != 0, AudioObjectHasProperty(ls, &a) else { return true }
        var v: Unmanaged<CFPropertyList>?; var z = UInt32(MemoryLayout<CFPropertyList?>.size)
        guard AudioObjectGetPropertyData(ls, &a, 0, nil, &z, &v) == noErr, let n = v?.takeRetainedValue() as? NSNumber else { return false }
        return n.int32Value == getpid()
    }

    /// Attached, and the virtual device is the default output (before Music plays again).
    private func reclaimDefault() {
        if !isAttached() { attach(true) }
        if CA.defaultOutput() != ls { log("default output was \(CA.string(CA.defaultOutput(), kAudioObjectPropertyName)); back to the virtual device: \(CA.setDefaultOutput(ls))") }
    }

    /// Plug-in 1.1+: the device can be the default output only while attached.
    private func attach(_ on: Bool) {
        var a = CA.addr(Self.kAttached)
        guard ls != 0, AudioObjectHasProperty(ls, &a) else {
            if on { log("virtual device has no 'LSac' (plug-in older than 1.1): it stays eligible as the default output after the engine stops; update it from the menu") }
            return
        }
        log("\(on ? "attached" : "detached") (pid \(on ? getpid() : 0)): \(CA.setCFNumber(ls, Self.kAttached, NSNumber(value: on ? Int32(getpid()) : 0)))")
    }

    /// Music may not start when told to play right after the default output changed: check, retry.
    private func playChecked() {
        for attempt in 1...4 {
            _ = scripts.play()
            if wait(2, until: { self.playing }) { return }
            log("play attempt \(attempt): Music isn't playing")
        }
    }

    // MARK: - Music events

    private func handleInfo(_ info: [AnyHashable: Any], at: Date) {
        let state = info["Player State"] as? String ?? "?"
        let name = info["Name"] as? String ?? ""
        // stations and Browse streams have no PersistentID: tell tracks apart by name
        let pid = (info["PersistentID"] as? NSNumber)?.int64Value ?? (name.isEmpty ? nil : Int64(truncatingIfNeeded: name.hashValue))
        log("playerInfo: \(state) \(name)")
        playing = state == "Playing"
        guard !inRoutine else { return } // our own pause/play
        if steppedAside {
            // Music plays straight to the DAC now; the run loop takes the output back
            if playing, resumeInfo == nil { resumeInfo = (info, at) }
            return
        }
        // Music can post Playing with no name and no PersistentID just before the real track's
        // (Babyface bench, before YYZ). It is not a track: taking a decoder line for it released the
        // gate, and the real track played at the old rate until its own line came. If no real one
        // follows, the next decoder line (or 3 s) decides for it.
        if playing, name.isEmpty, info["PersistentID"] == nil {
            if gatePending, awaiting == nil { awaiting = ("(no name)", at, Date().addingTimeInterval(3)) }
            log("playerInfo without a name or PersistentID: not a track; gate \(gatePending ? "held" : "open")")
            return
        }
        if playing { gateWaitsForMusic = false; regateOnSilence = false }
        let armedOrLatched = armAt != nil || latchZeros.load(ordering: .acquiring) > 0 || latchedAt != nil
        if !playing {
            if pid == lastTrackID, armedOrLatched { disarm("\(state) on the same track") }
            // the next play waits at the gate until its track's rate is known
            if !gatePending { gatePending = true; gateMarkedAt = nil; gate.store(1, ordering: .releasing) }
            trimIdle.store(1, ordering: .releasing)
            return
        }
        trimIdle.store(0, ordering: .releasing)
        if pid == lastTrackID { // resume or seek
            let late = lateArmAt != nil
            if armedOrLatched { disarm("seek on the same track") }
            // the second arm's time moved with the pause or seek: take it from Music again
            if late, let left = scripts.remaining(), left > 1.5 { lateArmAt = Date().addingTimeInterval(left - 1.5); log("boundary latch re-timed: \(String(format: "%.2f", left - 1.5)) s") }
            releaseGate("same track")
            return
        }
        lastTrackID = pid
        settingsCheckDue = true // after the rate decision below: the loop runs it
        lateArmAt = nil
        lossyTrackAt = nil
        awaiting = nil
        // Only a decoder line that came after the previous track began can be this track's (its
        // pre-roll, or its own setup). In trial m1 an Apple Music stream reported Playing before its
        // decoder line, and the previous track's 20 s old line was taken for it.
        let prev = lastNewTrackAt
        lastNewTrackAt = at
        guard let line = decoderRates.last(where: { prev == nil || $0.date > prev! }) else {
            // A gapless successor can have its decoder set up before the previous track began (trial
            // m2: none logged for Wish You Were Here after Have a Cigar). A local file's own header
            // decides; a stream waits for its line.
            if let st = LocalTrack.currentStats(attempts: 3) {
                decide(st.sampleRate, lossless: true, seenAgo: 0, name: name + " (file header, no decoder line)", tPlay: at)
                return
            }
            awaiting = (name, at, Date().addingTimeInterval(3))
            log("new track \(name): no decoder line for it yet; \(gatePending ? "holding at the gate" : "playing on at \(Int(curRate)) Hz") until one comes (3 s)")
            return
        }
        decide(line.rate, lossless: line.lossless, seenAgo: at.timeIntervalSince(line.date), name: name, tPlay: at)
    }

    private func decide(_ rate: Float64, lossless: Bool, seenAgo: TimeInterval, name: String, tPlay: Date) {
        if !lossless { lossyTrackAt = Date() }
        let need = neededRate(rate)
        log("new track \(name): decoder \(rate) Hz \(lossless ? "lossless" : "lossy") (seen \(String(format: "%.3f", seenAgo)) s before Playing), DAC \(Int(curRate)) Hz\(need.map { " -> switch to \(Int($0))" } ?? "")")
        if let r = need {
            switchRate(r, name: name, tPlay: tPlay)
        } else {
            if latchedAt != nil || latchZeros.load(ordering: .acquiring) > 0 || armAt != nil { disarm("same rate after all") }
            releaseGate("same rate", name: name, tPlay: tPlay)
        }
    }

    private func handleLine(_ line: String, at: Date) {
        guard let r = line.range(of: "Input format:") else { return }
        let rest = line[r.upperBound...]
        guard let hz = rest.range(of: #"[0-9]+ Hz"#, options: .regularExpression), let rate = Float64(rest[hz].dropLast(3)) else { return }
        let lossless = line.contains("lac")
        let bits = rest.range(of: #"from [0-9]+-bit source"#, options: .regularExpression).flatMap { Int(rest[$0].dropFirst(5).prefix { $0.isNumber }) }
        if decoderRates.last?.rate != rate || at.timeIntervalSince(decoderRates.last!.date) > 0.5 {
            log("decoder: \(rate) Hz \(bits.map { "\($0)-bit " } ?? "")(\(lossless ? "lossless" : "lossy"))")
        }
        // Apple Music streams can start on a lossy 48k decoder and set up the lossless one seconds later.
        if lossless, let t = lossyTrackAt, at.timeIntervalSince(t) < 10 { pendingUpgrade = (rate, bits); lossyTrackAt = nil }
        decoderRates.append((at, rate, bits, lossless))
        if decoderRates.count > 200 { decoderRates.removeFirst(100) }
        if let aw = awaiting, !inRoutine {
            awaiting = nil
            decide(rate, lossless: lossless, seenAgo: -at.timeIntervalSince(aw.tPlay), name: aw.name, tPlay: aw.tPlay)
            return
        }
        // A decoder for another rate while playing: the next track's pre-roll (8-12 s before the end:
        // arm the latch 1.5 s before it) or a user skip (arm now; Music leaves zeros between tracks).
        // Lines right after a track began are its own decoder (streams set it up after Playing).
        guard !inRoutine, playing, awaiting == nil, pendingUpgrade == nil, armAt == nil, latchedAt == nil,
              latchZeros.load(ordering: .acquiring) == 0, marker.load(ordering: .acquiring) < 0,
              at.timeIntervalSince(lastNewTrackAt ?? .distantPast) > 2, neededRate(rate) != nil else { return }
        let left = scripts.remaining() ?? 0
        let delay = left > 13 ? 0 : max(0, left - 1.5)
        armAt = Date().addingTimeInterval(delay)
        // More than 13 s left: a skip (Music leaves zeros now), or a pre-roll set up early (Babyface
        // bench: 105 s before the end of a streamed track; the 5 s arm expired and the boundary cut
        // at the play position). Cover both: arm now, and again 1.5 s before the end.
        lateArmAt = left > 13 ? Date().addingTimeInterval(left - 1.5) : nil
        log("next track needs \(Int(rate)) Hz; \(String(format: "%.2f", left)) s left, arming the boundary latch in \(String(format: "%.2f", delay)) s\(lateArmAt != nil ? " and again in \(String(format: "%.2f", left - 1.5)) s" : "")")
    }

    private func tickLatchAndGate() {
        if let aw = awaiting, Date() > aw.until {
            awaiting = nil
            log("no decoder line for \(aw.name) within 3 s; playing at \(Int(curRate)) Hz")
            if latchedAt != nil || armAt != nil || latchZeros.load(ordering: .acquiring) > 0 { disarm("no rate") }
            releaseGate("no decoder line")
        }
        regateIfSilent()
        if let l = lateArmAt, Date() >= l, armAt == nil, armedAt == nil, latchedAt == nil, !inRoutine {
            lateArmAt = nil
            armAt = Date()
            log("pre-roll came early; arming the boundary latch again")
        }
        if let a = armAt, Date() >= a {
            armAt = nil
            latchZeros.store(max(Int(0.01 * curRate), 1), ordering: .releasing)
            armedAt = Date()
            log("boundary latch armed at in frame \(inFrames.load(ordering: .relaxed))")
        }
        let m = marker.load(ordering: .acquiring)
        if let a = armedAt, m < 0, Date().timeIntervalSince(a) > 5 {
            latchZeros.store(0, ordering: .releasing); armedAt = nil
            log("no boundary within 5 s; disarmed")
        }
        if m >= 0, armedAt != nil, latchedAt == nil, !gatePending {
            armedAt = nil; latchedAt = Date()
            log("latched at ring \(m) (fill \(ring.fill))")
        }
        if let l = latchedAt, Date().timeIntervalSince(l) > 4 { disarm("latched 4 s without a new track") }
        // a marker nobody owns (A set it just as the gate or latch was released): let B go on
        if m >= 0, !gatePending, latchedAt == nil, armedAt == nil {
            if let s = strayMarkerAt { if Date().timeIntervalSince(s) > 0.5 { strayMarkerAt = nil; command.store(1, ordering: .releasing); log("stray marker at ring \(m); released") } }
            else { strayMarkerAt = Date() }
        } else { strayMarkerAt = nil }
        if procA != nil, !inputSeen, let s = setUpAt, Date().timeIntervalSince(s) > 3 {
            inputSeen = true
            if aCycles.load(ordering: .relaxed) == 0 { log("no input IO from the virtual device 3 s after setup (Microphone permission prompt pending?)") }
        }
        if gatePending, m >= 0 {
            if gateMarkedAt == nil { gateMarkedAt = Date(); log("gate: output started at ring \(m); waiting for the track's rate") }
            // another app's sound, or Music never reported Playing
            let limit = gateWaitsForMusic ? 4.0 : 1.5
            if !playing, let g = gateMarkedAt, Date().timeIntervalSince(g) > limit { releaseGate("no Playing within \(limit) s"); regateOnSilence = true }
        }
    }

    /// Another app's sound (or Music's tail after a quit) opened the gate while Music wasn't playing:
    /// Babyface bench, Kashmir then started ungated. Close the gate after 0.3 s of silence.
    private func regateIfSilent() {
        guard regateOnSilence, !gatePending, !playing, !inRoutine else { return }
        let silent = ring.written - lastNZ.load(ordering: .acquiring)
        guard silent >= Int(0.3 * curRate) else { return }
        regateOnSilence = false
        gatePending = true; gateMarkedAt = nil; gate.store(1, ordering: .releasing)
        log("gate closed again after \(silent * 1000 / max(Int(curRate), 1)) ms of silence")
    }

    /// Music idle for `after` seconds: give the DAC and the default output back, as a clean stop does
    /// (hog released, mixable, emulated mute undone, the previous default restored, the virtual
    /// device detached), and keep listening. Other apps then play to the DAC directly and the Sound
    /// menu works (picking a hogged DAC there hangs Control Center).
    private func stepAside(after: TimeInterval) {
        if armAt != nil || armedAt != nil || latchedAt != nil || latchZeros.load(ordering: .acquiring) > 0 { disarm("stepping aside") }
        lateArmAt = nil; awaiting = nil; pendingUpgrade = nil
        log("Music idle \(Int(after)) s: stepping aside (DAC and default output given back)")
        tearDown(restoreDefault: true, resumeMusic: false)
        procA = nil
        steppedAside = true
    }

    /// Music started playing while stepped aside (straight to the DAC): pause it, take the output
    /// back, then the switch routine sets the track's rate, rewinds to where the play began and plays.
    private func resumeFromIdle(_ info: [AnyHashable: Any], at: Date) {
        let name = info["Name"] as? String ?? "(current track)"
        log("playback began while stepped aside (\(name)); taking the output back")
        inRoutine = true
        _ = scripts.pause()
        let pausedAt = Date()
        _ = wait(1) { !self.playing }
        inRoutine = false
        steppedAside = false
        guard setUp() else {
            log("setup failed; staying stepped aside")
            steppedAside = true
            _ = scripts.play()
            return
        }
        // the rate this track needs: its newest decoder line (Music decoded it before pausing), else
        // the local file's header; the DAC's current rate if neither says
        let recent = decoderRates.last.flatMap { Date().timeIntervalSince($0.date) < 30 ? $0.rate : nil }
        let rate = recent ?? LocalTrack.currentStats(attempts: 2)?.sampleRate
        let target = rate.flatMap { neededRate($0) } ?? curRate
        lastTrackID = (info["PersistentID"] as? NSNumber)?.int64Value ?? (name.isEmpty ? nil : Int64(truncatingIfNeeded: name.hashValue))
        lastNewTrackAt = at
        switchRate(target, name: name, tPlay: at, pausedAt: pausedAt)
    }

    private func disarm(_ why: String) {
        let wasLatched = latchedAt != nil || marker.load(ordering: .acquiring) >= 0
        armAt = nil; armedAt = nil; latchedAt = nil; lateArmAt = nil
        latchZeros.store(0, ordering: .releasing)
        if wasLatched || marker.load(ordering: .acquiring) >= 0 { command.store(1, ordering: .releasing) }
        log("\(why); \(wasLatched ? "latch released" : "disarmed")")
    }

    private func releaseGate(_ why: String, name: String = "(current track)", tPlay: Date? = nil) {
        guard gatePending else { return }
        if playing, marker.load(ordering: .acquiring) >= 0, let g = gateMarkedAt, Date().timeIntervalSince(g) > 0.5 {
            // held long (the DAC coming up, a stream's late decoder line): continuing would keep that
            // much latency until the next pause, so start over from where the play began
            log("gate held \(String(format: "%.0f", Date().timeIntervalSince(g) * 1000)) ms (\(why)); restarting the play")
            switchRate(curRate, name: name, tPlay: tPlay ?? g)
            return
        }
        gatePending = false
        gate.store(0, ordering: .releasing)
        if marker.load(ordering: .acquiring) >= 0 {
            command.store(1, ordering: .releasing)
            let held = gateMarkedAt.map { String(format: "%.0f ms", Date().timeIntervalSince($0) * 1000) } ?? "< 10 ms"
            log("gate released (\(why)) \(held) after the output started")
        }
        gateMarkedAt = nil
    }

    /// The DAC rate the track needs (this app's format choice: nearest supported, multiples
    /// preference), or nil if the devices already run at it.
    private func neededRate(_ rate: Float64) -> Float64? {
        guard let device = AudioDevice.lookup(by: dac),
              let fmt = outputDevices.suitableFormat(for: CMPlayerStats(sampleRate: rate, bitDepth: 24, date: Date(), priority: 5), device: device) else { return nil }
        guard fmt.mSampleRate != curRate else { return nil }
        guard CA.nominalRates(ls).contains(fmt.mSampleRate) else {
            log("track needs \(Int(fmt.mSampleRate)) Hz, which the virtual device can't run at; staying at \(Int(curRate)) Hz")
            return nil
        }
        return fmt.mSampleRate
    }

    // MARK: - The switch routine

    /// `pausedAt`: when Music was paused, if a caller paused it already (resume from idle).
    private func switchRate(_ r: Float64, name: String, tPlay: Date, pausedAt: Date? = nil) {
        inRoutine = true
        defer { inRoutine = false }
        switches += 1
        let t = Date()
        let pauseTime = pausedAt ?? t // Music's position stops here; what it played is measured to here
        // Music can start playing before it posts Playing (after a relaunch): the gate saw the first
        // frame earlier, and that is where the play began
        let tPlay = gatePending ? min(tPlay, gateMarkedAt ?? tPlay) : tPlay
        _ = scripts.pause()
        var m = marker.load(ordering: .acquiring)
        let how = m < 0 ? "not latched: cut at the play position" : (gatePending ? "held at the gate" : "latched at the old track's end")
        if m < 0 { atBoundary.store(0, ordering: .releasing); m = ring.readPos; marker.store(m, ordering: .releasing) }
        latchZeros.store(0, ordering: .releasing); gate.store(0, ordering: .releasing)
        gatePending = false; gateMarkedAt = nil; armAt = nil; armedAt = nil; latchedAt = nil
        let reached = wait(1) { self.atBoundary.load(ordering: .acquiring) != 0 }
        let change = r != curRate || CA.nominal(dac) != r
        log("switch \(switches): \(name) \(change ? "needs \(Int(r)) Hz (DAC \(Int(curRate)))" : "restarts at \(Int(r)) Hz (no rate change)"); \(how); paused; boundary \(reached ? "reached" : "NOT reached") \(ms(t))")
        dropInput.store(1, ordering: .releasing) // the DAC can take seconds; don't let the ring overflow with zeros
        if change { outFormat.store(0, ordering: .releasing); applyRate(r) }
        recorder?.segmentIn(inFrames.load(ordering: .acquiring), r)
        let td = Date()
        if change {
            let target = dacFormat(r) ?? AudioStreamBasicDescription(mSampleRate: r, mFormatID: kAudioFormatLinearPCM, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: 0, mBitsPerChannel: 0, mReserved: 0)
            let ready = DeviceFormat.waitUntilReady(dac, format: target, checkBitDepth: target.mBitsPerChannel != 0, timeout: 12, stalled: { [unowned self] in
                guard let p = self.procB else { return }
                self.log("  DAC keeps stopping; restarting B")
                AudioDeviceStop(self.dac, p); AudioDeviceStart(self.dac, p)
            })
            log("  DAC \(ready ? "ready" : "NOT ready") after \(ms(td)): \(CA.formats(dacOut))")
            updateOutFormat()
        }
        command.store(2, ordering: .releasing)
        _ = wait(1) { self.command.load(ordering: .acquiring) == 0 }
        dropInput.store(0, ordering: .releasing)
        let seg = outSegmentAt.exchange(-1, ordering: .acquiringAndReleasing)
        recorder?.segmentOut(seg >= 0 ? seg : outFrames.load(ordering: .acquiring), r)
        resetLock()
        let pos = scripts.position() ?? 0
        // measured to the pause, not to now: the paused position doesn't advance during the switch (it
        // was measured to now, so a mid-track switch replayed the switch's own duration, ~1.5 s)
        let played = pauseTime.timeIntervalSince(tPlay) + 0.05
        var startPos = pos - played - 0.1
        // near the start is the start: the estimate can come up short (0.530 on the Babyface bench),
        // and a restart that skips a track's first half-second is heard
        if startPos < 2 { startPos = 0 }
        _ = scripts.setPosition(startPos)
        reclaimDefault() // never let Music start on whatever coreaudiod fell back to
        _ = scripts.play()
        log("  rewound to \(String(format: "%.3f", startPos)) (was \(String(format: "%.3f", pos)), played ~\(String(format: "%.3f", played)) s), play; switch \(switches) done \(ms(t)) after the request")
    }

    // MARK: - Devices

    private func checkDevicesAndMusic() {
        guard !inRoutine else { return }
        if steppedAside {
            if lastTrackID != nil, !musicRunning() { log("Music quit (engine stepped aside)"); lastTrackID = nil }
            return
        }
        if lastTrackID != nil, !musicRunning() {
            log("Music quit; the next play waits at the gate for its own decoder line")
            lastTrackID = nil
            playing = false
            // Relaunched Music played ~1.6 s before posting Playing (Babyface bench), and the last
            // decoder lines belong to the old session (one was taken 264 s later): gate the next
            // play, wait longer than usual for its Playing, and forget the old lines.
            if armAt != nil || armedAt != nil || latchedAt != nil || latchZeros.load(ordering: .acquiring) > 0 { disarm("Music quit") }
            awaiting = nil; pendingUpgrade = nil; lossyTrackAt = nil
            decoderRates = []; lastNewTrackAt = nil
            if !gatePending { gatePending = true; gateMarkedAt = nil; gate.store(1, ordering: .releasing) }
            gateWaitsForMusic = true
            trimIdle.store(1, ordering: .releasing)
        }
        // the plug-in's device vanished (coreaudiod restarted?): start over
        if CA.string(ls, kAudioDevicePropertyDeviceUID) != Self.deviceUID {
            log("virtual device gone; setting up again")
            procA = nil
            tearDown(restoreDefault: false, resumeMusic: false)
            if !setUp() { log("setup failed") }
            return
        }
        // The plug-in drops the attachment if it thinks we went away (it can misjudge a
        // reconfiguration); coreaudiod then moves the default off the virtual device. That move is
        // ours, not the user's: re-attach and take the default back instead of following it.
        if !isAttached() {
            log("attachment lost; re-attaching")
            reclaimDefault()
            return
        }
        let dacPresent = CA.string(dac, kAudioDevicePropertyDeviceUID) == dacUID
        let d = CA.defaultOutput()
        if !dacPresent {
            log("DAC gone")
            procB = nil; hogged = false; nonMixable = false
            if let f = Self.fallbackOutput(excluding: ls) {
                log("playing to \(CA.string(f, kAudioObjectPropertyName)) instead")
                follow(f)
            }
            return
        }
        if let s = selectedDAC() {
            // Selected Device decides: follow a new selection; a new default output doesn't move the
            // engine, it only gets the default back (the audio keeps going to the selection)
            if s != dac {
                log("Selected Device changed to \(CA.string(s, kAudioObjectPropertyName)); following it")
                follow(s)
            } else if d != ls, d != 0 {
                defaultBefore = d
                log("default output changed to \(CA.string(d, kAudioObjectPropertyName)); Selected Device \(CA.string(dac, kAudioObjectPropertyName)) stays the DAC; default -> virtual device: \(CA.setDefaultOutput(ls))")
            }
        } else if d != ls, d != 0 {
            defaultBefore = d
            if d == dac {
                // the DAC itself was picked (it stays listed in the Sound menu while hogged): it's
                // already where the audio goes; setting it up again would only cost a gap
                log("default output set to the DAC \(CA.string(d, kAudioObjectPropertyName)); default -> virtual device: \(CA.setDefaultOutput(ls))")
            } else {
                // the user (or the system) picked another output: play to it through the virtual device
                log("default output changed to \(CA.string(d, kAudioObjectPropertyName)); following it")
                follow(d)
            }
        }
    }

    /// Plays to `d` from now on: pause, give the old DAC back, set up the new one, play.
    private func follow(_ d: AudioObjectID) {
        let wasPlaying = musicPlaying()
        if wasPlaying { _ = scripts.pause(); _ = wait(1) { !self.playing } }
        tearDownDAC()
        if setUpDAC(d) {
            log("default output -> virtual device: \(CA.setDefaultOutput(ls))")
        } else {
            // never leave the system on a virtual device nobody plays out
            tearDownDAC()
            log("DAC setup failed; default output stays \(CA.string(d, kAudioObjectPropertyName)): \(CA.setDefaultOutput(d))")
        }
        if wasPlaying { playChecked() }
    }

    // MARK: - Clock lock

    private func resetLock() {
        phase0 = nil; integ = 0; dacScalarEst = 0; refillAsked = false
        lockAfterCycles = (aCycles.load(ordering: .relaxed) + 8, bCycles.load(ordering: .relaxed) + 8)
    }

    /// Every 0.5 s: phase = virtual sample time now - DAC sample time now, error vs the phase at lock;
    /// virtual scalar = DAC's HAL scalar (EMA) * (1 + P + I), within +-300 ppm.
    private func pll() {
        guard procB != nil, !inRoutine, aCycles.load(ordering: .relaxed) >= lockAfterCycles.0, bCycles.load(ordering: .relaxed) >= lockAfterCycles.1,
              let (sA, hA, _) = stampA.get(), let (sB, hB, rB) = stampB.get(), rB > 0.9, rB < 1.1 else { return }
        let tpf = ticksPerSec / curRate
        let h = Double(mach_absolute_time())
        let phase = (sA + (h - hA) / (tpf * lsScalar)) - (sB + (h - hB) / (tpf * rB))
        // After a switch the DAC's HAL scalar converges for seconds (1.00115 at 88.2k in trial s2, and
        // seeding on it walked the phase to -285 frames). Until it is within 100 ppm the virtual
        // device keeps its last scalar (same crystal) and nothing is locked.
        if phase0 == nil && abs(rB - 1) > 100e-6 {
            if !waitingForScalar { waitingForScalar = true; log("clock: DAC scalar \(String(format: "%.6f", rB)) not settled; waiting to lock") }
            return
        }
        waitingForScalar = false
        // The lock holds the phase it starts from, so it holds the ring's fill too. After the follow to
        // the MacBook speakers the ring had drained (6656 frames under) and it locked at fill 0: no
        // margin, for good. Below half the target, refill first (B plays silence until it's back).
        if phase0 == nil && ring.fill < targetFill / 2 {
            if !refillAsked {
                refillAsked = true
                refill.store(1, ordering: .releasing)
                log("clock: ring at \(ring.fill) frames before the lock (target \(targetFill)); refilling first")
            }
            return
        }
        refillAsked = false
        dacScalarEst = dacScalarEst == 0 ? rB : dacScalarEst + 0.1 * (rB - dacScalarEst)
        if phase0 == nil { phase0 = phase; log("clock lock: phase0 \(String(format: "%.3f", phase)), fill \(ring.fill), cycles A \(aCycles.load(ordering: .relaxed)) B \(bCycles.load(ordering: .relaxed))") }
        let err = phase - phase0!
        if abs(err) > 1000 {
            log("clock: phase jumped \(String(format: "%.0f", err)) frames (a device restarted?); re-locking")
            resetLock()
            return
        }
        let kp = 1 / (tau * curRate)
        integ = max(-300e-6, min(300e-6, integ + kp * err * 0.5 / (4 * tau)))
        let corr = max(-300e-6, min(300e-6, kp * err + integ))
        let s = dacScalarEst * (1 + corr)
        if CA.setScalar(ls, s, Self.kRateScalar) == noErr { lsScalar = s }
        recorder?.clock(fill: ring.fill, phase: phase, err: err, dac: rB, lsSet: lsScalar,
                        over: ring.overruns.load(ordering: .relaxed), under: ring.underruns.load(ordering: .relaxed),
                        a: aCycles.load(ordering: .relaxed), b: bCycles.load(ordering: .relaxed), rate: curRate)
    }

    // MARK: - IO threads

    /// A: the virtual device's loopback input (2 ch float32) -> ring.
    private func renderA(_ inInput: UnsafePointer<AudioBufferList>, _ inTime: UnsafePointer<AudioTimeStamp>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
        guard let b = ins.first, let d = b.mData, b.mNumberChannels == 2 else { return }
        let n = Int(b.mDataByteSize) / 8
        let f = d.assumingMemoryBound(to: Float.self)
        let w0 = ring.written
        if marker.load(ordering: .acquiring) < 0 {
            let lz = latchZeros.load(ordering: .acquiring)
            if lz > 0 {
                for i in 0..<n {
                    if f[i * 2] == 0 && f[i * 2 + 1] == 0 { zeroRun += 1 } else { zeroRun = 0 }
                    if zeroRun >= lz {
                        zeroRun = 0
                        if latchZeros.compareExchange(expected: lz, desired: 0, ordering: .acquiringAndReleasing).exchanged {
                            atBoundary.store(0, ordering: .relaxed)
                            marker.store(w0 + i + 1, ordering: .releasing)
                        }
                        break
                    }
                }
            } else if gate.load(ordering: .acquiring) != 0 {
                zeroRun = 0
                for i in 0..<n where f[i * 2] != 0 || f[i * 2 + 1] != 0 {
                    if gate.compareExchange(expected: 1, desired: 0, ordering: .acquiringAndReleasing).exchanged {
                        atBoundary.store(0, ordering: .relaxed)
                        marker.store(w0 + i, ordering: .releasing)
                    }
                    break
                }
            } else { zeroRun = 0 }
        }
        var i = n - 1
        while i >= 0 && f[i * 2] == 0 && f[i * 2 + 1] == 0 { i -= 1 }
        if i >= 0 { lastNZ.store(w0 + i + 1, ordering: .releasing) }
        if dropInput.load(ordering: .relaxed) == 0 { ring.write(f, n) }
        let t = inTime.pointee
        stampA.put(t.mSampleTime + Double(n), Double(t.mHostTime), t.mRateScalar) // end of this buffer
        recorder?.input(f, n, sample: t.mSampleTime, host: t.mHostTime)
        inFrames.wrappingAdd(n, ordering: .releasing)
        aCycles.wrappingAdd(1, ordering: .relaxed)
    }

    /// B: ring -> the DAC's stereo pair, in its virtual format.
    private func renderB(_ outOutput: UnsafeMutablePointer<AudioBufferList>, _ outTime: UnsafePointer<AudioTimeStamp>) {
        let t = outTime.pointee
        stampB.put(t.mSampleTime, Double(t.mHostTime), t.mRateScalar)
        let outs = UnsafeMutableAudioBufferListPointer(outOutput)
        let fmt = OutFormat(packed: outFormat.load(ordering: .acquiring))
        let muted = fmt.bytes == 0 // format not confirmed: run the ring as usual, write zeros
        guard let b0 = outs.first, b0.mNumberChannels > 0 else { return }
        let n = min(Int(b0.mDataByteSize) / (muted ? 4 : fmt.bytes) / Int(b0.mNumberChannels), Self.maxFrames)
        switch command.exchange(0, ordering: .acquiringAndReleasing) {
        case 1: // go on past the marker
            marker.store(-1, ordering: .releasing); atBoundary.store(0, ordering: .releasing)
        case 2: // the DAC runs at the new rate: drop the wrong-rate start and the pause fade, refill
            marker.store(-1, ordering: .releasing); atBoundary.store(0, ordering: .releasing)
            ring.trim(keep: 0); bPlaying = false
            outSegmentAt.store(outFrames.load(ordering: .relaxed), ordering: .releasing)
        default: break
        }
        if refill.exchange(0, ordering: .acquiringAndReleasing) != 0 { bPlaying = false }
        let m = marker.load(ordering: .acquiring)
        // drop only zeros: the startup backlog, and Music's silence while it isn't playing
        if (!bPlaying || trimIdle.load(ordering: .relaxed) != 0), m < 0, lastNZ.load(ordering: .acquiring) <= ring.readPos, ring.fill > targetFill {
            ring.trim(keep: targetFill)
        }
        if !bPlaying && ring.fill >= targetFill { bPlaying = true }
        if bPlaying {
            ring.read(scratch, n, limit: m)
            if m >= 0 && ring.readPos >= m { atBoundary.store(1, ordering: .releasing) }
        } else {
            scratch.update(repeating: 0, count: n * 2)
        }
        if muted {
            for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        } else {
            fmt.write(outs, scratch, n)
        }
        recorder?.output(scratch, n, sample: t.mSampleTime, host: t.mHostTime)
        outFrames.wrappingAdd(n, ordering: .releasing)
        bCycles.wrappingAdd(1, ordering: .relaxed)
    }

    // MARK: - Helpers

    private func musicPlaying() -> Bool {
        musicRunning() && scripts.playerState() == "playing"
    }

    private func waitPlain(_ seconds: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.005) }
        return cond()
    }

    private func ms(_ t: Date) -> String { String(format: "%.3f s", Date().timeIntervalSince(t)) }

    private func log(_ s: String) { log.write(s) }
}

// MARK: - Output format for B

/// How B writes a stereo float frame into the DAC's buffers, packed into one Int for the IO thread.
/// Advanced > Inter-sample Overshoot Protection: a fixed -3.0 dB (x0.7079) on Exclusive Mode's output
/// to the DAC, for loud masters whose reconstructed waveform peaks above full scale between samples
/// (clipping in the DAC's filter). Off by default; when on, the output is no longer bit-perfect.
/// Off, nothing is multiplied. Read by both engines' IO threads.
final class OvershootProtection: @unchecked Sendable {
    static let shared = OvershootProtection()
    static let gain: Float = 0.70794578 // 10^(-3/20)
    private let on = Atomic<Int>(0)
    var isOn: Bool { on.load(ordering: .relaxed) != 0 }
    func set(_ value: Bool) { on.store(value ? 1 : 0, ordering: .relaxed) }
}

struct OutFormat: CustomStringConvertible {
    var isFloat = true
    var bytes = 4          // per sample
    var bits = 32
    var alignedHigh = false
    var nonInterleaved = false
    var left = 0, right = 1

    init(asbd f: AudioStreamBasicDescription, left: Int, right: Int) {
        isFloat = f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        nonInterleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let ch = max(Int(f.mChannelsPerFrame), 1)
        bytes = nonInterleaved ? Int(f.mBytesPerFrame) : Int(f.mBytesPerFrame) / ch
        if bytes <= 0 { bytes = isFloat ? 4 : max(Int(f.mBitsPerChannel) / 8, 2) }
        bits = f.mBitsPerChannel > 0 ? Int(f.mBitsPerChannel) : bytes * 8
        alignedHigh = f.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0
        self.left = left; self.right = right
    }

    init(packed p: Int) {
        isFloat = p & 1 != 0
        nonInterleaved = p & 2 != 0
        alignedHigh = p & 4 != 0
        bytes = (p >> 4) & 0xF
        bits = (p >> 8) & 0x3F
        left = (p >> 16) & 0xFF
        right = (p >> 24) & 0xFF
    }

    var packed: Int {
        (isFloat ? 1 : 0) | (nonInterleaved ? 2 : 0) | (alignedHigh ? 4 : 0) | (bytes << 4) | (bits << 8) | (left << 16) | (right << 24)
    }

    var description: String { "\(isFloat ? "float" : "int")\(bits) in \(bytes) bytes\(nonInterleaved ? " non-interleaved" : ""), channels \(left + 1)/\(right + 1)" }

    @inline(__always)
    func write(_ outs: UnsafeMutableAudioBufferListPointer, _ src: UnsafePointer<Float>, _ n: Int) {
        let scale = isFloat || bits < 2 ? 1 : Double(Int64(1) << (bits - 1))
        let lo = -scale, hi = scale - 1
        let reduce = OvershootProtection.shared.isOn, gain = OvershootProtection.gain
        let shift = alignedHigh ? bytes * 8 - bits : 0
        var base = 0
        for buf in outs {
            guard let d = buf.mData else { continue }
            memset(d, 0, Int(buf.mDataByteSize))
            let ch = Int(buf.mNumberChannels)
            let frames = min(n, Int(buf.mDataByteSize) / bytes / max(ch, 1))
            for c in 0..<ch {
                let g = base + c
                guard g == left || g == right else { continue }
                let s = g == left ? 0 : 1
                if isFloat {
                    let o = d.assumingMemoryBound(to: Float.self)
                    if reduce { for k in 0..<frames { o[k * ch + c] = src[k * 2 + s] * gain } }
                    else { for k in 0..<frames { o[k * ch + c] = src[k * 2 + s] } }
                } else {
                    for k in 0..<frames {
                        let x = reduce ? src[k * 2 + s] * gain : src[k * 2 + s]
                        let v = Int64(min(hi, max(lo, (Double(x) * scale).rounded()))) << shift
                        let at = d + (k * ch + c) * bytes
                        switch bytes {
                        case 2: at.storeBytes(of: Int16(truncatingIfNeeded: v), as: Int16.self)
                        case 3:
                            at.storeBytes(of: UInt8(truncatingIfNeeded: v), as: UInt8.self)
                            (at + 1).storeBytes(of: UInt8(truncatingIfNeeded: v >> 8), as: UInt8.self)
                            (at + 2).storeBytes(of: UInt8(truncatingIfNeeded: v >> 16), as: UInt8.self)
                        default: at.storeBytes(of: Int32(truncatingIfNeeded: v), as: Int32.self)
                        }
                    }
                }
            }
            base += ch
        }
    }
}

// MARK: - Ring and time stamps

/// Single-producer single-consumer stereo float ring (A writes, B reads; the consumer alone trims).
final class VRing: @unchecked Sendable {
    let size: Int
    private let data: UnsafeMutablePointer<Float>
    private let w = Atomic<Int>(0), r = Atomic<Int>(0)
    let overruns = Atomic<Int>(0), underruns = Atomic<Int>(0)

    init(frames: Int) {
        size = frames
        data = .allocate(capacity: frames * 2)
        data.initialize(repeating: 0, count: frames * 2)
    }

    deinit { data.deallocate() }

    var written: Int { w.load(ordering: .acquiring) }
    var readPos: Int { r.load(ordering: .acquiring) }
    var fill: Int { written - readPos }

    func write(_ src: UnsafePointer<Float>, _ count: Int) {
        let wi = w.load(ordering: .relaxed), rd = r.load(ordering: .acquiring)
        var n = count
        let space = size - (wi - rd)
        if n > space { overruns.wrappingAdd(n - space, ordering: .relaxed); n = space }
        let mask = size - 1
        for i in 0..<n { let k = ((wi + i) & mask) * 2; data[k] = src[i * 2]; data[k + 1] = src[i * 2 + 1] }
        w.store(wi + n, ordering: .releasing)
    }

    /// Reads n frames, never at or past `limit` (>= 0); zeros for the rest. Underruns count only
    /// frames missing below the limit.
    @discardableResult
    func read(_ dst: UnsafeMutablePointer<Float>, _ n: Int, limit: Int = -1) -> Int {
        let rd = r.load(ordering: .relaxed), wi = w.load(ordering: .acquiring)
        let allowed = limit >= 0 ? max(0, min(n, limit - rd)) : n
        let take = min(allowed, wi - rd)
        let mask = size - 1
        for i in 0..<take { let k = ((rd + i) & mask) * 2; dst[i * 2] = data[k]; dst[i * 2 + 1] = data[k + 1] }
        if take < n { (dst + take * 2).update(repeating: 0, count: (n - take) * 2) }
        if take < allowed { underruns.wrappingAdd(allowed - take, ordering: .relaxed) }
        r.store(rd + take, ordering: .releasing)
        return take
    }

    /// Consumer side: drop the oldest frames so at most `keep` remain.
    func trim(keep: Int) {
        let rd = r.load(ordering: .relaxed), wi = w.load(ordering: .acquiring)
        if wi - rd > keep { r.store(wi - keep, ordering: .releasing) }
    }
}

/// (sample time, host time, rate scalar) from an IO thread for the control thread; a seqlock so a
/// reader never pairs one cycle's sample time with another's host time.
final class VStamp: @unchecked Sendable {
    private let seq = Atomic<UInt64>(0)
    private let v = UnsafeMutablePointer<Double>.allocate(capacity: 3)

    init() { v.initialize(repeating: 0, count: 3) }
    deinit { v.deallocate() }

    func put(_ sample: Double, _ host: Double, _ scalar: Double) {
        let q = seq.load(ordering: .relaxed)
        seq.store(q + 1, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
        v[0] = sample; v[1] = host; v[2] = scalar
        seq.store(q + 2, ordering: .releasing)
    }

    func get() -> (Double, Double, Double)? {
        for _ in 0..<100 {
            let q1 = seq.load(ordering: .acquiring)
            if q1 & 1 != 0 { continue }
            let a = v[0], b = v[1], c = v[2]
            atomicMemoryFence(ordering: .acquiring)
            if seq.load(ordering: .relaxed) == q1 { return q1 == 0 ? nil : (a, b, c) }
        }
        return nil
    }
}

// MARK: - Debug recording

/// Debug recording, for offline analysis (scripts not included): <prefix>.in.f32 (what A read),
/// .out.f32 (what B played, as float), .cycles.txt / .in.cycles.txt (sample frames 0 host),
/// .segments.txt / .in.segments.txt (first frame, rate), .clock.csv. Streams to disk; enabled with
/// `defaults write <bundle id> RendererDebugRecord <prefix>` (+ RendererDebugRecordSeconds, 330).
final class VRecorder {
    private let prefix: String
    private let maxFrames: Int
    private let inRing = VRing(frames: 1 << 21), outRing = VRing(frames: 1 << 21)
    private let fIn: FileHandle, fOut: FileHandle, csv: FileHandle
    private let buf = UnsafeMutablePointer<Float>.allocate(capacity: (1 << 21) * 2)
    private let maxCycles: Int
    private let cycA: UnsafeMutablePointer<Double>, cycB: UnsafeMutablePointer<Double>
    private var nA = 0, nB = 0          // IO threads
    private var framesIn = 0, framesOut = 0
    private var segIn: [String] = [], segOut: [String] = []
    private let t0 = Date()

    static func fromDefaults(log: (String) -> Void) -> VRecorder? {
        guard let prefix = UserDefaults.standard.string(forKey: "RendererDebugRecord"), !prefix.isEmpty else { return nil }
        let seconds = UserDefaults.standard.object(forKey: "RendererDebugRecordSeconds") as? Double ?? 330
        log("debug recording to \(prefix).* (\(Int(seconds)) s)")
        return VRecorder(prefix: prefix, seconds: seconds)
    }

    private init?(prefix: String, seconds: Double) {
        self.prefix = prefix
        maxFrames = Int(seconds * 192_000)
        maxCycles = Int(seconds * 192_000 / 64)
        for ext in ["in.f32", "out.f32"] { FileManager.default.createFile(atPath: "\(prefix).\(ext)", contents: nil) }
        FileManager.default.createFile(atPath: prefix + ".clock.csv", contents: "t,fill,phase,err,dacScalarHAL,lsScalarHAL,lsScalarSet,overruns,underruns,aCycles,bCycles,rate\n".data(using: .utf8))
        guard let a = FileHandle(forWritingAtPath: prefix + ".in.f32"), let b = FileHandle(forWritingAtPath: prefix + ".out.f32"),
              let c = FileHandle(forWritingAtPath: prefix + ".clock.csv") else { return nil }
        fIn = a; fOut = b; csv = c; csv.seekToEndOfFile()
        cycA = .allocate(capacity: maxCycles * 3); cycB = .allocate(capacity: maxCycles * 3)
    }

    @inline(__always) func input(_ f: UnsafePointer<Float>, _ n: Int, sample: Double, host: UInt64) {
        inRing.write(f, n)
        if nA < maxCycles { cycA[nA * 3] = sample; cycA[nA * 3 + 1] = Double(n); cycA[nA * 3 + 2] = Double(host); nA += 1 }
    }

    @inline(__always) func output(_ f: UnsafePointer<Float>, _ n: Int, sample: Double, host: UInt64) {
        outRing.write(f, n)
        if nB < maxCycles { cycB[nB * 3] = sample; cycB[nB * 3 + 1] = Double(n); cycB[nB * 3 + 2] = Double(host); nB += 1 }
    }

    deinit { buf.deallocate(); cycA.deallocate(); cycB.deallocate() }

    func segmentIn(_ frame: Int, _ rate: Double) { segIn.append("\(frame) \(rate)") }
    func segmentOut(_ frame: Int, _ rate: Double) { segOut.append("\(frame) \(rate)") }

    func clock(fill: Int, phase: Double, err: Double, dac: Double, lsSet: Double, over: Int, under: Int, a: Int, b: Int, rate: Double) {
        let line = String(format: "%.2f,%d,%.2f,%.3f,%.9f,%.9f,%.9f,%d,%d,%d,%d,%.0f\n", Date().timeIntervalSince(t0), fill, phase, err, dac, lsSet, lsSet, over, under, a, b, rate)
        csv.write(line.data(using: .utf8)!)
    }

    func drain() {
        for (r, f, isIn) in [(inRing, fIn, true), (outRing, fOut, false)] {
            let n = r.fill
            guard n > 0 else { continue }
            r.read(buf, n)
            let done = isIn ? framesIn : framesOut
            let keep = max(0, min(n, maxFrames - done))
            if keep > 0 { f.write(Data(bytes: buf, count: keep * 8)) }
            if isIn { framesIn += n } else { framesOut += n }
        }
    }

    func finish() {
        drain()
        func cycles(_ c: UnsafeMutablePointer<Double>, _ n: Int, _ path: String) {
            var s = ""
            for i in 0..<n { s += String(format: "%.0f %.0f 0 %.0f\n", c[i * 3], c[i * 3 + 1], c[i * 3 + 2]) }
            FileManager.default.createFile(atPath: path, contents: s.data(using: .utf8))
        }
        cycles(cycB, nB, prefix + ".cycles.txt")
        cycles(cycA, nA, prefix + ".in.cycles.txt")
        FileManager.default.createFile(atPath: prefix + ".segments.txt", contents: (segOut.joined(separator: "\n") + "\n").data(using: .utf8))
        FileManager.default.createFile(atPath: prefix + ".in.segments.txt", contents: (segIn.joined(separator: "\n") + "\n").data(using: .utf8))
        try? fIn.close(); try? fOut.close(); try? csv.close()
    }
}

// MARK: - Core Audio helpers

enum CA {
    static func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func array<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _: T.Type) -> [T] {
        var a = a; var z: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &z) == noErr, z > 0 else { return [] }
        let n = Int(z) / MemoryLayout<T>.stride
        let p = UnsafeMutablePointer<T>.allocate(capacity: n); defer { p.deallocate() }
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &z, p) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: n))
    }

    static func string(_ obj: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
        guard obj != 0 else { return "" }
        var a = addr(s); var v: Unmanaged<CFString>?; var z = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &z, &v) == noErr else { return "" }
        return (v?.takeRetainedValue() as String?) ?? ""
    }

    static func devices() -> [AudioObjectID] { array(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDevices), AudioObjectID.self) }
    static func streams(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioStreamID] { array(d, addr(kAudioDevicePropertyStreams, scope), AudioStreamID.self) }
    static func hasOutput(_ d: AudioObjectID) -> Bool { !streams(d, kAudioObjectPropertyScopeOutput).isEmpty }

    static func transport(_ d: AudioObjectID) -> UInt32 {
        var t = UInt32(0); var a = addr(kAudioDevicePropertyTransportType); var z = UInt32(4)
        AudioObjectGetPropertyData(d, &a, 0, nil, &z, &t); return t
    }

    static func defaultOutput() -> AudioObjectID {
        var d = AudioObjectID(0); var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var z = UInt32(4)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &z, &d); return d
    }

    static func setDefaultOutput(_ d: AudioObjectID) -> OSStatus {
        var d = d; var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, 4, &d)
    }

    static func nominal(_ d: AudioObjectID) -> Float64 { DeviceFormat.nominalSampleRate(d) ?? 0 }

    static func setNominal(_ d: AudioObjectID, _ hz: Float64) -> OSStatus {
        var r = hz; var a = addr(kAudioDevicePropertyNominalSampleRate)
        return AudioObjectSetPropertyData(d, &a, 0, nil, 8, &r)
    }

    static func nominalRates(_ d: AudioObjectID) -> [Float64] {
        array(d, addr(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange.self).map { $0.mMinimum }
    }

    static func hogOwner(_ d: AudioObjectID) -> pid_t {
        var h = pid_t(0); var a = addr(kAudioDevicePropertyHogMode); var z = UInt32(4)
        AudioObjectGetPropertyData(d, &a, 0, nil, &z, &h); return h
    }

    static func availablePhysicalFormats(_ s: AudioStreamID) -> [AudioStreamRangedDescription] {
        array(s, addr(kAudioStreamPropertyAvailablePhysicalFormats), AudioStreamRangedDescription.self)
    }

    static func fmt(_ f: AudioStreamBasicDescription) -> String {
        "\(f.mSampleRate) Hz \(f.mChannelsPerFrame) ch \(f.mBitsPerChannel) bit flags \(f.mFormatFlags)"
    }

    static func formats(_ s: AudioStreamID) -> String {
        var pf = AudioStreamBasicDescription(), vf = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = addr(kAudioStreamPropertyPhysicalFormat); AudioObjectGetPropertyData(s, &a, 0, nil, &z, &pf)
        a = addr(kAudioStreamPropertyVirtualFormat); AudioObjectGetPropertyData(s, &a, 0, nil, &z, &vf)
        return "phys \(fmt(pf)) / virt \(fmt(vf))"
    }

    static func physicalAndVirtual(_ s: AudioStreamID) -> (AudioStreamBasicDescription, AudioStreamBasicDescription) {
        var pf = AudioStreamBasicDescription(), vf = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = addr(kAudioStreamPropertyPhysicalFormat); AudioObjectGetPropertyData(s, &a, 0, nil, &z, &pf)
        a = addr(kAudioStreamPropertyVirtualFormat); AudioObjectGetPropertyData(s, &a, 0, nil, &z, &vf)
        return (pf, vf)
    }

    static func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatFlags == b.mFormatFlags && a.mBitsPerChannel == b.mBitsPerChannel
            && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame && a.mFormatID == b.mFormatID
    }

    /// The mixable twin of the output stream's current physical format (never a saved struct: it carries a rate).
    static func setMixable(_ d: AudioObjectID) -> OSStatus {
        guard let s = streams(d, kAudioObjectPropertyScopeOutput).first else { return -1 }
        var f = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = addr(kAudioStreamPropertyPhysicalFormat)
        AudioObjectGetPropertyData(s, &a, 0, nil, &z, &f)
        guard f.mFormatFlags & kAudioFormatFlagIsNonMixable != 0 else { return noErr }
        f.mFormatFlags &= ~kAudioFormatFlagIsNonMixable
        return AudioObjectSetPropertyData(s, &a, 0, nil, z, &f)
    }

    static func setCFNumber(_ d: AudioObjectID, _ sel: AudioObjectPropertySelector, _ n: NSNumber) -> OSStatus {
        var a = addr(sel); let num: CFNumber = n
        var ref = Unmanaged.passUnretained(num)
        return withExtendedLifetime(num) { AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CFNumber>>.size), &ref) }
    }

    /// The plug-in's custom properties take a CFPropertyListRef.
    static func setScalar(_ d: AudioObjectID, _ s: Double, _ sel: AudioObjectPropertySelector) -> OSStatus {
        var a = addr(sel); let num: CFNumber = s as NSNumber
        var ref = Unmanaged.passUnretained(num)
        return withExtendedLifetime(num) { AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CFNumber>>.size), &ref) }
    }

    /// Turns a scope's streams off for one IOProc (so it isn't a client of them).
    static func streamUsageOff(_ dev: AudioObjectID, _ proc: AudioDeviceIOProcID, _ scope: AudioObjectPropertyScope) -> OSStatus {
        var a = addr(kAudioDevicePropertyIOProcStreamUsage, scope); var z: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &z) == noErr, z > 0 else { return -1 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(z), alignment: 8); defer { raw.deallocate() }
        let u = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        u.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        var st = AudioObjectGetPropertyData(dev, &a, 0, nil, &z, raw)
        guard st == noErr else { return st }
        let flags = (raw + MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!).assumingMemoryBound(to: UInt32.self)
        for i in 0..<Int(u.pointee.mNumberStreams) { flags[i] = 0 }
        st = AudioObjectSetPropertyData(dev, &a, 0, nil, z, raw)
        return st
    }
}

// MARK: - Volume forwarding

/// The volume keys and the sound menu change the default output's volume and mute: while the
/// engine runs that is the virtual device, which passes audio at unity. Its volume and mute are
/// forwarded to the DAC's own controls, so the stream to the DAC stays bit-perfect. The DAC's master
/// element (0) if it has a volume there, else the stereo pair's channel elements (Babyface Pro:
/// channels 1/2, no master, no mute).
/// Mapping: the slider is linear in dB over a window below the top (defaults RendererVolumeTopDB 0,
/// RendererVolumeRangeDB 64: 4 dB per key step, 1 dB per Option+Shift step); the bottom is the DAC's
/// minimum. The DAC's own taper made one step 8-9.5 dB on the Babyface. A DAC without dB controls
/// gets the slider's value as its scalar.
/// A DAC without a mute is muted by setting its volume to the minimum; unmute and stop restore the
/// level it had. A change made on the DAC itself (Audio MIDI Setup, TotalMix) moves the slider to
/// match. Comparisons are in slider units, so the DAC's own rounding (0.5 dB on the RME) doesn't echo.
/// Listeners run on their own queue: the keys keep working while a rate switch holds the engine thread.
final class VolumeForwarder {
    /// Set while a DAC without a mute is at its minimum for a mute: [UID, DAC scalar to restore].
    private static let mutedKey = "RendererDACMutedByVolume"
    private static let tolerance: Float32 = 0.01 // slider units (1/16 per key step)

    private let queue = DispatchQueue(label: "RendererEngine.volume")
    private let log: (String) -> Void
    // on the queue
    private var active = false
    private var ls = AudioObjectID(0), dac = AudioObjectID(0), dacUID = ""
    private var volumeEls: [UInt32] = [], muteEls: [UInt32] = []
    private var emulatedMute = false
    private var mutedLevel: Float32 = 0 // DAC scalar before an emulated mute
    private var topDB: Float32 = 0, rangeDB: Float32 = 64, useDB = false
    // engine thread
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(log: @escaping (String) -> Void) { self.log = log }

    /// Engine thread, after the DAC is set up.
    func start(virtual ls: AudioObjectID, dac: AudioObjectID) {
        stop()
        let vols = Self.elements(dac, kAudioDevicePropertyVolumeScalar)
        let mutes = Self.elements(dac, kAudioDevicePropertyMute)
        queue.sync {
            self.ls = ls; self.dac = dac; self.dacUID = CA.string(dac, kAudioDevicePropertyDeviceUID)
            volumeEls = vols; muteEls = mutes; emulatedMute = false
            guard !vols.isEmpty else {
                log("volume: DAC has no settable output volume; the volume keys change nothing (audio stays at unity)")
                return
            }
            let d = UserDefaults.standard
            let range = Self.dbRange(dac, vols[0])
            topDB = min(Float32(d.object(forKey: "RendererVolumeTopDB") as? Double ?? 0), range?.max ?? 0)
            rangeDB = max(Float32(d.object(forKey: "RendererVolumeRangeDB") as? Double ?? 64), 6)
            useDB = range != nil && Self.dbToScalar(dac, vols[0], topDB) != nil
            // start from the DAC's level, so nothing jumps
            let level = currentSlider() ?? 1
            let muted = mutes.first.flatMap { Self.get(dac, kAudioDevicePropertyMute, $0) }.map { $0 != 0 } ?? false
            let st = Self.set(ls, kAudioDevicePropertyVolumeScalar, 0, level)
            let mst = Self.set(ls, kAudioDevicePropertyMute, 0, muted ? 1 : 0)
            let map = useDB ? "linear in dB, \(Int(topDB)) to \(Int(topDB - rangeDB)) dB (\(String(format: "%.1f", rangeDB / 16)) dB per key step)" : "DAC scalar (no dB controls)"
            log("volume: forwarding to DAC element\(vols.count > 1 ? "s" : "") \(vols.map(String.init).joined(separator: ",")) (\(Self.db(dac, vols[0])) dB), \(map); mute \(mutes.isEmpty ? "emulated (DAC has none)" : "to element\(mutes.count > 1 ? "s" : "") \(mutes.map(String.init).joined(separator: ","))"); slider -> \(String(format: "%.4f", level)): \(st), mute -> \(muted ? 1 : 0): \(mst)")
            active = true
        }
        guard !vols.isEmpty else { return }
        for sel in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            listen(ls, AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput, mElement: 0)) { $0.push() }
        }
        for e in vols {
            listen(dac, AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: e)) { $0.pull() }
        }
    }

    /// Engine thread: listeners off; a DAC muted by volume gets its level back.
    func stop() {
        for (obj, a, block) in listeners { var a = a; AudioObjectRemovePropertyListenerBlock(obj, &a, queue, block) }
        listeners = []
        queue.sync {
            guard active else { return }
            active = false
            if emulatedMute {
                log("volume: unmuting the DAC as the engine lets go (\(String(format: "%.4f", mutedLevel))): \(setDACScalar(mutedLevel))")
                emulatedMute = false
                UserDefaults.standard.removeObject(forKey: Self.mutedKey)
            }
        }
    }

    /// At launch after an unclean exit: a DAC left at its minimum by an emulated mute gets its level back.
    static func recover() -> String? {
        guard let saved = UserDefaults.standard.array(forKey: mutedKey), saved.count == 2,
              let uid = saved[0] as? String, let level = (saved[1] as? NSNumber)?.floatValue else { return nil }
        UserDefaults.standard.removeObject(forKey: mutedKey)
        guard let d = CA.devices().first(where: { CA.string($0, kAudioDevicePropertyDeviceUID) == uid }) else { return nil }
        let st = elements(d, kAudioDevicePropertyVolumeScalar).map { set(d, kAudioDevicePropertyVolumeScalar, $0, level) }
        return "DAC volume restored from an emulated mute to \(String(format: "%.4f", level)): \(st)"
    }

    private func listen(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ body: @escaping (VolumeForwarder) -> Void) {
        var a = a
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in if let self, self.active { body(self) } }
        let st = AudioObjectAddPropertyListenerBlock(obj, &a, queue, block)
        if st == noErr { listeners.append((obj, a, block)) } else { log("volume: listener on \(obj) el \(a.mElement): \(st)") }
    }

    // MARK: mapping (on the queue)

    /// Slider (0...1) -> DAC scalar: linear in dB over the window; 0 is the DAC's minimum.
    private func dacScalar(forSlider v: Float32) -> Float32 {
        guard useDB else { return v }
        if v <= 0.001 { return 0 }
        let dB = topDB - (1 - v) * rangeDB
        return Self.dbToScalar(dac, volumeEls[0], dB) ?? v
    }

    /// The DAC's level in slider units (the loudest of its elements).
    private func currentSlider() -> Float32? {
        guard useDB else { return volumeEls.compactMap { Self.get(dac, kAudioDevicePropertyVolumeScalar, $0) }.max() }
        guard let dB = volumeEls.compactMap({ Self.get(dac, kAudioDevicePropertyVolumeDecibels, $0) }).max() else { return nil }
        return min(1, max(0, 1 + (dB - topDB) / rangeDB))
    }

    /// Virtual device -> DAC (a volume key, the sound menu).
    private func push() {
        guard let v = Self.get(ls, kAudioDevicePropertyVolumeScalar, 0) else { return }
        let m = (Self.get(ls, kAudioDevicePropertyMute, 0) ?? 0) != 0
        var did: [String] = []
        if !muteEls.isEmpty {
            for e in muteEls where (Self.get(dac, kAudioDevicePropertyMute, e) ?? 0) != (m ? 1 : 0) {
                did.append("mute el\(e) -> \(m ? 1 : 0): \(Self.set(dac, kAudioDevicePropertyMute, e, m ? 1 : 0))")
            }
        } else if m != emulatedMute {
            if m {
                mutedLevel = volumeEls.compactMap { Self.get(dac, kAudioDevicePropertyVolumeScalar, $0) }.max() ?? dacScalar(forSlider: v)
                UserDefaults.standard.set([dacUID, NSNumber(value: mutedLevel)], forKey: Self.mutedKey)
                did.append("mute (DAC to its minimum): \(setDACScalar(0))")
            } else {
                UserDefaults.standard.removeObject(forKey: Self.mutedKey)
                did.append("unmute")
            }
            emulatedMute = m
        }
        if !(muteEls.isEmpty && m), let cur = currentSlider(), abs(cur - v) > Self.tolerance || did.contains("unmute") {
            did.append("DAC \(setDACScalar(dacScalar(forSlider: v))) -> \(Self.db(dac, volumeEls[0])) dB")
        }
        if !did.isEmpty { log("volume \(String(format: "%.4f", v))\(m ? " muted" : ""): " + did.joined(separator: ", ")) }
    }

    /// DAC -> virtual device (changed on the DAC itself); not while an emulated mute holds it down.
    private func pull() {
        guard !emulatedMute, let v = Self.get(ls, kAudioDevicePropertyVolumeScalar, 0),
              let d = currentSlider(), abs(d - v) > Self.tolerance else { return }
        log("volume: DAC changed to \(Self.db(dac, volumeEls[0])) dB; slider follows to \(String(format: "%.4f", d)): \(Self.set(ls, kAudioDevicePropertyVolumeScalar, 0, d))")
    }

    private func setDACScalar(_ level: Float32) -> [OSStatus] {
        volumeEls.map { Self.set(dac, kAudioDevicePropertyVolumeScalar, $0, level) }
    }

    // MARK: Core Audio

    /// Settable output elements for `sel`: the master, else the stereo pair's channels.
    private static func elements(_ d: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [UInt32] {
        func settable(_ e: UInt32) -> Bool {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
            var s: DarwinBoolean = false
            return AudioObjectHasProperty(d, &a) && AudioObjectIsPropertySettable(d, &a, &s) == noErr && s.boolValue
        }
        if settable(0) { return [0] }
        var ch = [UInt32](repeating: 0, count: 2)
        var a = CA.addr(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
        var z = UInt32(8)
        let pair: [UInt32] = AudioObjectGetPropertyData(d, &a, 0, nil, &z, &ch) == noErr && ch[0] >= 1 && ch[1] >= 1 ? ch : [1, 2]
        return Array(Set(pair)).sorted().filter(settable)
    }

    private static func dbRange(_ d: AudioObjectID, _ e: UInt32) -> (min: Float32, max: Float32)? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeRangeDecibels, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
        var r = AudioValueRange(); var z = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(d, &a, 0, nil, &z, &r) == noErr, r.mMaximum > r.mMinimum else { return nil }
        return (Float32(r.mMinimum), Float32(r.mMaximum))
    }

    /// The DAC's own dB -> scalar translation (its taper), clamped to its range.
    private static func dbToScalar(_ d: AudioObjectID, _ e: UInt32, _ dB: Float32) -> Float32? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibelsToScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
        var v = dB; if let r = dbRange(d, e) { v = min(r.max, max(r.min, v)) }
        var z = UInt32(4)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &z, &v) == noErr ? v : nil
    }

    private static func get(_ d: AudioObjectID, _ sel: AudioObjectPropertySelector, _ e: UInt32) -> Float32? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
        if sel == kAudioDevicePropertyMute {
            var u = UInt32(0); var z = UInt32(4)
            return AudioObjectGetPropertyData(d, &a, 0, nil, &z, &u) == noErr ? Float32(u) : nil
        }
        var f = Float32(0); var z = UInt32(4)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &z, &f) == noErr ? f : nil
    }

    private static func set(_ d: AudioObjectID, _ sel: AudioObjectPropertySelector, _ e: UInt32, _ v: Float32) -> OSStatus {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
        if sel == kAudioDevicePropertyMute { var u = UInt32(v != 0 ? 1 : 0); return AudioObjectSetPropertyData(d, &a, 0, nil, 4, &u) }
        var f = v; return AudioObjectSetPropertyData(d, &a, 0, nil, 4, &f)
    }

    private static func db(_ d: AudioObjectID, _ e: UInt32) -> String {
        get(d, kAudioDevicePropertyVolumeDecibels, e).map { String(format: "%.1f", $0) } ?? "?"
    }
}

// MARK: - Music settings check

/// Music settings that defeat the engine: AutoMix or crossfade (tracks blend, so a switch can't be
/// clean), Sound Check, EQ and a Music volume below 100 (not bit-perfect), Lossless off. Read at
/// engine start, at each new track and on "Check Again" only (no timer: minimal CPU; a change
/// mid-track shows at the next track). Music's preferences (keys confirmed on the Babyface bench by
/// toggling: TransitionsEnabled 0/1; optimizeSongVolume 1, absent when off) and, for EQ and volume,
/// AppleScript (the "eqEnabled" preference disagreed with Music's own "EQ enabled"). A change in the
/// set of problems is logged, shown at the top of the menu, posted as one notification, and opens a
/// window with the fixes that stays until they're done (it closes itself when a check comes back clean).
final class MusicSettingsCheck: ObservableObject {
    struct Problem: Equatable, Identifiable {
        let id: String, what: String, fix: String
    }

    static let shared = MusicSettingsCheck()
    @Published private(set) var problems: [Problem] = []
    @Published private(set) var checkedAt: Date?
    /// Main thread -> engine thread: "Check Again".
    let recheck = Atomic<Int>(0)
    private var last: [Problem] = []
    private var askedForNotifications = false
    private var window: NSWindow?

    /// Engine thread.
    func check(_ scripts: RendererScripts, musicRunning: Bool, log: (String) -> Void) {
        guard musicRunning else { return }
        let app = "com.apple.Music" as CFString
        CFPreferencesAppSynchronize(app)
        func pref(_ k: String) -> Int? { (CFPreferencesCopyAppValue(k as CFString, app) as? NSNumber)?.intValue }
        var found: [Problem] = []
        if let t = pref("TransitionsEnabled"), t != 0 {
            found.append(.init(id: "transitions", what: "AutoMix or Crossfade is on",
                               fix: "Music > Settings > Playback: turn off AutoMix and Crossfade. They blend one track into the next, so a sample-rate switch can't happen cleanly."))
        }
        if let v = pref("optimizeSongVolume"), v != 0 {
            found.append(.init(id: "soundcheck", what: "Sound Check is on",
                               fix: "Music > Settings > Playback: turn off Sound Check. It changes each track's level, so the output isn't bit-perfect."))
        }
        if let l = pref("losslessEnabled"), l == 0 {
            found.append(.init(id: "lossless", what: "Lossless Audio is off",
                               fix: "Music > Settings > Playback: turn on Lossless Audio and choose Hi-Res Lossless for streaming. Otherwise Apple Music plays lossy AAC."))
        }
        if scripts.eqEnabled() == true {
            found.append(.init(id: "eq", what: "The Equalizer is on",
                               fix: "Music > Window > Equalizer: uncheck On. EQ changes the samples, so the output isn't bit-perfect."))
        }
        if let v = scripts.volume(), v < 100 {
            found.append(.init(id: "volume", what: "Music's volume is \(v), not 100",
                               fix: "Drag Music's volume slider all the way up, or click Set to 100 below. Use the keyboard's volume keys instead: they now change the DAC's own volume."))
        }
        let changed = found != last
        last = found
        DispatchQueue.main.async {
            self.checkedAt = Date()
            self.problems = found
            if found.isEmpty { self.window?.close() } else if changed { self.showWindow() }
        }
        guard changed else { return }
        log(found.isEmpty ? "Music settings: OK" : "Music settings: " + found.map(\.what).joined(separator: "; "))
        guard !found.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let post = {
            let c = UNMutableNotificationContent()
            c.title = "LosslessSwitcher: Music settings"
            c.body = found.map(\.what).joined(separator: "\n") + "\nPlayback isn't bit-perfect until this is fixed."
            center.add(UNNotificationRequest(identifier: "music-settings", content: c, trigger: nil))
        }
        if askedForNotifications { post(); return }
        askedForNotifications = true
        center.requestAuthorization(options: [.alert]) { ok, _ in if ok { post() } }
    }

    func clear() {
        last = []
        DispatchQueue.main.async { self.problems = []; self.window?.close() }
    }

    /// Main thread.
    func checkAgain() { recheck.store(1, ordering: .releasing) }

    /// Main thread; the AppleScript runs off it.
    func setMusicVolumeTo100() {
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"Music\" to set sound volume to 100")?.executeAndReturnError(&err)
            self.recheck.store(1, ordering: .releasing)
        }
    }

    /// Main thread.
    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Music settings for bit-perfect playback"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: MusicSettingsView(check: self))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MusicSettingsView: View {
    @ObservedObject var check: MusicSettingsCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exclusive Mode plays Music's output bit-perfect only when Music doesn't change it. Fix these in Music:")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(check.problems) { p in
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.what).bold()
                    Text(p.fix).fixedSize(horizontal: false, vertical: true)
                    if p.id == "volume" {
                        Button("Set to 100") { check.setMusicVolumeTo100() }
                    }
                }
            }
            if check.problems.isEmpty { Text("All set.") }
            Spacer(minLength: 0)
            HStack {
                Button("Check Again") { check.checkAgain() }
                if let t = check.checkedAt {
                    Text("Checked \(t.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
                }
                Spacer()
                Text("Also checked at each new track.").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 220)
    }
}

// MARK: - The DAC, for the menu

/// While the engine plays to a DAC the default output is its virtual device, so the menu would name
/// "LosslessSwitcher". The engine publishes the DAC it holds; the menu shows that, and goes back to
/// the default output's name when the engine lets the DAC go.
final class RendererOutput: ObservableObject {
    static let shared = RendererOutput()
    @Published private(set) var dacName: String?

    /// Any thread.
    func set(dacName name: String?) {
        DispatchQueue.main.async { if self.dacName != name { self.dacName = name } }
    }
}
