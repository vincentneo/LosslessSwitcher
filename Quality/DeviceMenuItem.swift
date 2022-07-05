//
//  DeviceMenuItem.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 26/6/22.
//

import Cocoa
import SimplyCoreAudio

class DeviceMenuItem: NSMenuItem {
    var device: AudioDevice?
    
    init(title string: String, action selector: Selector?, keyEquivalent charCode: String, device: AudioDevice? = nil) {
        self.device = device
        super.init(title: string, action: selector, keyEquivalent: charCode)
    }
    
    required init(coder: NSCoder) {
        super.init(coder: coder)
    }
}
