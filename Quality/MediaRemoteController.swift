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
            guard let outputDevices else { return }
            outputDevices.trackDidChange(trackInfo)
        }
        
        controller.onPlaybackTimeUpdate = { [weak outputDevices] elapsedTime in
            outputDevices?.playbackTimeDidChange(elapsedTime: elapsedTime)
        }
        
    }
    
    deinit {
        controller.stopListening()
    }
    
}
