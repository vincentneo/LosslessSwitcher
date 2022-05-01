//
//  MediaRemoteController.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 1/5/22.
//

import Cocoa
import Combine
import PrivateMediaRemote

fileprivate let kMusicAppBundle = "com.apple.Music"

class MediaRemoteController {
    
    private var infoChangedCancellable: AnyCancellable?
    private var queueChangedCancellable: AnyCancellable?
    
    private var previousTrack: MediaTrack?
    
    init(outputDevices: OutputDevices) {
        infoChangedCancellable = NotificationCenter.default.publisher(for: NSNotification.Name.mrMediaRemoteNowPlayingInfoDidChange)
                .throttle(for: .seconds(3), scheduler: DispatchQueue.main, latest: true)
                .sink(receiveValue: { notification in
                    print("Info Changed Notification Received")
                    MRMediaRemoteGetNowPlayingInfo(.main) { info in
                        if let info = info as? [String : Any] {
                            let currentTrack = MediaTrack(mediaRemote: info)
                            if currentTrack != self.previousTrack {
                                self.send(command: MRMediaRemoteCommandPause, ifBundleMatches: kMusicAppBundle) {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                        outputDevices.switchLatestSampleRate()
                                        self.send(command: MRMediaRemoteCommandPlay, ifBundleMatches: kMusicAppBundle) {}
                                    }
                                }
                            }
                            self.previousTrack = currentTrack
                        }
                    }
                })
//        queueChangedCancellable = NotificationCenter.default.publisher(for: NSNotification.Name.mrNowPlayingPlaybackQueueChanged)
//                //.throttle(for: .seconds(3), scheduler: DispatchQueue.main, latest: false)
//                .removeDuplicates()
//                .sink(receiveValue: { notification in
//                    print("Queue Changed Notification Received")
//                })
        
        MRMediaRemoteRegisterForNowPlayingNotifications(.main)
        //NotificationCenter.default.addObserver(self, selector: #selector(x(notification:)), name: NSNotification.Name.mrMediaRemoteNowPlayingInfoDidChange, object: nil)
    }
    
    func send(command: MRMediaRemoteCommand, ifBundleMatches bundleId: String, completion: @escaping () -> ()) {
        MRMediaRemoteGetNowPlayingClient(.main) { client in
            guard let client = client else { return }
            if client.bundleIdentifier == bundleId {
                MRMediaRemoteSendCommand(command, nil)
            }
            completion()
        }
    }
}
