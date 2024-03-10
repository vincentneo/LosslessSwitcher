//
//  ScriptableApplicationCommand.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 6/12/23.
//

import Cocoa

class ScriptableApplicationCommand: NSScriptCommand {
    
    override func performDefaultImplementation() -> Any? {
        guard let delegate = AppDelegate.instance else {
            return -1000
        }
        let od = delegate.outputDevices
        guard let sampleRate = od?.currentSampleRate else {
            return -1
        }
        return Int(sampleRate * 1000)
    }
}
