//
//  RendererEngine.swift
//  LosslessSwitcher
//
//  Experimental "Renderer" output engine. Music keeps decoding; a Core Audio process tap takes its
//  audio off the output device (muting Music's own output) and plays it back to the same device
//  inside a private aggregate on the device's clock, bit-exact, through a 200 ms delay line. Owning
//  the output lets a rate switch happen without wrong-rate audio reaching the DAC and without
//  cutting the end of the old track:
//  - Music sets up a local next track's decoder 8-12 s early and logs its rate. Near the boundary
//    the input to the delay line is cut at the zeros Music leaves between tracks at a rate change
//    (the "boundary latch"); the old track's tail still plays out of the delay line.
//  - On the new track: pause Music, switch the device (SilentOutput + waitUntilReady, as Pause While
//    Switching does), play Music silently (volume 0) until its output is steady, build the tap, then
//    rewind to where the track started and unmute. The delay line's 200 ms falls inside the pause.
//  Same-rate track changes, gapless albums and pause/resume pass through untouched.
//  Measurements and the test history are summarized in the pull request that added it.
//
//  Threads: the engine runs on its own thread (a switch blocks for seconds); playerInfo
//  notifications (main thread) and decoder log lines (`log stream` reader) reach it through a locked
//  inbox. The IO thread shares a few plain flags with the engine thread, as in the prototype.
//  Needs the System Audio Recording permission (NSAudioCaptureUsageDescription) and Automation
//  permission for Music.
//

import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import SimplyCoreAudio

final class RendererEngine {

    static let delay: TimeInterval = 0.2 // output delay line
    static let settle: TimeInterval = 0.12 // Music's output steady this long before the tap is built
    static let quiet: TimeInterval = 0.04 // tap silent this long after the rewind's pause before unmuting
    private static let savedVolumeKey = "RendererSavedMusicVolume"

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
    private var dev = AudioObjectID(0)
    private var devUID = ""
    private var pipe: Pipeline?
    private var pipeBuiltPlaying = false
    private var pipeRate: Float64 = 0
    private var generation = 0
    private var playing = false
    private var lastInfo = Date.distantPast
    private var lastTrackID: Int64?
    private var decoderRates: [(date: Date, rate: Float64, bits: Int?, lossless: Bool)] = []
    private var lossyTrackAt: Date?
    private var pendingUpgrade: (rate: Float64, bits: Int?)?
    private var armAt: Date?
    private var armedAt = Date.distantPast
    private var request: SwitchRequest?
    private var inRoutine = false
    private var switches = 0
    private var savedVolume = 100
    private var volumeHeld = false
    private var scripts: RendererScripts!
    private let log = RendererLog()

    // shared with the IO thread (plain loads/stores, as in the prototype)
    private var frames = 0, cycles = 0, lastTapNZ = 0
    private var muteOut = false, clearDelay = true
    private var armed = false, muteIn = false, zeroRun = 0, armZero = 441, latchFrame = 0
    private var ringW = 0, delayFrames = 0
    private var stereo = (0, 1)
    private static let ringSize = 1 << 19 // frames; > 1 s at 384 kHz
    private let ring: UnsafeMutablePointer<Float>
    private let recorder: RendererRecorder?

    private struct Pipeline {
        var tap: AudioObjectID
        var agg: AudioObjectID
        var proc: AudioDeviceIOProcID
    }

    private struct SwitchRequest {
        var format: AudioStreamBasicDescription? // nil: rebuild only, no rate change
        var name: String
        var reason: String
        var tPlay: Date
    }

    init(outputDevices: OutputDevices) {
        self.outputDevices = outputDevices
        ring = .allocate(capacity: Self.ringSize * 2)
        ring.initialize(repeating: 0, count: Self.ringSize * 2)
        recorder = RendererRecorder.fromDefaults()
    }

    deinit {
        ring.deallocate()
    }

    // MARK: - Lifecycle (main thread)

    var isRunning: Bool { thread != nil }

