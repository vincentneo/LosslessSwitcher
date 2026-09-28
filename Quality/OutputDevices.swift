//
//  OutputDevices.swift
//  Quality
//
//  Created by Vincent Neo on 20/4/22.
//

import Combine
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
    
    private var enableBitDepthDetectionCancellable: AnyCancellable?
    
    private let coreAudio = SimplyCoreAudio()
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    private var timerCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    
    private var consoleQueue = DispatchQueue(label: "consoleQueue", qos: .userInteractive)
    
    private var processQueue = DispatchQueue(label: "processQueue", qos: .userInitiated)
    
    private var previousSampleRate: Float64?
    private var previousBitDepth: Int?
    var trackAndSample = [MediaTrack : Float64]()
    var trackAndBitDepth = [MediaTrack : Int]()
    var previousTrack: MediaTrack?
    var currentTrack: MediaTrack?
    
    var timerActive = false
    var timerCalls = 0
    
    /// Not the engine's own devices: the "LosslessSwitcher" virtual output (LSOutput_UID) and the
    /// process-tap engine's private aggregate "LosslessSwitcher renderer" (visible to this process
    /// only). Selecting either would point the app at itself.
    static func selectable(_ devices: [AudioDevice]) -> [AudioDevice] {
        devices.filter { $0.uid != VirtualDeviceEngine.deviceUID && !$0.name.hasPrefix("LosslessSwitcher") }
    }

    init() {
        self.outputDevices = Self.selectable(self.coreAudio.allOutputDevices)
        // the saved Selected Device (AppDelegate.handleDevicesMenu restored it before the SwiftUI menu)
        if let uid = Defaults.shared.selectedDeviceUID {
            self.selectedOutputDevice = self.outputDevices.first { $0.uid == uid }
        }
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        self.getDeviceSampleRate()
        
        changesCancellable =
            NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { _ in
                self.outputDevices = Self.selectable(self.coreAudio.allOutputDevices)
            })
        
        defaultChangesCancellable =
            NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged).sink(receiveValue: { _ in
                self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
                self.getDeviceSampleRate()
            })
        
        outputSelectionCancellable = $selectedOutputDevice.sink(receiveValue: { _ in
            self.getDeviceSampleRate()
        })
        
        enableBitDepthDetectionCancellable = Defaults.shared.$userPreferBitDepthDetection.sink(receiveValue: { newValue in
            self.enableBitDepthDetection = newValue
        })

        
    }
    
    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        timerCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
        //timer.upstream.connect().cancel()
    }
    
    func renewTimer() {
        if timerCancellable != nil { return }
        timerCancellable = Timer
            .publish(every: 2, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.timerCalls += 1
                if self.timerCalls >= 5 {
                    self.timerCalls = 0
                    self.timerCancellable?.cancel()
                    self.timerCancellable = nil
                }
                else {
                    self.processQueue.async {
                        self.switchLatestSampleRate()
                    }
                }
            }
    }
    
    func getDeviceSampleRate() {
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        guard let sampleRate = defaultDevice?.nominalSampleRate else { return }
        self.updateSampleRate(sampleRate, bitDepth: nil)
    }
    
    func getAllStats() -> [CMPlayerStats] {
        var allStats = [CMPlayerStats]()

        // RendererEngine owns rate switching; a rate set from here would land mid-track.
        if Defaults.shared.userPreferRendererEngine {
            return []
        }
        if Defaults.shared.userPreferPauseWhileSwitching {
            // TrackBoundarySwitcher owns local tracks (switching here would change the rate mid-track)
            // and has already asked Music; asking again from this timer competes with Music's controls.
            if TrackBoundarySwitcher.currentTrackKind != .notLocal {
                return []
            }
        }
        // A local file's own header is authoritative; recent log lines may still describe the previous track.
        else if Defaults.shared.userPreferLocalFileDetection, let localStats = LocalTrack.currentStats() {
            return [localStats]
        }
        
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
    
    func switchLatestSampleRate(recursion: Bool = false) {
        let allStats = self.getAllStats()
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        
        if let first = allStats.first, defaultDevice?.nominalSampleRates != nil {
            let sampleRate = Float64(first.sampleRate)
            
            if self.currentTrack == self.previousTrack, let prevSampleRate = currentSampleRate, prevSampleRate > sampleRate {
                print("same track, prev sample rate is higher")
                return
            }
            
            if sampleRate == 48000 && !recursion {
                processQueue.asyncAfter(deadline: .now() + 1) {
                    self.switchLatestSampleRate(recursion: true)
                }
            }
            
            if let suitableFormat = self.suitableFormat(for: first, device: defaultDevice!) {
                // The track may have changed while the logs were read; if TrackBoundarySwitcher now
                // owns it, a stale rate applied here would land in the middle of its wait.
                if Defaults.shared.userPreferPauseWhileSwitching, TrackBoundarySwitcher.currentTrackKind != .notLocal {
                    return
                }
                if Defaults.shared.userPreferRendererEngine {
                    return
                }
                self.apply(suitableFormat, device: defaultDevice)
            }

//            if let nearest = nearest {
//                let nearestSampleRate = nearest.element
//                if nearestSampleRate != previousSampleRate {
//                    defaultDevice?.setNominalSampleRate(nearestSampleRate)
//                    self.updateSampleRate(nearestSampleRate)
//                    if let currentTrack = currentTrack {
//                        self.trackAndSample[currentTrack] = nearestSampleRate
//                    }
//                }
//            }
        }
        else if !recursion {
            processQueue.asyncAfter(deadline: .now() + 1) {
                self.switchLatestSampleRate(recursion: true)
            }
        }
        else {
//                print("cache \(self.trackAndSample)")
            if self.currentTrack == self.previousTrack {
                print("same track, ignore cache")
                return
            }
//            if let currentTrack = currentTrack, let cachedSampleRate = trackAndSample[currentTrack] {
//                print("using cached data")
//                if cachedSampleRate != previousSampleRate {
//                    defaultDevice?.setNominalSampleRate(cachedSampleRate)
//                    self.updateSampleRate(cachedSampleRate)
//                }
//            }
        }

    }
    
    /// The device format closest to what the track needs, honoring the sample-rate-multiples preference.
    func suitableFormat(for stat: CMPlayerStats, device: AudioDevice) -> AudioStreamBasicDescription? {
        guard let supported = device.nominalSampleRates,
              let formats = self.getFormats(bestStat: stat, device: device) else { return nil }
        let sampleRate = Float64(stat.sampleRate)
        let bitDepth = Int32(stat.bitDepth)
        
        // https://stackoverflow.com/a/65060134
        var nearest = supported.min(by: {
            abs($0 - sampleRate) < abs($1 - sampleRate)
        })
        
        let nearestBitDepth = formats.min(by: {
            abs(Int32($0.mBitsPerChannel) - bitDepth) < abs(Int32($1.mBitsPerChannel) - bitDepth)
        })
        
        if Defaults.shared.userPreferSampleRateMultiples,
            let nearestSampleRate = nearest,
            nearestSampleRate != sampleRate {
                
                // Cast to Int for mathematically safe modulo operations
                let sourceInt = Int(sampleRate)
                let is44kFamily = sourceInt % 44100 == 0
                let baseRate = is44kFamily ? 44100 : 48000
                
                // Filter supported rates to match the family AND be strictly less than the source
                let familyRates = supported.filter {
                    Int($0) % baseRate == 0 && $0 < sampleRate
                }
                
                // Fall back to the highest available matching rate
                if let bestMatch = familyRates.max() {
                    nearest = bestMatch
                }
            }
        
        let nearestFormat = formats.filter({
            $0.mSampleRate == nearest && $0.mBitsPerChannel == nearestBitDepth?.mBitsPerChannel
        })
        
        print("NEAREST FORMAT \(nearestFormat)")
        return nearestFormat.first
    }
    
    /// Runs `apply` on processQueue, serialized with the regular detection path. For callers on other queues.
    func applySerialized(_ suitableFormat: AudioStreamBasicDescription, device: AudioDevice?, force: Bool = false) {
        processQueue.sync {
            self.apply(suitableFormat, device: device, force: force)
        }
    }

    /// `force` sets the rate even when `previousSampleRate` already matches, for callers that checked the device itself.
    func apply(_ suitableFormat: AudioStreamBasicDescription, device: AudioDevice?, force: Bool = false) {
        if enableBitDepthDetection {
            self.setFormats(device: device, format: suitableFormat)
        }
        else if force || suitableFormat.mSampleRate != previousSampleRate { // bit depth disabled
            device?.setNominalSampleRate(suitableFormat.mSampleRate)
        }
        self.updateSampleRate(suitableFormat.mSampleRate, bitDepth: Int(suitableFormat.mBitsPerChannel))
        if let currentTrack = currentTrack {
            self.trackAndSample[currentTrack] = suitableFormat.mSampleRate
            self.trackAndBitDepth[currentTrack] = Int(suitableFormat.mBitsPerChannel)
        }
    }
    
    func getFormats(bestStat: CMPlayerStats, device: AudioDevice) -> [AudioStreamBasicDescription]? {
        // new sample rate + bit depth detection route
        let streams = device.streams(scope: .output)
        // Non-mixable formats are meant for a single client with exclusive (hog mode) access, as
        // "integer mode" players use them; Music plays through the mixer, so only mixable formats
        // are candidates. Some devices, e.g. a Neumann MT 48, list a non-mixable format next to each
        // mixable one with the same rate and bit depth.
        let availableFormats = streams?.first?.availablePhysicalFormats?
            .compactMap({$0.mFormat})
            .filter({ $0.mFormatFlags & kAudioFormatFlagIsNonMixable == 0 })
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
        // With the Renderer Engine on the default output is its virtual device, and the engine runs
        // the script itself with the DAC's rate and bit depth (VirtualDeviceEngine.runUserScript).
        if !Defaults.shared.userPreferRendererEngine {
            self.runUserScript(sampleRate, bitDepth: bitDepth)
        }
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
        self.previousTrack = self.currentTrack
        self.currentTrack = MediaTrack(trackInfo: newTrack)
        // Music also posts now-playing updates mid-track, e.g. when a station queues its next item.
        // By then the newest decoder log line can belong to that prefetched next track, so only a
        // real track change (and the timer it starts) triggers detection.
        guard self.previousTrack != self.currentTrack else { return }
        self.renewTimer()
        processQueue.async { [unowned self] in
            self.switchLatestSampleRate()
        }
    }
}
