//
//  MediaRemoteController.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 1/5/22.
//

import Cocoa
//import Combine
//import PrivateMediaRemote
import MediaRemoteAdapter

fileprivate let kMusicAppBundle = "com.apple.Music"

class MediaRemoteController {
    
    private let controller: MediaController
    
    init(outputDevices: OutputDevices) {
        
        let controller = MediaController()
        self.controller = controller
        controller.startListening()
        
        controller.onTrackInfoReceived = { [weak outputDevices] trackInfo in
            print("track \(trackInfo.payload.uniqueIdentifier) \(trackInfo.payload.title ?? "nil")")
            // Only the Music app's playback matters; other players would just trigger needless work.
            if let bundle = trackInfo.payload.bundleIdentifier, bundle != kMusicAppBundle {
                return
            }
            // No artificial delay: OutputDevices reacts to the live decoder log stream,
            // so it can switch as soon as the new track's format is known.
            outputDevices?.trackDidChange(trackInfo)
        }
        
    }
    
    deinit {
        controller.stopListening()
    }
    
}
