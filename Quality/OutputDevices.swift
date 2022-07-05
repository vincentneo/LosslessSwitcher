//
//  OutputDevices.swift
//  Quality
//
//  Created by Vincent Neo on 20/4/22.
//

import Combine
import Foundation
import SimplyCoreAudio

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
    
    func switchLatestSampleRate(recursion: Bool = false) {
        do {
            var allStats = [CMPlayerStats]()
            let musicLogs = try Console.getRecentEntries(type: .music)
            //let coreAudioLogs = try Console.getRecentEntries(type: .coreAudio)
            let coreMediaLogs = try Console.getRecentEntries(type: .coreMedia)
            allStats.append(contentsOf: CMPlayerParser.parseMusicConsoleLogs(musicLogs))
            //allStats.append(contentsOf: CMPlayerParser.parseCoreAudioConsoleLogs(coreAudioLogs))
            allStats.append(contentsOf: CMPlayerParser.parseCoreMediaConsoleLogs(coreMediaLogs))
            
            allStats.sort(by: {$0.priority > $1.priority})
            print(allStats)
            let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
            if let first = allStats.first, let supported = defaultDevice?.nominalSampleRates {
                let sampleRate = Float64(first.sampleRate)
                
                if self.currentTrack == self.previousTrack, let prevSampleRate = currentSampleRate, prevSampleRate > sampleRate {
                    print("same track, prev sample rate is higher")
                    return
                }
                
                if sampleRate == 48000 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.switchLatestSampleRate(recursion: true)
                    }
                }
                
                // https://stackoverflow.com/a/65060134
                let nearest = supported.enumerated().min(by: {
                    abs($0.element - sampleRate) < abs($1.element - sampleRate)
                })
                if let nearest = nearest {
                    let nearestSampleRate = nearest.element
                    if nearestSampleRate != previousSampleRate {
                        defaultDevice?.setNominalSampleRate(nearestSampleRate)
                        self.updateSampleRate(nearestSampleRate)
                        if let currentTrack = currentTrack {
                            self.trackAndSample[currentTrack] = nearestSampleRate
                        }
                    }
                }
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
                if let currentTrack = currentTrack, let cachedSampleRate = trackAndSample[currentTrack] {
                    print("using cached data")
                    if cachedSampleRate != previousSampleRate {
                        defaultDevice?.setNominalSampleRate(cachedSampleRate)
                        self.updateSampleRate(cachedSampleRate)
                    }
                }
            }
        }
        catch {
            print(error)
        }
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
