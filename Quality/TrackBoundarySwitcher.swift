//
//  TrackBoundarySwitcher.swift
//  LosslessSwitcher
//
//  Opt-in "Pause While Switching": when Music starts a local track that needs a different
//  device format, pause Music, switch the device, wait until the device is running steadily
//  at the new rate, add the chosen gap, then restart the track from 0:00. Music stays paused
//  if the device never gets there, rather than playing through a rate change.
//
//  Music's com.apple.Music.playerInfo notification arrives the moment a track starts, but it
//  carries no file location, so a fraction of a second of the new track still plays at the
//  old rate before the pause.
//

import AudioToolbox
import Combine
import CoreAudio
import Foundation
import SimplyCoreAudio

class TrackBoundarySwitcher {

    static let readyTimeout: TimeInterval = 8

    enum TrackKind {
        case unknown, local, notLocal
    }

    /// What the switcher found for Music's current track. In pause mode the regular detection path
    /// reads this instead of asking Music itself: its timer asked ~29 times per track change, and
    /// Music answers Apple events on the same thread as its playback controls.
    static var currentTrackKind: TrackKind {
        lock.lock(); defer { lock.unlock() }
        return _currentTrackKind
    }
    private static var _currentTrackKind = TrackKind.unknown
    private static let lock = NSLock()
    private static func setCurrentTrackKind(_ kind: TrackKind) {
        lock.lock(); _currentTrackKind = kind; lock.unlock()
    }

    /// Tracks our own pause so the user's actions during the wait cancel the resume.
    private enum Wait {
        case idle
        case pausing(Int64) // pause sent; Music may still repeat the track's "Playing" notification
        case paused(Int64) // Music confirmed; any "Playing" from here on is the user
        case cancelled
    }
    private var wait = Wait.idle // guarded by waitLock
    private let waitLock = NSLock()
    private func setWait(_ new: Wait) {
        waitLock.lock(); wait = new; waitLock.unlock()
    }
    private var isCancelled: Bool {
        waitLock.lock(); defer { waitLock.unlock() }
        if case .cancelled = wait { return true }
        return false
    }

    private unowned let outputDevices: OutputDevices
    // Own queue: the regular detection path's AppleScript calls can block for seconds while Music is busy.
    private let queue = DispatchQueue(label: "trackBoundaryQueue", qos: .userInitiated)
    private var observer: NSObjectProtocol?
    private var toggleCancellable: AnyCancellable?
    private var lastPersistentID: Int64? // main thread only
    // Compiled once and only used on `queue`: compiling on every track change delayed the pause.
    private let scripts = MusicPlayer.CompiledScripts()

