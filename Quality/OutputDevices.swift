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
import OrderedCollections

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
    private var outputSelectionCancellable: AnyCancellable?
    
    private let logReader = LogReader()
    private var entryStreamReceiver: AnyCancellable?
    private var lastTrackChangeTime: Date?
    
    private var collection: OrderedDictionary<String, InfoPair> = [:]
    private var currentTrackPair: DatedPair<MediaTrack>?
    private var updateRequester = PassthroughSubject<Void, Never>()
    private var updateRequesterReceiver: AnyCancellable?
    
    private var pairHandlingQueue = DispatchQueue(label: "phq", qos: .userInteractive)
    private var processQueue = DispatchQueue(label: "processQueue", qos: .userInitiated)
    
    private var previousSampleRate: Float64?
    private var previousBitDepth: Int?
    var trackAndSample = [MediaTrack : Float64]()
    var trackAndBitDepth = [MediaTrack : Int]()
    var previousTrack: MediaTrack?
    var currentTrack: MediaTrack?
    
    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        self.getDeviceSampleRate()
        
        self.logReader.spawnProcessIfNeeded()
        
        entryStreamReceiver = logReader.entryStream
            .receive(on: pairHandlingQueue)
            .sink { [weak self] entry in
                self?.handleLogEntry(entry)
            }
        
        updateRequesterReceiver = updateRequester
            .throttle(for: 0.3, scheduler: DispatchQueue.global(), latest: true)
            .receive(on: pairHandlingQueue)
            .sink { [weak self] in
                self?.processPendingUpdates()
            }
        
        changesCancellable =
            NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { [weak self] _ in
                self?.outputDevices = self?.coreAudio.allOutputDevices ?? []
            })
        
        defaultChangesCancellable =
            NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged).sink(receiveValue: { [weak self] _ in
                self?.defaultOutputDevice = self?.coreAudio.defaultOutputDevice
                self?.getDeviceSampleRate()
            })
        
        outputSelectionCancellable = $selectedOutputDevice.sink(receiveValue: { [weak self] _ in
            self?.getDeviceSampleRate()
        })
        
        enableBitDepthDetectionCancellable = Defaults.shared.$userPreferBitDepthDetection.sink(receiveValue: { [weak self] newValue in
            self?.enableBitDepthDetection = newValue
        })
    }
    
    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
        entryStreamReceiver?.cancel()
        updateRequesterReceiver?.cancel()
        outputSelectionCancellable?.cancel()
        logReader.stopProcess()
    }
    
    private func handleLogEntry(_ entry: CMEntry) {
        let key = entry.trackName ?? UUID().uuidString
        
        // Skip duplicate entries within 1 second for unknown tracks
        if entry.trackName == nil,
           let lastKey = collection.keys.last,
           let lastDate = collection[lastKey]?.format?.date,
           abs(lastDate.timeIntervalSince(entry.date)) < 1 {
            return
        }
        
        let format = DatedPair(date: entry.date, object: AudioFormat(sampleRate: entry.sampleRate, bitDepth: entry.bitDepth))
        if let pair = collection[key] {
            pair.format = format
        }
        else {
            collection[key] = InfoPair(format: format)
        }
        
        updateRequester.send()
    }
    
    private func processPendingUpdates() {
        guard let currentTrackPair = currentTrackPair else { return }
        
        var limit = 0
        for (_, value) in collection.reversed() {
            guard limit < 5 else { break }
            defer { limit += 1 }
            
            if let track = value.track?.object, let current = currentTrack, track == current {
                if let format = value.format?.object {
                    processQueue.async { [weak self] in
                        self?.switchLatestSampleRate(format: format)
                    }
                    return
                }
            }
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
    
    func switchLatestSampleRate(format: AudioFormat) {
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        
        guard let supported = defaultDevice?.nominalSampleRates else { return }
        
        let sampleRate = Float64(format.sampleRate)
        let bitDepth = Int32(format.bitDepth ?? 32)
        
        guard let formats = getFormats(device: defaultDevice!) else { return }
        
        // Find nearest supported sample rate
        var nearest = supported.min(by: {
            abs($0 - sampleRate) < abs($1 - sampleRate)
        })
        
        // Find nearest bit depth
        let nearestBitDepth = formats.min(by: {
            abs(Int32($0.mBitsPerChannel) - bitDepth) < abs(Int32($1.mBitsPerChannel) - bitDepth)
        })
        
        // Handle sample rate multiples preference
        if Defaults.shared.userPreferSampleRateMultiples,
           let nearestSampleRate = nearest,
           nearestSampleRate != sampleRate,
           supported.contains(sampleRate / 2) {
            nearest = sampleRate / 2
        }
        
        let nearestFormat = formats.filter({
            $0.mSampleRate == nearest && $0.mBitsPerChannel == nearestBitDepth?.mBitsPerChannel
        })
        
        print("NEAREST FORMAT \(nearestFormat)")
        
        if let suitableFormat = nearestFormat.first {
            if enableBitDepthDetection {
                setFormats(device: defaultDevice, format: suitableFormat)
            }
            else if suitableFormat.mSampleRate != previousSampleRate {
                defaultDevice?.setNominalSampleRate(suitableFormat.mSampleRate)
            }
            updateSampleRate(suitableFormat.mSampleRate, bitDepth: Int(suitableFormat.mBitsPerChannel))
            if let currentTrack = currentTrack {
                trackAndSample[currentTrack] = suitableFormat.mSampleRate
                trackAndBitDepth[currentTrack] = Int(suitableFormat.mBitsPerChannel)
            }
        }
    }
    
    func getFormats(device: AudioDevice) -> [AudioStreamBasicDescription]? {
        let streams = device.streams(scope: .output)
        return streams?.first?.availablePhysicalFormats?.compactMap({ $0.mFormat })
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let readableSampleRate = sampleRate / 1000
            self.currentSampleRate = readableSampleRate
            self.currentBitDepth = bitDepth
            
            let delegate = AppDelegate.instance
            
            if self.enableBitDepthDetection {
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
        let mt = MediaTrack(trackInfo: newTrack)
        
        guard previousTrack != mt else { return }
        self.previousTrack = self.currentTrack
        self.currentTrack = mt

        pairHandlingQueue.async { [weak self] in
            guard let self else { return }
            let now = Date.now
            let pair = DatedPair(date: now, object: mt)
            self.currentTrackPair = pair
            
            let key = mt.title ?? UUID().uuidString
            if let collectionPair = self.collection[key] {
                collectionPair.track = pair
            }
            else if let lastKey = self.collection.keys.last,
                    self.collection[lastKey]?.track == nil,
                    UUID(uuidString: lastKey) != nil {
                self.collection[lastKey]?.track = pair
            }
            else {
                self.collection[key] = .init(track: pair)
            }
            self.updateRequester.send()
        }
        
        lastTrackChangeTime = Date()
    }
}