    /// Logged when the engine starts (why the tap engine is used instead of the virtual device).
    var startupNote: String?

    func start() {
        guard thread == nil else { return }
        print("[Exclusive Mode] start requested")
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
        t.name = "RendererEngine"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    /// Tears the pipeline down and restores Music's volume. Waits for a switch in progress (up to 15 s).
    func stop() {
        guard thread != nil else { return }
        inboxLock.lock(); stopRequested = true; inboxLock.unlock()
        if finished?.wait(timeout: .now() + 15) == .timedOut {
            // the engine thread is stuck (e.g. in Core Audio); still give Music its volume back
            if let v = UserDefaults.standard.object(forKey: Self.savedVolumeKey) as? Int {
                NSAppleScript(source: "tell application \"Music\" to set sound volume to \(v)")?.executeAndReturnError(nil)
                UserDefaults.standard.removeObject(forKey: Self.savedVolumeKey)
            }
            print("[Exclusive Mode] engine thread did not stop within 15 s")
        }
        thread = nil
        finished = nil
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        logProcess?.terminate()
        logProcess = nil
    }

    /// Music logs "Input format: 2 ch, <rate> Hz, ..." (com.apple.coreaudio) each time it sets up a
    /// decoder, including the real rate of Apple Music streams, and ~8-12 s ahead for a local next track.
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
        log("engine started (process tap)")
        if let n = startupNote { log(n) }
        scripts = RendererScripts()
        log("scripts compiled")
        resolveDevice()
        recoverVolume()
        if scripts.playerState() == "playing" {
            muteOut = true
            request = SwitchRequest(format: nil, name: "(current track)", reason: "engine started while Music plays", tPlay: Date())
        } else {
            holdVolume() // the first play is silent until the routine has a pipeline
        }
        var lastCheck = Date()
        while !shouldStop {
            pump()
            if Date().timeIntervalSince(lastCheck) >= 1 { lastCheck = Date(); checkDeviceAndMusic() }
            if let a = armAt, Date() >= a, !armed, !muteIn, pipe != nil {
                armAt = nil; zeroRun = 0; armZero = max(Int(0.01 * nominal(dev)), 1); armedAt = Date(); armed = true
                log("boundary latch armed at frame \(frames)")
            }
            if armed && Date().timeIntervalSince(armedAt) > 5 { armed = false; log("no boundary within 5 s; disarmed") }
            if muteIn && !inRoutine && request == nil && Double(frames - latchFrame) > 4 * nominal(dev) {
                muteIn = false; log("latched 4 s without a track change; released")
            }
            if let rq = request { request = nil; runSwitch(rq) }
            if let up = pendingUpgrade, playing, request == nil {
                pendingUpgrade = nil
                if let fmt = neededFormat(rate: up.rate, bits: up.bits) {
                    log("lossless decoder at \(up.rate) Hz after a lossy start; switching again")
                    muteOut = true; clearDelay = true
                    runSwitch(SwitchRequest(format: fmt, name: "(lossless upgrade)", reason: "rate \(fmt.mSampleRate)", tPlay: Date()))
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if let p = pipe { teardown(p); pipe = nil }
        releaseVolume()
        recorder?.write(frames: frames)
        log("engine stopped")
        log.close()
    }

    /// Drains the inbox; call instead of sleeping while waiting for Music's notifications.
    private func pump() {
        inboxLock.lock()
        let infos = infoInbox, lines = lineInbox
        infoInbox = []; lineInbox = []
        inboxLock.unlock()
        for (at, info) in infos { handleInfo(info, at: at) }
        for (at, line) in lines { handleLine(line, at: at) }
    }

    private func wait(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() {
            pump()
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func handleInfo(_ info: [AnyHashable: Any], at: Date) {
        let state = info["Player State"] as? String ?? "?"
        let name = info["Name"] as? String ?? ""
        // stations and Browse streams have no PersistentID: tell tracks apart by name
        let pid = (info["PersistentID"] as? NSNumber)?.int64Value ?? (name.isEmpty ? nil : Int64(truncatingIfNeeded: name.hashValue))
        log("playerInfo: \(state) \(name)")
        playing = state == "Playing"
        lastInfo = at
        // a notification for the same track (pause, seek) while armed/latched: the boundary moved
        if !inRoutine, pid == lastTrackID, armed || muteIn || armAt != nil {
            armed = false; armAt = nil
            if muteIn { muteIn = false; log("\(state) on the same track; latch released") } else { log("\(state) on the same track; disarmed") }
        }
        guard playing, !inRoutine, request == nil else { return }
        var fmt: AudioStreamBasicDescription?
        if let id = pid, id != lastTrackID {
            lastTrackID = id
            lossyTrackAt = nil
            if let last = decoderRates.last {
                if !last.lossless { lossyTrackAt = Date() }
                fmt = neededFormat(rate: last.rate, bits: last.bits)
                log("new track \(name): decoder \(last.rate) Hz (seen \(String(format: "%.3f", at.timeIntervalSince(last.date))) s before), device \(nominal(dev)) Hz\(fmt.map { " -> switch to \($0.mSampleRate)" } ?? "")")
            } else {
                log("new track \(name): no decoder rate seen")
            }
        }
        if fmt != nil || needsRebuild() {
            if muteIn && fmt != nil {
                log("boundary latched \(String(format: "%.0f", Double(frames - latchFrame) / nominal(dev) * 1000)) ms before Playing; keeping the old track's tail")
            } else {
                muteOut = true; clearDelay = true // a wrong-rate start may be in the delay line: drop it
            }
            request = SwitchRequest(format: fmt, name: name, reason: fmt.map { "rate \($0.mSampleRate)" } ?? "no pipeline built while playing", tPlay: at)
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
        // A decoder for another rate while a pipeline plays is the next track: arm the latch near the end.
        if !inRoutine, playing, pipe != nil, !armed, !muteIn, armAt == nil, neededFormat(rate: rate, bits: bits) != nil {
            let left = scripts.remaining() ?? 0
            armAt = Date().addingTimeInterval(max(0, left - 1.5))
            log("next track needs \(rate) Hz; \(String(format: "%.2f", left)) s left, arming the boundary latch in \(String(format: "%.2f", max(0, left - 1.5))) s")
        }
    }

    // MARK: - The switch routine

    private func runSwitch(_ rq: SwitchRequest) {
        inRoutine = true
        defer { inRoutine = false }
        armed = false; armAt = nil
        switches += 1
        let t = Date()
        log("switch \(switches): \(rq.name): \(rq.reason); \(muteIn ? "latched" : "output muted") at frame \(frames); pausing Music")
        _ = scripts.pause()
        wait(1) { !playing }
        if muteIn { // let the old track's tail play out of the delay line before tearing down
            let r0 = nominal(dev)
            wait(0.5) { Double(frames - latchFrame) >= Double(delayFrames) + 0.02 * r0 }
        }
        muteOut = true; muteIn = false
        let pos = scripts.position() ?? 0
        // where this play started: position now minus what played since Playing (+ ~50 ms before it)
        let played = Date().timeIntervalSince(rq.tPlay) + 0.05
        var startPos = pos - played - 0.1
        if startPos < 0.5 { startPos = 0 }
        holdVolume()
        if let p = pipe { teardown(p); pipe = nil }
        log("switch: paused after \(ms(t)) at position \(String(format: "%.3f", pos)) -> resume at \(String(format: "%.3f", startPos)); volume 0, torn down")

        // With Music paused nothing runs the device, and only a running device restarts at the new
        // rate and reports its clock: run it with silence until it's ready.
        let keepAlive = SilentOutput(device: dev)
        if let fmt = rq.format, let device = AudioDevice.lookup(by: dev) {
            let t0 = Date()
            outputDevices.applySerialized(fmt, device: device, force: true)
            let checkBitDepth = outputDevices.enableBitDepthDetection
            let ready = keepAlive.map { ka in
                DeviceFormat.waitUntilReady(dev, format: fmt, checkBitDepth: checkBitDepth, stalled: { ka.restart() })
            } ?? DeviceFormat.waitUntilFormatMatches(dev, format: fmt, checkBitDepth: checkBitDepth)
            log("switch: device \(ready ? "ready" : "NOT ready") at \(nominal(dev)) Hz \(ms(t0)) after the set (actual \(String(format: "%.1f", DeviceFormat.actualSampleRate(dev) ?? 0)))")
        }
        pump()
        _ = scripts.play()
        var playSent = Date()
        // hold: Music plays silently until it reports Playing and its output has been steady
        var run = musicRunningOutput(), since = Date(), replays = 0
        let th = Date()
        while Date().timeIntervalSince(th) < 10 {
            pump()
            let r = musicRunningOutput()
            if r != run { run = r; since = Date() }
            // Music gives up and pauses itself if the device doesn't come up
            // (counted from our play: the inbox isn't drained during waitUntilReady, so lastInfo can be old)
            if !playing && Date().timeIntervalSince(max(lastInfo, playSent)) > 0.5 && replays < 3 {
                replays += 1
                playSent = Date()
                log("switch: Music paused itself during the hold; play again (\(replays))")
                _ = scripts.play()
            }
            if playing && run && Date().timeIntervalSince(since) >= Self.settle && Date().timeIntervalSince(lastInfo) >= Self.settle { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        log("switch: Music \(playing ? "playing" : "NOT playing"), output \(run ? "steady" : "not running") after \(ms(th)) of hold; building")
        pipe = buildPipeline()
        pipeBuiltPlaying = pipe != nil
        pipeRate = nominal(dev)
        keepAlive?.stop()
        guard pipe != nil else {
            log("switch: no pipeline; Music plays directly")
            releaseVolume()
            muteOut = false
            return
        }
        _ = scripts.pause()
        wait(1) { !playing }
        releaseVolume() // while paused: the muted tap and our muted output keep it silent
        _ = scripts.setPosition(startPos)
        let rate = nominal(dev)
        let tq = Date()
        while Double(frames - lastTapNZ) < Self.quiet * rate && Date().timeIntervalSince(tq) < 1 {
            pump(); Thread.sleep(forTimeInterval: 0.005)
        }
        log("switch: paused, rewound; tap quiet \(String(format: "%.0f", Double(frames - lastTapNZ) / rate * 1000)) ms at frame \(frames); unmuting, play")
        clearDelay = true
        muteOut = false
        _ = scripts.play()
        log("switch \(switches) done \(ms(t)) after the request (frame \(frames))")
    }

    private func needsRebuild() -> Bool {
        pipe == nil || !pipeBuiltPlaying || nominal(dev) != pipeRate
    }

    /// The device format the track needs, or nil if the device already has it.
    private func neededFormat(rate: Float64, bits: Int?) -> AudioStreamBasicDescription? {
        guard let device = AudioDevice.lookup(by: dev),
              let fmt = outputDevices.suitableFormat(for: CMPlayerStats(sampleRate: rate, bitDepth: bits ?? 24, date: Date(), priority: 5), device: device) else { return nil }
        return DeviceFormat.matches(dev, format: fmt, checkBitDepth: outputDevices.enableBitDepthDetection) ? nil : fmt
    }

    /// Music plays to the default output device; the tap has to be on that device.
    private func resolveDevice() {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var d = AudioObjectID(0), z = UInt32(4)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &z, &d)
        dev = d
        devUID = stringProp(d, kAudioDevicePropertyDeviceUID)
        var ch = [UInt32](repeating: 0, count: 2)
        a = addr(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
        z = 8
        if AudioObjectGetPropertyData(d, &a, 0, nil, &z, &ch) == noErr, ch[0] >= 1, ch[1] >= 1 {
            stereo = (Int(ch[0]) - 1, Int(ch[1]) - 1)
        } else {
            stereo = (0, 1)
        }
        log("device \(stringProp(d, kAudioObjectPropertyName)) @ \(nominal(d)) Hz, stereo channels \(stereo.0 + 1)/\(stereo.1 + 1)")
    }

    private func checkDeviceAndMusic() {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var d = AudioObjectID(0), z = UInt32(4)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &z, &d)
        let musicRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
        if d != dev {
            log("default output device changed")
            if let p = pipe { teardown(p); pipe = nil }
            resolveDevice()
            if musicRunning { holdVolume() }
            if playing && musicRunning && request == nil {
                muteOut = true
                request = SwitchRequest(format: nil, name: "(current track)", reason: "output device changed", tPlay: Date())
            }
        } else if !musicRunning, let p = pipe {
            log("Music quit; pipeline torn down")
            teardown(p); pipe = nil
            lastTrackID = nil
            volumeHeld = false // Music's volume went with it; it restores its own on launch
        }
    }

    // MARK: - Pipeline

    private func buildPipeline() -> Pipeline? {
        guard let music = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first else {
            log("Music isn't running"); return nil
        }
        var pid = music.processIdentifier
        var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var musicObj = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &musicObj) == noErr, musicObj != 0 else {
            log("no process object for Music"); return nil
        }
        let desc = CATapDescription(processes: [musicObj], deviceUID: devUID, stream: 0)
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.name = "LosslessSwitcher renderer"
        desc.muteBehavior = .muted
        var tap = AudioObjectID(0)
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr else { log("create tap failed \(st) (System Audio Recording permission?)"); return nil }
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceUIDKey: UUID().uuidString, kAudioAggregateDeviceNameKey: "LosslessSwitcher renderer",
            kAudioAggregateDeviceIsPrivateKey: 1, kAudioAggregateDeviceMainSubDeviceKey: devUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: devUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: 0]],
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]
        var agg = AudioObjectID(0)
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard st == noErr else { log("create aggregate failed \(st)"); AudioHardwareDestroyProcessTap(tap); return nil }

        generation += 1
        let gen = Int32(generation)
        var procID: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { [unowned self] _, inInput, inTime, outOutput, _ in
            self.render(inInput, inTime, outOutput, gen)
        }
        guard st == noErr, let procID else {
            log("IOProc failed \(st)"); AudioHardwareDestroyAggregateDevice(agg); AudioHardwareDestroyProcessTap(tap); return nil
        }
        disableDeviceInputs(agg, procID)
        let rate = nominal(agg)
        recorder?.segment(frame: frames, rate: rate)
        delayFrames = Int(Self.delay * rate)
        clearDelay = true
        let c0 = cycles, tStart = Date()
        st = AudioDeviceStart(agg, procID)
        while cycles == c0 && Date().timeIntervalSince(tStart) < 15 { pump(); Thread.sleep(forTimeInterval: 0.002) }
        log("pipeline \(generation): aggregate @ \(rate) Hz; start \(st); first IO cycle after \(ms(tStart))")
        if cycles == c0 {
            // no IO in 15 s (a permission prompt waiting, in trial ls2): stopping it hung for ~105 s
            // there, so destroy without AudioDeviceStop, and time it
            let td = Date()
            AudioDeviceDestroyIOProcID(agg, procID)
            AudioHardwareDestroyAggregateDevice(agg); AudioHardwareDestroyProcessTap(tap)
            log("pipeline without IO destroyed in \(ms(td))")
            return nil
        }
        return Pipeline(tap: tap, agg: agg, proc: procID)
    }

    /// The aggregate's input streams are the device's own inputs followed by the tap. Only the tap is
    /// read, so the device's inputs are switched off for our IOProc: an IOProc that reads a device's
    /// inputs needs the Microphone permission (tccd prompted for it in trial ls2).
    private func disableDeviceInputs(_ agg: AudioObjectID, _ proc: AudioDeviceIOProcID) {
        var a = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(agg, &a, 0, nil, &size) == noErr else { return }
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        guard count > 1 else { return }
        let bytes = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + (count - 1) * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(count)
        let flags = UnsafeMutableRawPointer(raw + MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!).bindMemory(to: UInt32.self, capacity: count)
        for i in 0..<count { flags[i] = i == count - 1 ? 1 : 0 }
        a = addr(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        let st = AudioObjectSetPropertyData(agg, &a, 0, nil, UInt32(bytes), raw)
        log("input streams: \(count), device inputs off for our IOProc: \(st)")
    }

    private func teardown(_ p: Pipeline) {
        AudioDeviceStop(p.agg, p.proc)
        AudioDeviceDestroyIOProcID(p.agg, p.proc)
        AudioHardwareDestroyAggregateDevice(p.agg)
        AudioHardwareDestroyProcessTap(p.tap)
    }

    /// IO thread. Input buffers: [device inputs..., Music tap]; output: the device's stream(s).
    private func render(_ inInput: UnsafePointer<AudioBufferList>, _ inTime: UnsafePointer<AudioTimeStamp>, _ outOutput: UnsafeMutablePointer<AudioBufferList>, _ gen: Int32) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
        let outs = UnsafeMutableAudioBufferListPointer(outOutput)
        for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        guard let ob = outs.first, let od = ob.mData, ob.mNumberChannels > 0 else { return }
        let och = Int(ob.mNumberChannels), n = Int(ob.mDataByteSize) / 4 / och
        let tb = ins.last
        let tch = max(Int(tb?.mNumberChannels ?? 1), 1)
        let td = tb?.mData?.assumingMemoryBound(to: Float.self)
        let tn = td == nil ? 0 : min(n, Int(tb!.mDataByteSize) / 4 / tch)
        let (cl, cr) = stereo
        let tl = cl < tch ? cl : 0, tr = cr < tch ? cr : min(1, tch - 1)
        let ol = cl < och ? cl : 0, orr = cr < och ? cr : min(1, och - 1)
        let o = od.assumingMemoryBound(to: Float.self)
        if clearDelay { ring.update(repeating: 0, count: Self.ringSize * 2); clearDelay = false }
        let mute = muteOut
        let g: Float = OvershootProtection.shared.isOn ? OvershootProtection.gain : 1
        var latched = muteIn
        for f in 0..<n {
            let l: Float = f < tn ? td![f * tch + tl] : 0, r: Float = f < tn ? td![f * tch + tr] : 0
            if l != 0 || r != 0 { lastTapNZ = frames + f }
            if armed && !latched {
                if l == 0 && r == 0 {
                    zeroRun += 1
                    if zeroRun >= armZero { latched = true; muteIn = true; armed = false; latchFrame = frames + f }
                } else { zeroRun = 0 }
            }
            // delay line: write the tap in (zeros while muted or latched), read delayFrames behind
            let wi = (ringW & (Self.ringSize - 1)) * 2
            let zin = mute || latched
            ring[wi] = zin ? 0 : l; ring[wi + 1] = zin ? 0 : r
            let ri = ((ringW - delayFrames) & (Self.ringSize - 1)) * 2
            ringW += 1
            let vl: Float = mute ? 0 : ring[ri], vr: Float = mute ? 0 : ring[ri + 1]
            if g != 1 { o[f * och + ol] = vl * g; o[f * och + orr] = vr * g } else { o[f * och + ol] = vl; o[f * och + orr] = vr }
            recorder?.frame(frames + f, l, r, vl, vr)
        }
        recorder?.cycle(cycles, frames: n, gen: gen, host: inTime.pointee.mHostTime)
        cycles += 1
        frames += n
    }

    // MARK: - Music's volume

    /// Music at volume 0 while there's no pipeline built while it plays, so nothing reaches the DAC
    /// directly; the value to restore is also kept in defaults in case the app dies holding it.
    private func holdVolume() {
        guard !volumeHeld else { return }
        let v = scripts.volume() ?? 100
        savedVolume = v > 0 ? v : (UserDefaults.standard.object(forKey: Self.savedVolumeKey) as? Int ?? 100)
        UserDefaults.standard.set(savedVolume, forKey: Self.savedVolumeKey)
        _ = scripts.setVolume(0)
        volumeHeld = true
    }

    private func releaseVolume() {
        guard volumeHeld else { return }
        _ = scripts.setVolume(savedVolume)
        volumeHeld = false
        UserDefaults.standard.removeObject(forKey: Self.savedVolumeKey)
    }

    private func recoverVolume() {
        guard let v = UserDefaults.standard.object(forKey: Self.savedVolumeKey) as? Int else { return }
        if scripts.volume() == 0 {
            log("restoring Music's volume \(v) held by an earlier run")
            _ = scripts.setVolume(v)
        }
        UserDefaults.standard.removeObject(forKey: Self.savedVolumeKey)
    }

    // MARK: - Helpers

    private func musicRunningOutput() -> Bool {
        guard let music = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first else { return false }
        var pid = music.processIdentifier
        var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var obj = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj) == noErr else { return false }
        var r = UInt32(0), z = UInt32(4)
        a = addr(kAudioProcessPropertyIsRunningOutput)
        AudioObjectGetPropertyData(obj, &a, 0, nil, &z, &r)
        return r != 0
    }

    private func nominal(_ d: AudioObjectID) -> Float64 {
        DeviceFormat.nominalSampleRate(d) ?? 0
    }

    private func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func stringProp(_ obj: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
        var a = addr(s); var v: Unmanaged<CFString>?; var z = UInt32(MemoryLayout<CFString?>.size)
        AudioObjectGetPropertyData(obj, &a, 0, nil, &z, &v)
        return (v?.takeRetainedValue() as String?) ?? ""
    }

    private func ms(_ t: Date) -> String { String(format: "%.3f s", Date().timeIntervalSince(t)) }

    private func log(_ s: String) { log.write(s) }
}

/// AppleScript for Music, used only on an engine thread (RendererEngine, VirtualDeviceEngine).
final class RendererScripts {
    private let pauseScript = compile("tell application \"Music\" to pause")
    private let playScript = compile("tell application \"Music\" to play")
    private let positionScript = compile("tell application \"Music\" to get player position")
    private let remainingScript = compile("tell application \"Music\" to get (duration of current track) - player position")
    private let volumeScript = compile("tell application \"Music\" to get sound volume")
    private let stateScript = compile("tell application \"Music\" to get player state as string")
    private let eqScript = compile("tell application \"Music\" to get EQ enabled")

    private static func compile(_ source: String) -> NSAppleScript? {
        let s = NSAppleScript(source: source)
        var err: NSDictionary?
        s?.compileAndReturnError(&err)
        if let err { print("[Exclusive Mode] AppleScript compile: \(err)") }
        return s
    }

    private func run(_ s: NSAppleScript?) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let d = s?.executeAndReturnError(&err)
        if let err { print("[Exclusive Mode] AppleScript: \(err)"); return nil }
        return d
    }

    func pause() -> Bool { run(pauseScript) != nil }
    func play() -> Bool { run(playScript) != nil }
    func position() -> Double? { run(positionScript)?.doubleValue }
    func remaining() -> Double? { run(remainingScript)?.doubleValue }
    func volume() -> Int? { run(volumeScript).map { Int($0.int32Value) } }
    func playerState() -> String? { run(stateScript)?.stringValue }
    func eqEnabled() -> Bool? { run(eqScript)?.booleanValue }
    func setVolume(_ v: Int) -> Bool { run(Self.compile("tell application \"Music\" to set sound volume to \(v)")) != nil }
    func setPosition(_ p: Double) -> Bool { run(Self.compile("tell application \"Music\" to set player position to \(p)")) != nil }
}

/// Engine log: ~/Library/Logs/LosslessSwitcher-Renderer.log, one "[seconds] message" line each,
/// seconds since the engine started (the prototype's format, which its analysis scripts read).
final class RendererLog {
    private var handle: FileHandle?
    private var t0 = Date()
    private let lock = NSLock()

