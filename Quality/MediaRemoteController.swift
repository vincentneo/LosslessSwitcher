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
    
    //private var previousTrack: MediaTrack?
    
    init(outputDevices: OutputDevices) {
        infoChangedCancellable = NotificationCenter.default.publisher(for: NSNotification.Name.mrMediaRemoteNowPlayingInfoDidChange)
                .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
                .sink(receiveValue: { notification in
                        //print(notification)
                    print("Info Changed Notification Received")
                    MRMediaRemoteGetNowPlayingInfo(.main) { info in
                        if let info = info as? [String : Any] {
                            let currentTrack = MediaTrack(mediaRemote: info)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                print("Current Track \(outputDevices.currentTrack?.title ?? "nil"), previous: \(outputDevices.previousTrack?.title ?? "nil"), isSame: \(outputDevices.previousTrack == outputDevices.currentTrack)")
                                outputDevices.previousTrack = outputDevices.currentTrack
                                outputDevices.currentTrack = currentTrack
                                if outputDevices.previousTrack != outputDevices.currentTrack {
                                    outputDevices.renewTimer()
                                }
                                outputDevices.switchLatestSampleRate()
                            }
//                            if currentTrack != self.previousTrack {
//                                self.send(command: MRMediaRemoteCommandPause, ifBundleMatches: kMusicAppBundle) {
//                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
//                                    outputDevices.switchLatestSampleRate()
//                                    //self.send(command: MRMediaRemoteCommandPlay, ifBundleMatches: kMusicAppBundle) {}
//                                }
//                                //}
//                            }
                            //self.previousTrack = currentTrack
                        }
                    }
                })
        
        MRMediaRemoteRegisterForNowPlayingNotifications(.main)
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
