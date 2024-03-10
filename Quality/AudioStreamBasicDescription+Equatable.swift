//
//  AudioStreamBasicDescription+Equatable.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 2/1/23.
//

import CoreAudioTypes

extension AudioStreamBasicDescription: Equatable {
    public static func == (lhs: AudioStreamBasicDescription, rhs: AudioStreamBasicDescription) -> Bool {
        return lhs.mSampleRate == rhs.mSampleRate && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
}
