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

    private var processQueue = DispatchQueue(label: "processQueue", qos: .userInitiated)

    private var previousSampleRate: Float64?
    private var previousBitDepth: Int?
    var trackAndSample = [MediaTrack : Float64]()
    var trackAndBitDepth = [MediaTrack : Int]()
    var previousTrack: MediaTrack?
    var currentTrack: MediaTrack?

    var timerCalls = 0

    // MARK: Live detection state (only touched on processQueue)

    private let logStream = LogStreamMonitor()
    /// How long after a track starts (or playback resumes) a live decoder log is trusted to belong to it.
    private static let liveWindow: TimeInterval = 8
    private var liveWindowEnd = Date.distantPast
    private var lastTrackChange = Date.distantPast
    /// A decoder format seen outside the live window: most likely Music pre-buffering the
    /// *next* track for gapless playback. Applied when that track actually starts.
    private var pendingStat: CMPlayerStats?
    private var appliedForCurrentTrack = false
    /// When a live format was last applied; Music often logs the decoder just *before*
    /// MediaRemote announces the new track.
    private var lastLiveApply = Date.distantPast
    private var wasPlaying = false

    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        self.selectedOutputDevice = self.savedSelectedDevice(in: self.outputDevices)
        self.getDeviceSampleRate()

        changesCancellable =
            NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { _ in
                self.outputDevices = self.coreAudio.allOutputDevices
                // Re-attach to the saved device if it was unplugged and came back.
                let saved = self.savedSelectedDevice(in: self.outputDevices)
                if saved?.uid != self.selectedOutputDevice?.uid {
                    self.selectedOutputDevice = saved
                }
            })

        defaultChangesCancellable =
            NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged).sink(receiveValue: { _ in
                self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
                self.getDeviceSampleRate()
            })

        outputSelectionCancellable = $selectedOutputDevice.dropFirst().sink(receiveValue: { _ in
            DispatchQueue.main.async { self.getDeviceSampleRate() }
        })

        enableBitDepthDetectionCancellable = Defaults.shared.$userPreferBitDepthDetection.sink(receiveValue: { newValue in
            self.enableBitDepthDetection = newValue
        })

        logStream.onFormat = { [weak self] stat in
            guard let self else { return }
            self.processQueue.async { self.handleLiveStat(stat) }
        }
        logStream.start()
    }

    deinit {
        logStream.stop()
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        timerCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
    }

    private func savedSelectedDevice(in devices: [AudioDevice]) -> AudioDevice? {
        guard let uid = Defaults.shared.selectedDeviceUID else { return nil }
        return devices.first(where: { $0.uid == uid })
    }

    /// Selects a specific output device, or `nil` to follow the system default.
    func select(device: AudioDevice?) {
        Defaults.shared.selectedDeviceUID = device?.uid
        selectedOutputDevice = device
    }

    private var targetDevice: AudioDevice? {
        selectedOutputDevice ?? defaultOutputDevice
    }

    // MARK: - Track changes

    func trackDidChange(_ newTrack: TrackInfo) {
        processQueue.async { [weak self] in
            self?.handleTrackInfo(newTrack)
        }
    }

    private func handleTrackInfo(_ info: TrackInfo) {
        let track = MediaTrack(trackInfo: info)
        let isPlaying = info.payload.isPlaying ?? true
        let resumed = isPlaying && !wasPlaying
        wasPlaying = isPlaying

        previousTrack = currentTrack
        currentTrack = track
        let changed = previousTrack != currentTrack

        // MediaRemote also fires for pause, seek, elapsed-time and artwork updates of the
        // same track. Re-reading logs on those used to switch the device mid-song
        // (e.g. picking up the pre-buffered next track's format), so ignore them.
        guard changed || resumed else { return }

        guard logStream.isActive else {
            // Fallback: the original polling detection.
            if changed {
                DispatchQueue.main.async { self.renewTimer() }
            }
            switchLatestSampleRate()
            return
        }

        let now = Date()
        liveWindowEnd = now.addingTimeInterval(Self.liveWindow)

        guard changed else { return }

        // A format applied in the last moment already belongs to this track.
        appliedForCurrentTrack = now.timeIntervalSince(lastLiveApply) < 3
        if let pending = pendingStat, pending.date > lastTrackChange {
            print("[live] applying pre-buffered format for new track \(pending)")
            applyStat(pending)
            appliedForCurrentTrack = true
        }
        pendingStat = nil
        lastTrackChange = now

        // Safety net in case the live stream missed the decoder line.
        processQueue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.currentTrack == track, !self.appliedForCurrentTrack else { return }
            print("[live] no live format yet, scanning log store")
            if let stat = self.getAllStats().first {
                self.applyStat(stat)
                self.appliedForCurrentTrack = true
            }
        }
    }

    private func handleLiveStat(_ stat: CMPlayerStats) {
        if Date() <= liveWindowEnd {
            applyStat(stat)
            appliedForCurrentTrack = true
            lastLiveApply = Date()
        }
        else if stat.sampleRate != previousSampleRate || (enableBitDepthDetection && stat.bitDepth != previousBitDepth) {
            print("[live] format outside track window, holding until next track \(stat)")
            pendingStat = stat
        }
    }

    // MARK: - Legacy polling detection (used when `log stream` is unavailable)

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
        guard let sampleRate = targetDevice?.nominalSampleRate else { return }
        self.updateSampleRate(sampleRate, bitDepth: nil)
    }

    func getAllStats() -> [CMPlayerStats] {
        var allStats = [CMPlayerStats]()

        do {
            let coreAudioLogs = try Console.getRecentEntries(type: .coreAudio)
            allStats.append(contentsOf: CMPlayerParser.parseCoreAudioConsoleLogs(coreAudioLogs))
            print("[getAllStats] \(allStats)")
        }
        catch {
            print("[getAllStats, error] \(error)")
        }

        return allStats
    }

    func switchLatestSampleRate(recursion: Bool = false) {
        let allStats = self.getAllStats()

        if let first = allStats.first {
            if self.currentTrack == self.previousTrack, let prevSampleRate = currentSampleRate, prevSampleRate > first.sampleRate {
                print("same track, prev sample rate is higher")
                return
            }

            if first.sampleRate == 48000 && !recursion {
                processQueue.asyncAfter(deadline: .now() + 1) {
                    self.switchLatestSampleRate(recursion: true)
                }
            }

            applyStat(first)
        }
        else if !recursion {
            processQueue.asyncAfter(deadline: .now() + 1) {
                self.switchLatestSampleRate(recursion: true)
            }
        }
    }

    // MARK: - Applying a format

    private func applyStat(_ stat: CMPlayerStats) {
        guard let device = targetDevice,
              let supported = device.nominalSampleRates,
              let formats = getFormats(device: device),
              !formats.isEmpty
        else { return }

        let sampleRate = Float64(stat.sampleRate)
        let bitDepth = Int32(stat.bitDepth)

        // https://stackoverflow.com/a/65060134
        var nearest = supported.min(by: {
            abs($0 - sampleRate) < abs($1 - sampleRate)
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

        // Pick the closest bit depth among formats that actually exist at the chosen rate.
        let atRate = formats.filter({ $0.mSampleRate == nearest })
        let suitableFormat = atRate.min(by: {
            abs(Int32($0.mBitsPerChannel) - bitDepth) < abs(Int32($1.mBitsPerChannel) - bitDepth)
        })

        print("NEAREST FORMAT \(String(describing: suitableFormat))")

        guard let suitableFormat else { return }

        if enableBitDepthDetection {
            self.setFormats(device: device, format: suitableFormat)
        }
        else if suitableFormat.mSampleRate != device.nominalSampleRate {
            device.setNominalSampleRate(suitableFormat.mSampleRate)
        }
        self.updateSampleRate(suitableFormat.mSampleRate, bitDepth: Int(suitableFormat.mBitsPerChannel))
        if let currentTrack = currentTrack {
            self.trackAndSample[currentTrack] = suitableFormat.mSampleRate
            self.trackAndBitDepth[currentTrack] = Int(suitableFormat.mBitsPerChannel)
        }
    }

    func getFormats(device: AudioDevice) -> [AudioStreamBasicDescription]? {
        let streams = device.streams(scope: .output)
        return streams?.first?.availablePhysicalFormats?.compactMap({$0.mFormat})
    }

    func setFormats(device: AudioDevice?, format: AudioStreamBasicDescription?) {
        guard let device, let format else { return }
        let streams = device.streams(scope: .output)
        if streams?.first?.physicalFormat != format {
            streams?.first?.physicalFormat = format
        }
    }

    func updateSampleRate(_ sampleRate: Float64, bitDepth: Int?) {
        let changed = sampleRate != previousSampleRate || bitDepth != previousBitDepth
        self.previousSampleRate = sampleRate
        self.previousBitDepth = bitDepth
        DispatchQueue.main.async { [self] in
            self.currentSampleRate = sampleRate / 1000
            self.currentBitDepth = bitDepth
        }
        // Only notify the user's script on real changes; it used to fire on every poll.
        if changed {
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
}