    func start() {
        lock.lock(); defer { lock.unlock() }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LosslessSwitcher-ExclusiveMode.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        t0 = Date()
    }

    func write(_ s: String) {
        let line = String(format: "[%7.3f] ", Date().timeIntervalSince(t0)) + s
        print("[Exclusive Mode] \(line)")
        lock.lock(); handle?.write((line + "\n").data(using: .utf8)!); lock.unlock()
    }

    func close() {
        lock.lock(); try? handle?.close(); handle = nil; lock.unlock()
    }
}

/// Debug recording, for offline analysis of the output against the input (the analysis scripts are
/// not part of this repository).
/// Enabled with `defaults write <bundle id> RendererDebugRecord <path prefix>` (and optionally
/// RendererDebugRecordSeconds, default 330); written when the engine stops. Memory: 16 bytes per frame.
final class RendererRecorder {
    private let prefix: String
    private let maxFrames: Int
    private let tap: UnsafeMutablePointer<Float>
    private let out: UnsafeMutablePointer<Float>
    private let maxCycles = 400_000
    private let cycFrames: UnsafeMutablePointer<Int32>
    private let cycGen: UnsafeMutablePointer<Int32>
    private let cycHost: UnsafeMutablePointer<UInt64>
    private var cycles = 0
    private var segments: [String] = []

