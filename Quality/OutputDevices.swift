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
    
    private let coreAudio = SimplyCoreAudio()
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    private var timerCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    
    private var consoleQueue = DispatchQueue(label: "consoleQueue", qos: .userInteractive)
    
    private var previousSampleRate: Float64?
    var trackAndSample = [MediaTrack : Float64]()
    var previousTrack: MediaTrack?
    var currentTrack: MediaTrack?
    
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
        
        outputSelectionCancellable = selectedOutputDevice.publisher.sink(receiveValue: { _ in
            self.getDeviceSampleRate()
        })
        
    }
    
    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        timerCancellable?.cancel()
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
    
    func getDeviceSampleRate() {
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        guard let sampleRate = defaultDevice?.nominalSampleRate else { return }
        self.updateSampleRate(sampleRate)
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
            //allStats.append(contentsOf: CMPlayerParser.parseCoreAudioConsoleLogs(coreAudioLogs))
            allStats.append(contentsOf: CMPlayerParser.parseCoreMediaConsoleLogs(coreMediaLogs))
            
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
            
            if self.currentTrack == self.previousTrack/*, let prevSampleRate = currentSampleRate, prevSampleRate > sampleRate */ {
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
                //if suitableFormat.mSampleRate != previousSampleRate {
                    self.setFormats(device: defaultDevice, format: suitableFormat)
                    self.updateSampleRate(suitableFormat.mSampleRate)
                    if let currentTrack = currentTrack {
                        self.trackAndSample[currentTrack] = suitableFormat.mSampleRate
                    }
                //}
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
        guard let device, let format else { return }
        let streams = device.streams(scope: .output)
        streams?.first?.physicalFormat = format
    }
    
    func updateSampleRate(_ sampleRate: Float64) {
        self.previousSampleRate = sampleRate
        DispatchQueue.main.async {
            let readableSampleRate = sampleRate / 1000
            self.currentSampleRate = readableSampleRate
            
            let delegate = AppDelegate.instance
            delegate?.statusItemTitle = String(format: "%.1f kHz", readableSampleRate)
        }
    }
}