    init(outputDevices: OutputDevices) {
        self.outputDevices = outputDevices
        observer = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
            self?.playerInfoDidChange(note.userInfo ?? [:])
        }
        // currentTrackKind is only maintained while the toggle is on, and a track already playing
        // sends no notification. So whenever the toggle turns on (including at launch), look up the
        // current track and switch it without pausing.
        toggleCancellable = Defaults.shared.$userPreferPauseWhileSwitching
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                Self.setCurrentTrackKind(.unknown)
                self?.queue.async {
                    self?.switchCurrentTrack(pauseMusic: false, persistentID: nil, received: Date())
                }
            }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    private func playerInfoDidChange(_ info: [AnyHashable : Any]) {
        let state = info["Player State"] as? String
        let persistentID = (info["PersistentID"] as? NSNumber)?.int64Value
        noteUserAction(state: state, persistentID: persistentID)

        guard state == "Playing" else { return }
        guard let persistentID else {
            // Apple Music streams that aren't in the library (stations, Browse) have no PersistentID.
            // Local files are always library tracks, so this is a stream: leave it to the regular path.
            if lastPersistentID != nil || Self.currentTrackKind != .notLocal {
                print("[TrackBoundary] stream without PersistentID; leaving it to the regular path")
            }
            lastPersistentID = nil
            Self.setCurrentTrackKind(.notLocal)
            return
        }
        // the notification repeats for the same track, and fires again when we resume
        guard persistentID != lastPersistentID else { return }
        lastPersistentID = persistentID
        guard Defaults.shared.userPreferPauseWhileSwitching else { return }
        // until the switcher has asked Music, keep the regular path away from this track
        Self.setCurrentTrackKind(.unknown)

        let received = Date()
        queue.async { [weak self] in
            self?.switchCurrentTrack(pauseMusic: true, persistentID: MusicPlayer.hexPersistentID(persistentID), received: received)
        }
    }

    private func noteUserAction(state: String?, persistentID: Int64?) {
        waitLock.lock(); defer { waitLock.unlock() }
        switch wait {
        case .pausing(let id) where state == "Paused" && persistentID == id:
            wait = .paused(id)
        case .pausing(let id) where state == "Playing" && persistentID != id:
            // the user moved to another track before Music confirmed our pause
            wait = .cancelled
        case .paused where state == "Playing":
            // the user pressed play or moved to another track while we waited
            wait = .cancelled
        default:
            break
        }
    }

    private func switchCurrentTrack(pauseMusic: Bool, persistentID: String?, received: Date) {
        let lookup = lookupCurrentTrack()
        switch lookup {
        case .local: Self.setCurrentTrackKind(.local)
        case .notLocal: Self.setCurrentTrackKind(.notLocal)
        case .unknown: Self.setCurrentTrackKind(.unknown)
        }
        guard case .local(let stats) = lookup,
              let device = outputDevices.selectedOutputDevice ?? outputDevices.defaultOutputDevice,
              let format = outputDevices.suitableFormat(for: stats, device: device) else { return }

        let checkBitDepth = outputDevices.enableBitDepthDetection
        if DeviceFormat.matches(device.id, format: format, checkBitDepth: checkBitDepth) {
            return
        }

        guard pauseMusic, let persistentID else {
            outputDevices.applySerialized(format, device: device, force: true)
            return
        }

        guard let signedID = MusicPlayer.signedPersistentID(persistentID) else { return }
        setWait(.pausing(signedID))
        defer { setWait(.idle) }
        guard scripts.pause() else {
            print("[TrackBoundary] could not pause Music; switching during playback")
            outputDevices.applySerialized(format, device: device, force: true)
            return
        }
        print("[TrackBoundary] paused \(persistentID) \(Self.ms(since: received)) after track start, switching to \(format.mSampleRate) Hz / \(format.mBitsPerChannel) bit")

        // With Music paused nothing runs the device, and only a running device reports its clock.
        let keepAlive = SilentOutput(device: device.id)
        outputDevices.applySerialized(format, device: device, force: true)

        let switched = Date()
        let ready: Bool
        if let keepAlive {
            ready = DeviceFormat.waitUntilReady(device.id, format: format, checkBitDepth: checkBitDepth,
                                                cancelled: { [unowned self] in isCancelled },
                                                stalled: { keepAlive.restart() })
        } else {
            // e.g. another app has the device in hog mode: nothing runs it while Music is paused, so it
            // can never report running. Fall back to the format change plus the gap.
            print("[TrackBoundary] no silent output; waiting for the format change only")
            ready = DeviceFormat.waitUntilFormatMatches(device.id, format: format, checkBitDepth: checkBitDepth,
                                                        cancelled: { [unowned self] in isCancelled })
        }
        if isCancelled {
            print("[TrackBoundary] user took over while waiting; not resuming")
            keepAlive?.stop()
            return
        }
        guard ready else {
            print("[TrackBoundary] device not ready within \(Self.readyTimeout)s; leaving Music paused")
            keepAlive?.stop()
            return
        }
        let gap = Defaults.shared.switchGap
        print("[TrackBoundary] device ready \(Self.ms(since: switched)) after switching; \(gap.rawValue) gap \(Int(gap.extraWait * 1000)) ms")
        let gapEnd = Date().addingTimeInterval(gap.extraWait)
        while Date() < gapEnd, !isCancelled {
            Thread.sleep(forTimeInterval: 0.01)
        }

        // don't resume if the user moved on or pressed play themselves while we waited
        if !isCancelled, MusicPlayer.isPaused(on: persistentID) {
            MusicPlayer.restart()
            print("[TrackBoundary] resumed \(Self.ms(since: received)) after track start")
        }
        // keep the device running until Music has taken over, so it doesn't stop and restart
        queue.asyncAfter(deadline: .now() + 0.5) {
            keepAlive?.stop()
        }
    }

    /// Music's own sample rate for the current local track is one round trip and no file I/O.
    /// The file header is only read when bit depth matters.
    private func lookupCurrentTrack() -> LocalTrack.Lookup {
        if outputDevices.enableBitDepthDetection {
            return LocalTrack.lookupCurrent(attempts: 5)
        }
        return scripts.lookupLocalTrack(attempts: 5)
    }

    private static func ms(since date: Date) -> String {
        String(format: "%.0f ms", Date().timeIntervalSince(date) * 1000)
    }
}