    static func fromDefaults() -> RendererRecorder? {
        guard let prefix = UserDefaults.standard.string(forKey: "RendererDebugRecord"), !prefix.isEmpty else { return nil }
        let seconds = UserDefaults.standard.object(forKey: "RendererDebugRecordSeconds") as? Double ?? 330
        return RendererRecorder(prefix: prefix, seconds: seconds)
    }

    private init(prefix: String, seconds: Double) {
        self.prefix = prefix
        maxFrames = Int(seconds * 200_000)
        tap = .allocate(capacity: maxFrames * 2); tap.initialize(repeating: 0, count: maxFrames * 2)
        out = .allocate(capacity: maxFrames * 2); out.initialize(repeating: 0, count: maxFrames * 2)
        cycFrames = .allocate(capacity: maxCycles)
        cycGen = .allocate(capacity: maxCycles)
        cycHost = .allocate(capacity: maxCycles)
    }

    func segment(frame: Int, rate: Float64) { segments.append("\(frame) \(rate)") }

    @inline(__always) func frame(_ k: Int, _ l: Float, _ r: Float, _ ol: Float, _ or: Float) {
        guard k < maxFrames else { return }
        tap[k * 2] = l; tap[k * 2 + 1] = r; out[k * 2] = ol; out[k * 2 + 1] = or
    }

    @inline(__always) func cycle(_ i: Int, frames: Int, gen: Int32, host: UInt64) {
        guard i < maxCycles else { return }
        cycFrames[i] = Int32(frames); cycGen[i] = gen; cycHost[i] = host
        cycles = i + 1
    }

    func write(frames: Int) {
        let nf = min(frames, maxFrames)
        FileManager.default.createFile(atPath: prefix + ".tap.f32", contents: Data(bytes: tap, count: nf * 8))
        FileManager.default.createFile(atPath: prefix + ".out.f32", contents: Data(bytes: out, count: nf * 8))
        var cyc = ""
        for i in 0..<cycles { cyc += "0 \(cycFrames[i]) \(cycGen[i]) \(cycHost[i])\n" }
        try? cyc.write(toFile: prefix + ".cycles.txt", atomically: true, encoding: .utf8)
        try? (segments.joined(separator: "\n") + "\n").write(toFile: prefix + ".segments.txt", atomically: true, encoding: .utf8)
    }
}
