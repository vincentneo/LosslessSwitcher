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
    
    private var detectionGeneration = 0
    private var lastPlaybackPosition: Double?
    private var lastPlaybackObservation: Date?
    private var wasPlaying = false
    var timerActive = false
    var timerCalls = 0
    
    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        self.getDeviceSampleRate()
        
        changesCancellable =
            NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { _ in
                self.outputDevices = self.coreAudio.allOutputDevices
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
    
    // All device and track state is accessed on the main queue. Only log reads
    // run in the background; generation tokens reject results from old tracks.
    func switchLatestSampleRate() {
        beginDetection(at: Date())
    }

    private func beginDetection(at event: Date) {
        detectionGeneration += 1
        let generation = detectionGeneration
        for delay in [0.35, 1.0, 2.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.detectionGeneration == generation else { return }
                self.processQueue.async { [weak self] in
                    guard let self else { return }
                    let stats = self.getAllStats()
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.detectionGeneration == generation,
                              let stat = RateSelection.candidate(stats, near: event) else { return }
                        self.apply(stat)
                    }
                }
            }
        }
    }

    private func apply(_ stat: CMPlayerStats) {
        guard let device = selectedOutputDevice ?? defaultOutputDevice,
              let supported = device.nominalSampleRates,
              var rate = supported.min(by: { abs($0 - stat.sampleRate) < abs($1 - stat.sampleRate) })
        else { return }
        if Defaults.shared.userPreferSampleRateMultiples, rate != stat.sampleRate {
            let sourceInt = Int(stat.sampleRate)
            let baseRate = sourceInt % 44100 == 0 ? 44100 : 48000
            let familyRates = supported.filter {
                Int($0) % baseRate == 0 && $0 < stat.sampleRate
            }
            if let bestMatch = familyRates.max() { rate = bestMatch }
        }
        if enableBitDepthDetection {
            guard let formats = getFormats(bestStat: stat, device: device),
                  let format = formats.filter({ $0.mSampleRate == rate }).min(by: {
                      abs(Int($0.mBitsPerChannel) - stat.bitDepth) < abs(Int($1.mBitsPerChannel) - stat.bitDepth)
                  }) else { return }
            setFormats(device: device, format: format)
        } else if device.nominalSampleRate != rate {
            device.setNominalSampleRate(rate)
        }
        // Display the hardware readback, not the requested rate.
        if let actualRate = device.nominalSampleRate {
            updateSampleRate(actualRate, bitDepth: device.streams(scope: .output)?.first?.physicalFormat.map { Int($0.mBitsPerChannel) })
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
    
    func trackDidChange(_ newTrack: TrackInfo, observedAt: Date) {
        let track = MediaTrack(trackInfo: newTrack)
        guard track.isMusicApp, newTrack.payload.isPlaying == true else {
            detectionGeneration += 1
            wasPlaying = false
            return
        }
        let position = newTrack.payload.elapsedTimeMicros.map { $0 / 1_000_000 }
        var didSeek = false
        if let position, let previous = lastPlaybackPosition, let date = lastPlaybackObservation {
            didSeek = abs(position - previous - observedAt.timeIntervalSince(date)) > 1.0
        }
        let shouldDetect = track != currentTrack || !wasPlaying || didSeek
        previousTrack = currentTrack
        currentTrack = track
        lastPlaybackPosition = position
        lastPlaybackObservation = observedAt
        wasPlaying = true
        if shouldDetect { beginDetection(at: observedAt) }
    }
}
