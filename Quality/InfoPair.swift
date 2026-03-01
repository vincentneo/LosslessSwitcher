//
//  InfoPair.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 1/3/26.
//

import Foundation

class InfoPair: CustomStringConvertible {
    var track: DatedPair<MediaTrack>?
    var format: DatedPair<AudioFormat>?
    
    init(track: DatedPair<MediaTrack>? = nil, format: DatedPair<AudioFormat>? = nil) {
        self.track = track
        self.format = format
    }
    
    var description: String {
        return "InfoPair(\(String(describing: track)), \(String(describing: format)))"
    }
}

struct DatedPair<T> {
    let date: Date
    let object: T
}
