//
//  MediaTrack.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 1/5/22.
//

import Foundation
import PrivateMediaRemote
import MediaRemoteAdapter

struct MediaTrack: Equatable, Hashable {
    
    let isMusicApp: Bool
    let id: String?
    
    let title: String?
    let album: String?
    let artist: String?
    let trackNumber: String?
    
    init(mediaRemote info: [String : Any]) {
        self.id = info[kMRMediaRemoteNowPlayingInfoUniqueIdentifier] as? String
        self.isMusicApp = info[kMRMediaRemoteNowPlayingInfoIsMusicApp] as? Bool ?? false
        self.title = info[kMRMediaRemoteNowPlayingInfoTitle] as? String
        self.album = info[kMRMediaRemoteNowPlayingInfoAlbum] as? String
        self.artist = info[kMRMediaRemoteNowPlayingInfoArtist] as? String
        self.trackNumber = info[kMRMediaRemoteNowPlayingInfoTrackNumber] as? String
    }
    
    init(trackInfo: TrackInfo) {
        let payload = trackInfo.payload
        self.id = payload.uniqueIdentifier
        self.isMusicApp = true
        self.title = payload.title
        self.album = payload.album
        self.artist = payload.artist
        self.trackNumber = nil
    }
}
