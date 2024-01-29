//
//  ScriptableApplicationCommand.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 6/12/23.
//

import Cocoa

class ScriptableApplicationCommandSetRate: NSScriptCommand {
    
    override func performDefaultImplementation() -> Any? {
        guard let delegate = AppDelegate.instance else {
            return -1000
        }

    //    print( "in" )
        let newrate = self.evaluatedArguments!["newrate"] as! String

        let newratenum = Float64(newrate)
        
        print( "newrate " + newrate )
        
        if ( newrate == "" || newratenum != nil ) {
            
            let od = delegate.outputDevices!
            if let outdev = od.selectedOutputDevice ?? od.defaultOutputDevice {

                print("setOutputDeviceRate -- \(newratenum)"  )
                
                let retval = outdev.setNominalSampleRate( Float64(newratenum!) )
                
                if retval != true {
                    return -2000
                }
                
                od.updateSampleRate( newratenum! )
                return newratenum

            } else {
                return -3000
            }

        } else {
            return -4000
        }

   }
    
}
