//
//  AudioDevice.swift
//  Quality
//
//  Created by Vincent Neo on 18/4/22.
//
// https://stackoverflow.com/a/58618034

import Cocoa
import CoreAudio

class AudioDevice {
    var audioDeviceID: AudioDeviceID

    init(deviceID: AudioDeviceID) {
        self.audioDeviceID = deviceID
    }

    var hasOutput: Bool {
        get {
            var address:AudioObjectPropertyAddress = AudioObjectPropertyAddress(
                mSelector:AudioObjectPropertySelector(kAudioDevicePropertyStreamConfiguration),
                mScope:AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput),
                mElement:0)

            var propsize:UInt32 = UInt32(MemoryLayout<CFString?>.size);
            var result:OSStatus = AudioObjectGetPropertyDataSize(self.audioDeviceID, &address, 0, nil, &propsize);
            if (result != 0) {
                return false;
            }

            let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity:Int(propsize))
            result = AudioObjectGetPropertyData(self.audioDeviceID, &address, 0, nil, &propsize, bufferList);
            if (result != 0) {
                return false
            }

            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for bufferNum in 0..<buffers.count {
                if buffers[bufferNum].mNumberChannels > 0 {
                    return true
                }
            }

            return false
        }
    }

    var uid:String? {
        get {
            var address:AudioObjectPropertyAddress = AudioObjectPropertyAddress(
                mSelector:AudioObjectPropertySelector(kAudioDevicePropertyDeviceUID),
                mScope:AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                mElement:AudioObjectPropertyElement(kAudioObjectPropertyElementMaster))

            var name:CFString? = nil
            var propsize:UInt32 = UInt32(MemoryLayout<CFString?>.size)
            let result:OSStatus = AudioObjectGetPropertyData(self.audioDeviceID, &address, 0, nil, &propsize, &name)
            if (result != 0) {
                return nil
            }

            return name as String?
        }
    }

    var name:String? {
        get {
            var address:AudioObjectPropertyAddress = AudioObjectPropertyAddress(
                mSelector:AudioObjectPropertySelector(kAudioDevicePropertyDeviceNameCFString),
                mScope:AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                mElement:AudioObjectPropertyElement(kAudioObjectPropertyElementMaster))

            var name:CFString? = nil
            var propsize:UInt32 = UInt32(MemoryLayout<CFString?>.size)
            let result:OSStatus = AudioObjectGetPropertyData(self.audioDeviceID, &address, 0, nil, &propsize, &name)
            if (result != 0) {
                return nil
            }

            return name as String?
        }
    }
    
    var bit: CFArray? {
        get {
            var address:AudioObjectPropertyAddress = AudioObjectPropertyAddress(
                mSelector:AudioObjectPropertySelector(kAudioStreamPropertyAvailablePhysicalFormats),
                mScope:AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                mElement:AudioObjectPropertyElement(kAudioObjectPropertyElementMaster))

            //var sampleRate: Any? = nil
            var propsize:UInt32 = UInt32(MemoryLayout<AudioStreamRangedDescription?>.size)
            var s = UInt32.zero
            var size = AudioObjectGetPropertyDataSize(self.audioDeviceID, &address, 0, nil, &s)
            print(s)
            s = s * propsize
            var size2 = [AudioStreamRangedDescription]() as CFArray
            let result:OSStatus = AudioObjectGetPropertyData(self.audioDeviceID, &address, 0, nil, &s, &size2)
            print(size2)
            if (result != 0) {
                return nil
            }

            return size2//name as String?
        }
    }
}
