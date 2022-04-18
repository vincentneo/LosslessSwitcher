//
//  AudioDeviceFinder.swift
//  Quality
//
//  Created by Vincent Neo on 18/4/22.
//
// https://stackoverflow.com/a/58618034

import Cocoa
import CoreAudio

class AudioDeviceFinder {
    static func findDevices() {
        var propsize:UInt32 = 0

        var address:AudioObjectPropertyAddress = AudioObjectPropertyAddress(
mSelector:AudioObjectPropertySelector(kAudioHardwarePropertyDevices),
            mScope:AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement:AudioObjectPropertyElement(kAudioObjectPropertyElementMaster))

        var result:OSStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<AudioObjectPropertyAddress>.size), nil, &propsize)

        if (result != 0) {
            print("Error \(result) from AudioObjectGetPropertyDataSize")
            return
        }

        let numDevices = Int(propsize / UInt32(MemoryLayout<AudioDeviceID>.size))

        var devids = [AudioDeviceID]()
        for _ in 0..<numDevices {
            devids.append(AudioDeviceID())
        }

        result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propsize, &devids);
        if (result != 0) {
            print("Error \(result) from AudioObjectGetPropertyData")
            return
        }

        for i in 0..<numDevices {
            let audioDevice = AudioDevice(deviceID:devids[i])
            if (audioDevice.hasOutput) {
                if let name = audioDevice.name,
                    let uid = audioDevice.uid {
                    print("Found device \"\(name)\", uid=\(uid)")
                }
            }
        }
    }
}
