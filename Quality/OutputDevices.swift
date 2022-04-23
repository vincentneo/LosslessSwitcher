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
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]()
    @Published var currentSampleRate: Float64?
    
    private let coreAudio = SimplyCoreAudio()
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var timerCancellable: AnyCancellable?
    private var consoleQueue = DispatchQueue(label: "consoleQueue", qos: .userInteractive)
    
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
        
        timerCancellable = timer.sink(receiveValue: { _ in
            self.consoleQueue.async {
                self.switchLatestSampleRate()
            }
        })
    }
    
    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        timerCancellable?.cancel()
        timer.upstream.connect().cancel()
    }
    
    func getDeviceSampleRate() {
        let defaultDevice = self.defaultOutputDevice
        guard let sampleRate = defaultDevice?.nominalSampleRate else { return }
        self.updateSampleRate(sampleRate)
    }
    
    func switchLatestSampleRate() {
        do {
            let musicLog = try Console.getRecentEntries()
            let cmStats = CMPlayerParser.parseMusicConsoleLogs(musicLog)
            
            let defaultDevice = self.defaultOutputDevice
            if let first = cmStats.first, let supported = defaultDevice?.nominalSampleRates {
                let sampleRate = Float64(first.sampleRate)
                // https://stackoverflow.com/a/65060134
                let nearest = supported.enumerated().min(by: {
                    abs($0.element - sampleRate) < abs($1.element - sampleRate)
                })
                if let nearest = nearest {
                    let nearestSampleRate = nearest.element
                    if nearestSampleRate != defaultDevice?.nominalSampleRate {
                        defaultDevice?.setNominalSampleRate(nearestSampleRate)
                        self.updateSampleRate(nearestSampleRate)
                    }
                }
            }
        }
        catch {
            print(error)
        }
    }
    
    func updateSampleRate(_ sampleRate: Float64) {
        DispatchQueue.main.async {
            let readableSampleRate = sampleRate / 1000
            self.currentSampleRate = readableSampleRate
            
            let statusBarItem = AppDelegate.instance.statusItem
            statusBarItem?.button?.title = String(format: "%.1f kHz", readableSampleRate)
        }
    }
}
