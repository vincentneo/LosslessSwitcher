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

        
        controller.onTrackInfoReceived = { [weak outputDevices] trackInfo in
            let observedAt = Date()
            DispatchQueue.main.async {
                guard let outputDevices else { return }
                outputDevices.trackDidChange(trackInfo, observedAt: observedAt)
            }
        }
        controller.startListening()
    }
    
    deinit {
        controller.stopListening()
    }
    
}