enum DeviceFormat {

    static func nominalSampleRate(_ device: AudioObjectID) -> Float64? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    static func physicalFormat(_ device: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr, let stream = streams.first else { return nil }

        address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyPhysicalFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }

    /// Both the device's nominal rate and its output stream's physical format report the target.
    static func matches(_ device: AudioObjectID, format: AudioStreamBasicDescription, checkBitDepth: Bool) -> Bool {
        guard nominalSampleRate(device) == format.mSampleRate,
              let physical = physicalFormat(device),
              physical.mSampleRate == format.mSampleRate else { return false }
        return !checkBitDepth || physical.mBitsPerChannel == format.mBitsPerChannel
    }

    static func isRunning(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunning, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    /// The HAL's measurement of the device clock; only meaningful while the device runs.
    static func actualSampleRate(_ device: AudioObjectID) -> Float64? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyActualSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    // Measured on a Neumann MT 48 (research/track-boundary-switch/log.md): nominal rate and physical
    // format change ~60 ms after the switch, but the device stops, restarts (sometimes several
    // times) 1.1-1.7 s later, and the measured clock can start 6% off and converge over seconds.
    static let steadyRunning: TimeInterval = 0.5
    static let clockTolerance = 0.005 // measured rate within 0.5% of nominal
    static let unmeasuredFallback: TimeInterval = 2 // accept steady running if the HAL never reports a measurement
    static let stallAfter: TimeInterval = 2.5
    static let stallStopped: TimeInterval = 0.25
    static let stallRestartInterval: TimeInterval = 1.5

    static func waitUntilFormatMatches(_ device: AudioObjectID, format: AudioStreamBasicDescription, checkBitDepth: Bool,
                                       timeout: TimeInterval = TrackBoundarySwitcher.readyTimeout,
                                       cancelled: () -> Bool = { false }) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !cancelled() {
            if matches(device, format: format, checkBitDepth: checkBitDepth) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    /// Needs the device running (see SilentOutput) to ever return true.
    static func waitUntilReady(_ device: AudioObjectID, format: AudioStreamBasicDescription, checkBitDepth: Bool,
                               timeout: TimeInterval = TrackBoundarySwitcher.readyTimeout,
                               cancelled: () -> Bool = { false },
                               stalled: () -> Void = {}) -> Bool {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var runningSince: Date?
        var stoppedSince: Date?
        var measured = false
        var starts = 0, restarts = 0
        var lastRestart = start
        var wasRunning = true // the device is usually running (our silent output) when the switch begins
        while Date() < deadline, !cancelled() {
            let running = isRunning(device)
            if running, !wasRunning { starts += 1 }
            wasRunning = running
            stoppedSince = running ? nil : (stoppedSince ?? Date())
            // The MT 48 sometimes keeps stopping and restarting for seconds after a switch.
            // Normal start-up flapping ends by ~1.5 s, so only restart the keep-alive after that.
            if let stoppedSince, Date().timeIntervalSince(start) >= stallAfter,
               Date().timeIntervalSince(stoppedSince) >= stallStopped,
               Date().timeIntervalSince(lastRestart) >= stallRestartInterval {
                restarts += 1
                lastRestart = Date()
                print("[TrackBoundary] device keeps stopping (\(starts) starts); restarting silent output")
                stalled()
            }
            if matches(device, format: format, checkBitDepth: checkBitDepth), running {
                let since = runningSince ?? Date()
                runningSince = since
                let steadyFor = Date().timeIntervalSince(since)
                if let actual = actualSampleRate(device) {
                    // right after a restart the HAL reports the nominal rate exactly, before measuring
                    if actual != format.mSampleRate { measured = true }
                    let deviation = abs(actual / format.mSampleRate - 1)
                    if steadyFor >= steadyRunning,
                       (measured && deviation <= clockTolerance) || steadyFor >= unmeasuredFallback {
                        if restarts > 0 || starts > 3 {
                            print("[TrackBoundary] ready after \(starts) starts, \(restarts) keep-alive restarts")
                        }
                        return true
                    }
                }
            } else {
                runningSince = nil
                measured = false
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        print("[TrackBoundary] not ready: matches=\(matches(device, format: format, checkBitDepth: checkBitDepth)) running=\(isRunning(device)) nominal=\(nominalSampleRate(device) ?? 0) actual=\(actualSampleRate(device) ?? 0) measured=\(measured) starts=\(starts) restarts=\(restarts) steadyFor=\(runningSince.map { String(format: "%.2f s", Date().timeIntervalSince($0)) } ?? "not running")")
        return false
    }
}

/// Runs the device with silence while Music is paused, so the HAL restarts it at the new rate
/// and measures its clock.
final class SilentOutput {
    private let device: AudioObjectID
    private var procID: AudioDeviceIOProcID?

    init?(device: AudioObjectID) {
        self.device = device
        guard start() else { return nil }
    }

    private func start() -> Bool {
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, _, _, outData, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(outData) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }
        guard status == noErr, let procID else {
            print("[TrackBoundary] could not create silent output (\(status))")
            return false
        }
        let startStatus = AudioDeviceStart(device, procID)
        guard startStatus == noErr else {
            print("[TrackBoundary] could not start silent output (\(startStatus))")
            stop()
            return false
        }
        return true
    }

    func restart() {
        stop()
        _ = start()
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }

    deinit {
        stop()
    }
}

/// Extra wait after the device is ready, for DACs whose clock lock lags what the HAL reports.
enum SwitchGap: String, CaseIterable {
    case short = "Short"
    case normal = "Normal"
    case long = "Long"

    var extraWait: TimeInterval {
        switch self {
        case .short: return 0
        case .normal: return 0.25
        case .long: return 1
        }
    }
}

enum MusicPlayer {

    /// AppleScript's persistent ID is the notification's signed 64-bit value as 16 hex digits.
    static func hexPersistentID(_ id: Int64) -> String {
        String(format: "%016llX", UInt64(bitPattern: id))
    }

    static func signedPersistentID(_ hex: String) -> Int64? {
        UInt64(hex, radix: 16).map { Int64(bitPattern: $0) }
    }

    /// Not thread-safe: use each instance from one queue.
    final class CompiledScripts {
        private let pauseScript = compile("tell application \"Music\" to pause")
        private let localSampleRateScript = compile("""
        tell application "Music"
            if player state is stopped then return ""
            set t to current track
            if class of t is not file track then return ""
            try
                if cloud status of t is subscription then return ""
            end try
            if location of t is missing value then return ""
            return (sample rate of t) as string
        end tell
        """)

        private static func compile(_ source: String) -> NSAppleScript? {
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            script?.compileAndReturnError(&error)
            if let error { print("[APPLESCRIPT] compile - \(error)") }
            return script
        }

        private func run(_ script: NSAppleScript?) -> String? {
            var error: NSDictionary?
            let output = script?.executeAndReturnError(&error).stringValue
            if let error {
                print("[APPLESCRIPT] - \(error)")
                return nil
            }
            return output ?? ""
        }

        func pause() -> Bool {
            run(pauseScript) != nil
        }

        func lookupLocalTrack(attempts: Int) -> LocalTrack.Lookup {
            guard LocalTrack.isMusicRunning else { return .notLocal }
            var output = run(localSampleRateScript)
            for _ in 1..<max(attempts, 1) where output == nil {
                Thread.sleep(forTimeInterval: 0.1)
                output = run(localSampleRateScript)
            }
            guard let output else { return .unknown }
            guard let sampleRate = Double(output), sampleRate > 0 else { return .notLocal }
            return .local(CMPlayerStats(sampleRate: sampleRate, bitDepth: 24, date: Date(), priority: 100))
        }
    }

    static func isPaused(on persistentID: String) -> Bool {
        let script = """
        tell application "Music"
            return (player state as string) & " " & persistent ID of current track
        end tell
        """
        let state = LocalTrack.runScript(script)
        if state != "paused \(persistentID)" {
            print("[TrackBoundary] not resuming: Music reports \(state ?? "an error")")
            return false
        }
        return true
    }

    static func restart() {
        _ = LocalTrack.runScript("""
        tell application "Music"
            set player position to 0
            play
        end tell
        """)
    }
}
