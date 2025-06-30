//
//  AudioStreamBasicDescription+Equatable.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 2/1/23.
//

import CoreAudioTypes

extension AudioStreamBasicDescription {
    public static func isLosslessEqual(lhs: AudioStreamBasicDescription, rhs: AudioStreamBasicDescription) -> Bool {
        return lhs.mSampleRate == rhs.mSampleRate && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
}
