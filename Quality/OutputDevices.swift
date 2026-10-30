//
//  OutputDevices.swift
//  Quality
//
//  Created by Vincent Neo on 20/4/22.
//

import Combine
import Sweep
import Foundation
import SimplyCoreAudio
import CoreAudioTypes
import MediaRemoteAdapter

class OutputDevices: ObservableObject {
    @Published var selectedOutputDevice: AudioDevice? // auto if nil
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]()
    @Published var currentSampleRate: Float64?
    @Published var currentBitDepth: Int?
    @Published var enableBitDepthDetection = Defaults.shared.userPreferBitDepthDetection
    
    @Published var isPlaying: Bool = false
    
    private var targetSampleRate: Float64?
    private var targetBitDepth: Int?
    private var trackChangeTime: Date?
    private var pendingTargetSampleRate: Float64?
    private var pendingTargetBitDepth: Int?
    private var initialFormatSetForCurrentTrack: Bool = false
    private var activeDecoderAddress: String?
    private var pendingDecoderAddress: String?
    
    private let pauseScript = NSAppleScript(source: "tell application \"Music\" to pause")
    private let playScript = NSAppleScript(source: "tell application \"Music\" to play")
    private let muteScript = NSAppleScript(source: "tell application \"Music\" to set muted to true")
    private let unmuteScript = NSAppleScript(source: "tell application \"Music\" to set muted to false")
    private let rewindScript = NSAppleScript(source: "try\ntell application \"Music\" to set player position to 0\nend try")
    
    private let logStreamListener = LogStreamListener()
    
    private var enableBitDepthDetectionCancellable: AnyCancellable?
    
    private let coreAudio = SimplyCoreAudio()
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    
    private var consoleQueue = DispatchQueue(label: "consoleQueue", qos: .userInteractive)
    
    private var processQueue = DispatchQueue(label: "processQueue", qos: .userInitiated)
    
    private var previousSampleRate: Float64?
    private var previousBitDepth: Int?
    var trackAndSample = [MediaTrack : Float64]()
    var trackAndBitDepth = [MediaTrack : Int]()
    var previousTrack: MediaTrack?
    var currentTrack: MediaTrack?
    private var currentTrackDuration: Double = 0.0
    private var isNearEndOfTrack = false
    var currentPlaybackTime: Double = 0.0
    
    private let loggerQueue = DispatchQueue(label: "outputDevicesLoggerQueue", qos: .utility)
    
    private func log(_ message: String) {
        loggerQueue.async {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            print("[\(formatter.string(from: Date()))] [OutputDevices] \(message)")
            fflush(stdout)
        }
    }
    
    func applyCurrentFormatToActiveDevice() {
        guard let targetSR = self.targetSampleRate else { return }
        let targetBD = self.targetBitDepth ?? 24
        
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        guard let defaultDevice = defaultDevice else { return }
        
        processQueue.async { [weak self] in
            guard let self = self else { return }
            let stat = CMPlayerStats(sampleRate: targetSR, bitDepth: targetBD, date: Date(), priority: 5, decoderAddress: self.activeDecoderAddress)
            self.switchSampleRateWithStat(stat, onDevice: defaultDevice, isDeviceChange: true)
        }
    }
    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        self.getDeviceSampleRate()
        
        changesCancellable =
            NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { _ in
                self.outputDevices = self.coreAudio.allOutputDevices
                if let savedUID = Defaults.shared.selectedDeviceUID {
                    self.selectedOutputDevice = self.outputDevices.first(where: { $0.uid == savedUID })
                }
            })
        
        defaultChangesCancellable =
            NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged).sink(receiveValue: { _ in
                self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
                self.getDeviceSampleRate()
                self.applyCurrentFormatToActiveDevice()
            })
        
        outputSelectionCancellable = $selectedOutputDevice.sink(receiveValue: { _ in
            self.getDeviceSampleRate()
            self.applyCurrentFormatToActiveDevice()
        })
        
        enableBitDepthDetectionCancellable = Defaults.shared.$userPreferBitDepthDetection.sink(receiveValue: { newValue in
            self.enableBitDepthDetection = newValue
        })

        logStreamListener.onLogReceived = { [weak self] stat in
            self?.handleRealtimeLog(stat)
        }
        logStreamListener.start()
        
        // Restore saved device selection at launch
        if let savedUID = Defaults.shared.selectedDeviceUID {
            self.selectedOutputDevice = self.outputDevices.first(where: { $0.uid == savedUID })
        }
    }
    
    deinit {
        logStreamListener.stop()
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
        //timer.upstream.connect().cancel()
    }
    func playbackTimeDidChange(elapsedTime: Double) {
        self.currentPlaybackTime = elapsedTime
        guard isPlaying, currentTrackDuration > 0.0 else { return }
        let remainingTime = currentTrackDuration - elapsedTime
        isNearEndOfTrack = (remainingTime <= 2.0 && remainingTime > 0.0)
    }
    
    private func handleRealtimeLog(_ stat: CMPlayerStats) {
        processQueue.async { [weak self] in
            guard let self = self else { return }
            let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
            guard let defaultDevice = defaultDevice else { return }
            self.switchSampleRateWithStat(stat, onDevice: defaultDevice)
        }
    }
    
    func getDeviceSampleRate() {
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        guard let sampleRate = defaultDevice?.nominalSampleRate else { return }
        self.updateSampleRate(sampleRate, bitDepth: nil)
    }
    
    func getSampleRateFromAppleScript() -> Double? {
        let scriptContents = "tell application \"Music\" to get sample rate of current track"
        var error: NSDictionary?
        
        if let script = NSAppleScript(source: scriptContents) {
            let output = script.executeAndReturnError(&error).stringValue
            
            if let error = error {
                print("[APPLESCRIPT] - \(error)")
            }
            guard let output = output else { return nil }

            if output == "missing value" {
                return nil
            }
            else {
                return Double(output)
            }
        }
        
        return nil
    }
    
    func getAllStats() -> [CMPlayerStats] {
        var allStats = [CMPlayerStats]()
        
        do {
//            let musicLogs = try Console.getRecentEntries(type: .music)
            let coreAudioLogs = try Console.getRecentEntries(type: .coreAudio)
//            let coreMediaLogs = try Console.getRecentEntries(type: .coreMedia)
            
//            allStats.append(contentsOf: CMPlayerParser.parseMusicConsoleLogs(musicLogs))
//            if enableBitDepthDetection {
                allStats.append(contentsOf: CMPlayerParser.parseCoreAudioConsoleLogs(coreAudioLogs))
//            }
//            else {
//                allStats.append(contentsOf: CMPlayerParser.parseCoreMediaConsoleLogs(coreMediaLogs))
//            }

//            allStats.sort(by: {$0.priority > $1.priority})
            print("[getAllStats] \(allStats)")
        }
        catch {
            print("[getAllStats, error] \(error)")
        }
        
        return allStats
    }
    
    private func executeCompiledScript(_ script: NSAppleScript?) {
        DispatchQueue.main.async {
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            if let error = error {
                print("[AppleScript Error] \(error)")
            }
        }
    }
    
    private func pauseMusicApp() {
        executeCompiledScript(pauseScript)
    }
    
    private func playMusicApp() {
        executeCompiledScript(playScript)
    }
    
    private func muteMusicApp() {
        executeCompiledScript(muteScript)
    }
    
    private func unmuteMusicApp() {
        executeCompiledScript(unmuteScript)
    }
    
    private func rewindMusicApp() {
        executeCompiledScript(rewindScript)
    }
    
    func switchLatestSampleRate(recursion: Bool = false) {
        let allStats = self.getAllStats()
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        
        guard let defaultDevice = defaultDevice else { return }
        
        if let first = allStats.first {
            self.switchSampleRateWithStat(first, onDevice: defaultDevice, recursion: recursion)
        }
        else if !recursion {
            processQueue.asyncAfter(deadline: .now() + 1) {
                self.switchLatestSampleRate(recursion: true)
            }
        }
        else {
            if self.currentTrack == self.previousTrack {
                print("same track, ignore cache")
                return
            }
        }
    }
    
    func switchSampleRateWithStat(_ first: CMPlayerStats, onDevice defaultDevice: AudioDevice, recursion: Bool = false, isDeviceChange: Bool = false) {
        guard let supported = defaultDevice.nominalSampleRates else { return }
        
        let sampleRate = Float64(first.sampleRate)
        let bitDepth = Int32(first.bitDepth)
        
        if !isDeviceChange {
            if self.currentTrack == self.previousTrack, let prevSampleRate = currentSampleRate, prevSampleRate > sampleRate {
                return
            }
            
            if sampleRate == 48000 && !recursion {
                processQueue.asyncAfter(deadline: .now() + 1) {
                    self.switchLatestSampleRate(recursion: true)
                }
            }
            
            // 1. Separate decoder instance detection: next-track pre-buffering
            if self.isPlaying && self.initialFormatSetForCurrentTrack {
                if let activeAddr = self.activeDecoderAddress,
                   let incomingAddr = first.decoderAddress,
                   activeAddr != incomingAddr {
                    self.log("Pre-buffer detected from separate decoder instance (\(incomingAddr) != active \(activeAddr)). Deferring \(sampleRate)Hz/\(bitDepth)bit for next track.")
                    self.pendingTargetSampleRate = sampleRate
                    self.pendingTargetBitDepth = Int(bitDepth)
                    self.pendingDecoderAddress = incomingAddr
                    return
                }
            }
            
            // 2. Format change evaluation during current track
            if self.isPlaying && self.initialFormatSetForCurrentTrack {
                let curSR = self.targetSampleRate ?? (defaultDevice.nominalSampleRate ?? 0.0)
                let curBD = self.targetBitDepth ?? 16
                let inBD = Int(bitDepth)
                
                let isDifferentFormat = (sampleRate != curSR) || (enableBitDepthDetection && inBD != curBD)
                if isDifferentFormat {
                    let isDowngrade = (sampleRate < curSR) || (sampleRate == curSR && inBD < curBD)
                    let isUpgrade = (sampleRate > curSR) || (sampleRate == curSR && inBD > curBD)
                    
                    // If more than 5.0s into playback, defer format changes to prevent interrupting listening
                    let isPastInitialPlayback = self.currentPlaybackTime > 5.0
                    
                    if isDowngrade || (isUpgrade && (!Defaults.shared.userPreferMidSongUpgrades || isPastInitialPlayback)) {
                        self.log("Mid-song format change deferred (SR: \(sampleRate) vs \(curSR), elapsed: \(String(format: "%.1f", self.currentPlaybackTime))s). Storing as pending.")
                        self.pendingTargetSampleRate = sampleRate
                        self.pendingTargetBitDepth = inBD
                        if let addr = first.decoderAddress {
                            self.pendingDecoderAddress = addr
                        }
                        return
                    }
                }
            }
        }
        
        guard let formats = self.getFormats(bestStat: first, device: defaultDevice) else { return }
        
        // https://stackoverflow.com/a/65060134
        var nearest = supported.min(by: {
            abs($0 - sampleRate) < abs($1 - sampleRate)
        })
        
        let nearestBitDepth = formats.min(by: {
            abs(Int32($0.mBitsPerChannel) - bitDepth) < abs(Int32($1.mBitsPerChannel) - bitDepth)
        })
        
        if Defaults.shared.userPreferSampleRateMultiples,
           let nearestSampleRate = nearest,
           nearestSampleRate != sampleRate, supported.contains(sampleRate / 2) {
            nearest = sampleRate / 2
        }
        
        let nearestFormat = formats.filter({
            $0.mSampleRate == nearest && $0.mBitsPerChannel == nearestBitDepth?.mBitsPerChannel
        })
        
        if let suitableFormat = nearestFormat.first {
            let targetSR = suitableFormat.mSampleRate
            let targetBD = Int(suitableFormat.mBitsPerChannel)
            
            if !isDeviceChange && targetSampleRate == targetSR && (!enableBitDepthDetection || targetBitDepth == targetBD) {
                return
            }
            
            let streams = defaultDevice.streams(scope: .output)
            let currentFormat = streams?.first?.physicalFormat
            let currentSampleRateVal = defaultDevice.nominalSampleRate ?? (currentFormat?.mSampleRate ?? 0.0)
            
            let isSampleRateDifferent = abs(currentSampleRateVal - targetSR) >= 1.0
            let isDifferent: Bool
            if enableBitDepthDetection {
                let currentBD = currentFormat.map { Int($0.mBitsPerChannel) } ?? 0
                isDifferent = isSampleRateDifferent || (currentBD != targetBD)
            } else {
                isDifferent = isSampleRateDifferent
            }
            
            if !isDifferent {
                self.targetSampleRate = targetSR
                self.targetBitDepth = targetBD
                if let addr = first.decoderAddress {
                    self.activeDecoderAddress = addr
                }
                self.updateSampleRate(targetSR, bitDepth: targetBD)
                self.initialFormatSetForCurrentTrack = true
                if let currentTrack = self.currentTrack {
                    self.trackAndSample[currentTrack] = targetSR
                    self.trackAndBitDepth[currentTrack] = targetBD
                }
                return
            }
            
            self.targetSampleRate = targetSR
            self.targetBitDepth = targetBD
            if let addr = first.decoderAddress {
                self.activeDecoderAddress = addr
            }
            self.pendingTargetSampleRate = nil
            self.pendingTargetBitDepth = nil
            self.pendingDecoderAddress = nil
            self.initialFormatSetForCurrentTrack = true
            
            Task {
                let trackFired = self.trackChangeTime ?? Date()
                let logTime = first.date
                let detectedTime = Date()
                
                let wasPlaying = self.isPlaying
                var muteTime: Date?
                var rewindTime: Date?
                
                if wasPlaying {
                    self.log("Muting Apple Music")
                    self.muteMusicApp()
                    muteTime = Date()
                    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms wait for mute to process
                }
                
                let dacStartTime = Date()
                self.log("Changing DAC format to \(targetSR) Hz / \(targetBD) bit")
                if self.enableBitDepthDetection {
                    self.setFormats(device: defaultDevice, format: suitableFormat)
                } else {
                    defaultDevice.setNominalSampleRate(targetSR)
                }
                
                let startTime = Date()
                var isComplete = false
                while Date().timeIntervalSince(startTime) < 1.5 {
                    let curSR = defaultDevice.nominalSampleRate ?? 0.0
                    let curStreams = defaultDevice.streams(scope: .output)
                    let curBD = curStreams?.first?.physicalFormat?.mBitsPerChannel ?? 0
                    
                    let sampleRateMatches = abs(curSR - targetSR) < 1.0
                    let bitDepthMatches = !self.enableBitDepthDetection || (Int(curBD) == targetBD)
                    
                    if sampleRateMatches && bitDepthMatches {
                        isComplete = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 20_000_000) // Poll every 20ms
                }
                let dacEndTime = Date()
                self.log("DAC change completed: \(isComplete)")
                
                try? await Task.sleep(nanoseconds: 20_000_000) // 20ms stabilizer sleep
                
                self.updateSampleRate(targetSR, bitDepth: targetBD)
                if let currentTrack = self.currentTrack {
                    self.trackAndSample[currentTrack] = targetSR
                    self.trackAndBitDepth[currentTrack] = targetBD
                }
                
                var unmuteTime: Date?
                if wasPlaying {
                    if !isDeviceChange && self.currentPlaybackTime < 5.0 {
                        self.rewindMusicApp()
                        rewindTime = Date()
                        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms wait for rewind to process
                    }
                    
                    self.unmuteMusicApp()
                    unmuteTime = Date()
                }
                
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                
                var diag = "\n[Timing Diagnostics]\n--------------------------------------------------\n"
                diag += "1. Track Change Fired:           \(formatter.string(from: trackFired)) (Base)\n"
                diag += "2. Music Log Written:            \(formatter.string(from: logTime)) (Diff: \(Int(logTime.timeIntervalSince(trackFired) * 1000))ms from Track Change)\n"
                diag += "3. Log Detected by App:          \(formatter.string(from: detectedTime)) (Diff: \(Int(detectedTime.timeIntervalSince(logTime) * 1000))ms log scan delay)\n"
                if wasPlaying, let muteTime = muteTime, let rewindTime = rewindTime, let unmuteTime = unmuteTime {
                    diag += "4. Mute Sent:                    \(formatter.string(from: muteTime)) (Diff: \(Int(muteTime.timeIntervalSince(detectedTime) * 1000))ms from detect)\n"
                    diag += "5. DAC Change Sent:              \(formatter.string(from: dacStartTime)) (Diff: \(Int(dacStartTime.timeIntervalSince(muteTime) * 1000))ms from mute)\n"
                    diag += "6. DAC Change Confirmed:         \(formatter.string(from: dacEndTime)) (Diff: \(Int(dacEndTime.timeIntervalSince(dacStartTime) * 1000))ms DAC transition time)\n"
                    diag += "7. Rewind (00:00) Sent:          \(formatter.string(from: rewindTime)) (Diff: \(Int(rewindTime.timeIntervalSince(dacEndTime) * 1000))ms from DAC complete)\n"
                    diag += "8. Unmute Sent:                  \(formatter.string(from: unmuteTime)) (Diff: \(Int(unmuteTime.timeIntervalSince(rewindTime) * 1000))ms from rewind)\n"
                    diag += "--------------------------------------------------\n"
                    diag += "Total Sync Latency: \(Int(unmuteTime.timeIntervalSince(trackFired) * 1000))ms\n"
                } else {
                    diag += "4. DAC Change Sent:              \(formatter.string(from: dacStartTime))\n"
                    diag += "5. DAC Change Confirmed:         \(formatter.string(from: dacEndTime)) (Diff: \(Int(dacEndTime.timeIntervalSince(dacStartTime) * 1000))ms DAC transition time)\n"
                    diag += "--------------------------------------------------\n"
                    diag += "Total Sync Latency: \(Int(dacEndTime.timeIntervalSince(trackFired) * 1000))ms\n"
                }
                diag += "--------------------------------------------------"
                self.log(diag)
            }
        }
        else if !recursion {
            processQueue.asyncAfter(deadline: .now() + 1) {
                self.switchLatestSampleRate(recursion: true)
            }
        }
        else {
            if self.currentTrack == self.previousTrack {
                return
            }
        }
    }
    
    func getFormats(bestStat: CMPlayerStats, device: AudioDevice) -> [AudioStreamBasicDescription]? {
        // new sample rate + bit depth detection route
        let streams = device.streams(scope: .output)
        let availableFormats = streams?.first?.availablePhysicalFormats?.compactMap({$0.mFormat})
        return availableFormats
    }
    
    func setFormats(device: AudioDevice?, format: AudioStreamBasicDescription?) {
        guard let device, let format else { return }
        let streams = device.streams(scope: .output)
        if streams?.first?.physicalFormat != format {
            streams?.first?.physicalFormat = format
        }
    }
    
    func updateSampleRate(_ sampleRate: Float64, bitDepth: Int?) {
        self.previousSampleRate = sampleRate
        self.previousBitDepth = bitDepth
        DispatchQueue.main.async { [self] in
            let readableSampleRate = sampleRate / 1000
            self.currentSampleRate = readableSampleRate
            self.currentBitDepth = bitDepth
            
            let delegate = AppDelegate.instance
            
            if enableBitDepthDetection {
                if let bitDepth = bitDepth {
                    delegate?.statusItemTitle = String(format: "%.1f kHz / %d bit", readableSampleRate, bitDepth)
                } else {
                    delegate?.statusItemTitle = String(format: "%.1f kHz / ? bit", readableSampleRate)
                }
            } else {
                delegate?.statusItemTitle = String(format: "%.1f kHz", readableSampleRate)
            }
        }
        self.runUserScript(sampleRate, bitDepth: bitDepth)
    }
    
    func runUserScript(_ sampleRate: Float64, bitDepth: Int?) {
        guard let scriptPath = Defaults.shared.shellScriptPath else { return }
        let argumentSampleRate = String(Int(sampleRate))
        var arguments = [argumentSampleRate]
        
        // Add bit depth as second argument if available
        if let bitDepth = bitDepth {
            arguments.append(String(bitDepth))
        }
        
        Task.detached {
            let scriptURL = URL(fileURLWithPath: scriptPath)
            do {
                let task = try NSUserUnixTask(url: scriptURL)
                try await task.execute(withArguments: arguments)
            }
            catch {
                print("TASK ERR \(error)")
            }
        }
    }
    
    func trackDidChange(_ newTrack: TrackInfo) {
        let incomingTrack = MediaTrack(trackInfo: newTrack)
        if self.currentTrack != incomingTrack {
            self.trackChangeTime = Date()
            self.currentPlaybackTime = 0.0
            self.initialFormatSetForCurrentTrack = false
            self.activeDecoderAddress = nil
            
            let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
            if let defaultDevice = defaultDevice {
                // 1. Pending (Pre-buffered format from previous track) - 0ms
                if let pendingSR = self.pendingTargetSampleRate {
                    let pendingBD = self.pendingTargetBitDepth ?? 24
                    let pendingAddr = self.pendingDecoderAddress
                    self.pendingTargetSampleRate = nil
                    self.pendingTargetBitDepth = nil
                    self.pendingDecoderAddress = nil
                    self.activeDecoderAddress = pendingAddr
                    
                    self.log("Applying pending pre-buffered format (\(pendingSR)Hz/\(pendingBD)bit) for new track (decoder: \(pendingAddr ?? "nil"))")
                    let stat = CMPlayerStats(sampleRate: pendingSR, bitDepth: pendingBD, date: Date(), priority: 5, decoderAddress: pendingAddr)
                    self.switchSampleRateWithStat(stat, onDevice: defaultDevice)
                }
                // 2. Memory Cache (Previously played track) - 0ms
                else if let cachedSR = self.trackAndSample[incomingTrack] {
                    let cachedBD = self.trackAndBitDepth[incomingTrack] ?? 24
                    self.log("Applying cached format (\(cachedSR)Hz/\(cachedBD)bit) for known track")
                    let stat = CMPlayerStats(sampleRate: cachedSR, bitDepth: cachedBD, date: Date(), priority: 4, decoderAddress: nil)
                    self.switchSampleRateWithStat(stat, onDevice: defaultDevice)
                }
                // 3. AppleScript Metadata Immediate Query - ~50-100ms
                else {
                    self.processQueue.async { [weak self] in
                        guard let self = self else { return }
                        if let appleScriptSR = self.getSampleRateFromAppleScript() {
                            if !self.initialFormatSetForCurrentTrack {
                                self.log("Applying AppleScript detected sample rate (\(appleScriptSR)Hz) immediately on track change")
                                let stat = CMPlayerStats(sampleRate: appleScriptSR, bitDepth: 24, date: Date(), priority: 3, decoderAddress: nil)
                                self.switchSampleRateWithStat(stat, onDevice: defaultDevice)
                            }
                        }
                    }
                }
            }
        }
        self.previousTrack = self.currentTrack
        self.currentTrack = incomingTrack
        self.isNearEndOfTrack = false
        
        if let durationMicros = newTrack.payload.durationMicros {
            self.currentTrackDuration = durationMicros / 1_000_000.0
        } else {
            self.currentTrackDuration = 0.0
        }
        
        DispatchQueue.main.async {
            self.isPlaying = newTrack.payload.isPlaying ?? false
        }
    }
}
