//
//  MenuBarController.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 18/6/25.
//

import Observation
import SwiftUI

@Observable
class MenuBarController {
    @ObservationIgnored
    var outputDevices: OutputDevices!
    
    @ObservationIgnored
    private var mrController: MediaRemoteController!
    
    init() {
        let outputDevices = OutputDevices()
        self.outputDevices = outputDevices
        self.mrController = MediaRemoteController(outputDevices: outputDevices)
    }
}
