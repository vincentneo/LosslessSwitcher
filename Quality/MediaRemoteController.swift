//
//  MediaRemoteController.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 1/5/22.
//

import Cocoa
import MediaRemoteAdapter

class MediaRemoteController {
    
    private let controller: MediaController
    private var restartWorkItem: DispatchWorkItem?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastHandledPlayback: PlaybackState?
    
    private struct PlaybackState: Equatable {
        let bundleId: String?
        let trackId: String
        let isPlaying: Bool
    }
    
    init(outputDevices: OutputDevices) {
        
        // Listen to all now-playing apps so we can reset when playback leaves Music.
        let controller = MediaController()
        self.controller = controller
        
        controller.onTrackInfoReceived = { [weak self, weak outputDevices] trackInfo in
            self?.debounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak outputDevices] in
                guard let self, let outputDevices else { return }
                guard let trackInfo else {
                    outputDevices.resetToDefaultSampleRate()
                    return
                }
                
                let bundleId = trackInfo.payload.bundleIdentifier
                let state = PlaybackState(
                    bundleId: bundleId,
                    trackId: trackInfo.payload.uniqueIdentifier,
                    isPlaying: trackInfo.payload.isPlaying ?? false
                )
                guard state != self.lastHandledPlayback else { return }
                self.lastHandledPlayback = state
                
                let isMusic = bundleId == MusicApp.bundleIdentifier
                
                if !isMusic {
                    outputDevices.resetToDefaultSampleRate()
                    return
                }
                
                if !state.isPlaying {
                    outputDevices.musicPlaybackPaused()
                    return
                }
                
                outputDevices.trackDidChange(trackInfo)
            }
            self?.debounceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
        
        controller.onListenerTerminated = { [weak self] in
            self?.scheduleRestart()
        }
        
        controller.startListening()
    }
    
    deinit {
        debounceWorkItem?.cancel()
        restartWorkItem?.cancel()
        controller.onListenerTerminated = nil
        controller.stopListening()
    }
    
    private func scheduleRestart() {
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.controller.startListening()
        }
        restartWorkItem = work
        // Brief delay avoids a tight crash/restart loop if perl exits immediately.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    
}
