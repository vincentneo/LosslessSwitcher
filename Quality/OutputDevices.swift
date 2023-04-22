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

class OutputDevices: ObservableObject {
    @Published var selectedOutputDevice: AudioDevice? // auto if nil
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]()
    @Published var currentSampleRate: Float64?
    @Published var currentBitDepth: UInt32?
    @Published var detectedSampleRate: Float64?
    @Published var detectedBitDepth: UInt32?
    @Published var sampleRatesForCurrentBitDepth: [AudioStreamBasicDescription] = []
    @Published var bitDepthsForCurrentSampleRate: [AudioStreamBasicDescription] = []
    @Published var supportedSampleRates: [Float64] = []
    
    private var currentFormatFlags: AudioFormatFlags?
    private var lastNearestFormat: AudioStreamBasicDescription?
    
    @Published var enableAutoSwitch = Defaults.shared.userPreferAutoSwitch
    private var enableAutoSwitchCancellable: AnyCancellable?
    
    @Published var enableBitDepthDetection = Defaults.shared.userPreferBitDepthDetection
    private var enableBitDepthDetectionCancellable: AnyCancellable?
    
    private let coreAudio = SimplyCoreAudio()
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    private var timerCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    
    private var consoleQueue = DispatchQueue(label: "consoleQueue", qos: .userInteractive)
    
    var trackAndSample = [MediaTrack : Float64]()
    var previousTrack: MediaTrack?
    var currentTrack: MediaTrack?
    
    var timerActive = false
    var timerCalls = 0
    
    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        self.getDeviceFormat()
        
        changesCancellable =
        NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { _ in
            self.outputDevices = self.coreAudio.allOutputDevices
        })
        
        defaultChangesCancellable =
        NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged).sink(receiveValue: { _ in
            self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
            self.getDeviceFormat()
        })
        
        outputSelectionCancellable = selectedOutputDevice.publisher.sink(receiveValue: { _ in
            self.getDeviceFormat()
        })
        
        enableBitDepthDetectionCancellable = Defaults.shared.$userPreferBitDepthDetection.sink(receiveValue: { newValue in
            self.enableBitDepthDetection = newValue
            if self.enableAutoSwitch {
                self.setCurrentToDetected()
            }
            self.updateStatusItemTitleText()
            AppDelegate.instance.updateClients()
        })
        
        enableAutoSwitchCancellable = Defaults.shared.$userPreferAutoSwitch.sink(receiveValue: { newValue in
            self.enableAutoSwitch = newValue
            if self.enableAutoSwitch {
                self.setCurrentToDetected()
            }
            AppDelegate.instance.updateClients()
        })
        
    }
    
    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        timerCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
        enableAutoSwitchCancellable?.cancel()
        //timer.upstream.connect().cancel()
    }
    
    func renewTimer() {
        if timerCancellable != nil { return }
        timerCancellable = Timer
            .publish(every: 2, on: .main, in: .default)
            .autoconnect()
            .sink { _ in
                if self.timerCalls == 5 {
                    self.timerCalls = 0
                    self.timerCancellable?.cancel()
                    self.timerCancellable = nil
                }
                else {
                    self.timerCalls += 1
                    self.consoleQueue.async {
                        self.switchLatestSampleRate()
                    }
                }
            }
    }
    
    func getDeviceFormat() {
        guard let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice,
              let format = defaultDevice.streams(scope: .output)?.first?.physicalFormat else { return }
        self.currentSampleRate = format.mSampleRate
        self.currentBitDepth = format.mBitsPerChannel
        self.currentFormatFlags = format.mFormatFlags
        self.updateStatusItemTitleText()
        self.refreshSampeRatesAndBitDepths(defaultDevice)
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
            let musicLogs = try Console.getRecentEntries(type: .music)
            let coreAudioLogs = try Console.getRecentEntries(type: .coreAudio)
            let coreMediaLogs = try Console.getRecentEntries(type: .coreMedia)
            
            allStats.append(contentsOf: CMPlayerParser.parseMusicConsoleLogs(musicLogs))
            if enableBitDepthDetection {
                allStats.append(contentsOf: CMPlayerParser.parseCoreAudioConsoleLogs(coreAudioLogs))
            }
            else {
                allStats.append(contentsOf: CMPlayerParser.parseCoreMediaConsoleLogs(coreMediaLogs))
            }
            
            allStats.sort(by: {$0.priority > $1.priority})
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
        
        if let first = allStats.first, let supported = defaultDevice?.nominalSampleRates {
            let sampleRate = Float64(first.sampleRate)
            let bitDepth = Int32(first.bitDepth)
            
            if self.currentTrack == self.previousTrack, let prevSampleRate = currentSampleRate, prevSampleRate > sampleRate {
                print("same track, prev sample rate is higher")
                return
            }
            
            if sampleRate == 48000 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.switchLatestSampleRate(recursion: true)
                }
            }
            
            let formats = self.getFormats(bestStat: first, device: defaultDevice!)!
            
            // https://stackoverflow.com/a/65060134
            let nearest = supported.min(by: {
                abs($0 - sampleRate) < abs($1 - sampleRate)
            })
            
            let nearestBitDepth = formats.min(by: {
                abs(Int32($0.mBitsPerChannel) - bitDepth) < abs(Int32($1.mBitsPerChannel) - bitDepth)
            })
            
            let nearestFormat = formats.filter({
                $0.mSampleRate == nearest && $0.mBitsPerChannel == nearestBitDepth?.mBitsPerChannel
            })
            
            print("NEAREST FORMAT \(nearestFormat)")
            
            if let suitableFormat = nearestFormat.first {
                self.lastNearestFormat = suitableFormat
                if enableAutoSwitch {
                    self.setFormats(device: defaultDevice, format: suitableFormat)
                } else {
                    AppDelegate.instance.updateClients()
                }
                self.updateStatusItemTitleText()
                if let currentTrack = currentTrack {
                    self.trackAndSample[currentTrack] = suitableFormat.mSampleRate
                }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
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
    
    func getFormats(bestStat: CMPlayerStats, device: AudioDevice) -> [AudioStreamBasicDescription]? {
        // new sample rate + bit depth detection route
        let streams = device.streams(scope: .output)
        let availableFormats = streams?.first?.availablePhysicalFormats?.compactMap({$0.mFormat})
        return availableFormats
    }
    
    func setFormats(device: AudioDevice?, format: AudioStreamBasicDescription?) {
        guard let device, let format, format.mSampleRate > 1000 else { return }
        DispatchQueue.main.async {
            if self.enableBitDepthDetection {
                if format != device.streams(scope: .output)?.first?.physicalFormat {
                    device.streams(scope: .output)?.first?.physicalFormat = format
                    self.currentSampleRate = format.mSampleRate
                    self.currentBitDepth = format.mBitsPerChannel
                    self.currentFormatFlags = format.mFormatFlags
                }
            } else if device.nominalSampleRate != format.mSampleRate {
                device.setNominalSampleRate(format.mSampleRate)
                self.currentSampleRate = format.mSampleRate
            }
            self.refreshSampeRatesAndBitDepths(device)
        }
    }
    
    func updateStatusItemTitleText() {
        DispatchQueue.main.async {
            let currentBitDepth = self.currentBitDepth ?? 0
            let currentSampleRate = self.currentSampleRate ?? 1.0
            let detectedBitDepth = self.lastNearestFormat?.mBitsPerChannel ?? 0
            let detectedSampleRate = self.lastNearestFormat?.mSampleRate ?? 1.0
            self.detectedSampleRate = detectedSampleRate
            self.detectedBitDepth = detectedBitDepth
            
            var statusItemTitle = "C:\(self.kHzString(currentSampleRate))/\(currentBitDepth) | D:\(self.kHzString(detectedSampleRate))"
            if self.enableBitDepthDetection {
                statusItemTitle += "/\(detectedBitDepth)"
            }
            AppDelegate.instance.statusItemTitle = statusItemTitle
        }
    }
    
    func kHzString(_ frequency: Float64) -> String {
        // A small frequency value indicate its unset, return zero
        if frequency < 1000 {
            return "0"
        }
        let readableFrequency = frequency / 1000
        if floor(readableFrequency) == readableFrequency {
            // The frequency is an integer, so format without a decimal point
            return String(format: "%.0f", readableFrequency)
        } else {
            // The value has a decimal part, so format with one decimal place
            return  String(format: "%.1f", readableFrequency)
        }
    }
    
    func setCurrentToDetected() {
        let defaultDevice = selectedOutputDevice ?? defaultOutputDevice
        if let targetFormat = lastNearestFormat {
            setFormats(device: defaultDevice, format: targetFormat)
            updateStatusItemTitleText()
        }
    }
    
    func manualSetFormat(_ format: AudioStreamBasicDescription) {
        if let device = selectedOutputDevice ?? defaultOutputDevice {
            if format != device.streams(scope: .output)?.first?.physicalFormat {
                device.streams(scope: .output)?.first?.physicalFormat = format
                currentSampleRate = format.mSampleRate
                currentBitDepth = format.mBitsPerChannel
                currentFormatFlags = format.mFormatFlags
                updateStatusItemTitleText()
                refreshSampeRatesAndBitDepths(device)
            }
        }
    }
    
    func refreshSampeRatesAndBitDepths(_ device: AudioDevice) {
        guard let outputStream = device.streams(scope: .output)?.first else { return }
        
        var bitDepthFormatsForSampleRate: [AudioStreamBasicDescription] = []
        var sampleRateFormatsForBitDepth: [AudioStreamBasicDescription] = []
        
        if let availableFormats = outputStream.availablePhysicalFormats {
            for formatRange in availableFormats {
                if formatRange.mFormat.mFormatFlags == currentFormatFlags {
                    if formatRange.mFormat.mSampleRate == currentSampleRate {
                        bitDepthFormatsForSampleRate.append(formatRange.mFormat)
                    }
                    if formatRange.mFormat.mBitsPerChannel == currentBitDepth {
                        sampleRateFormatsForBitDepth.append(formatRange.mFormat)
                    }
                }
            }
        }
        
        DispatchQueue.main.async {
            self.bitDepthsForCurrentSampleRate = bitDepthFormatsForSampleRate
            self.sampleRatesForCurrentBitDepth = sampleRateFormatsForBitDepth
            NotificationCenter.default.post(name: .refreshedSampleRatesAndBitDepths, object: self)
            AppDelegate.instance.updateClients()
        }
    }
}
    
extension Notification.Name {
    static let refreshedSampleRatesAndBitDepths = Notification.Name("refreshedSampleRatesAndBitDepths")
}

