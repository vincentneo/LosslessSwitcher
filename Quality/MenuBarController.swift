//
//  MenuBarController.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 18/6/25.
//

import Combine
import Observation
import SwiftUI

@Observable
class MenuBarController {
    @ObservationIgnored
    var outputDevices: OutputDevices!
    
    @ObservationIgnored
    private var mrController: MediaRemoteController!

    @ObservationIgnored
    var bitPerfectCheck: BitPerfectCheck!

    @ObservationIgnored
    private var selectedDeviceCancellable: AnyCancellable?
    
    init() {
        let outputDevices = OutputDevices()
        self.outputDevices = outputDevices
        self.mrController = MediaRemoteController(outputDevices: outputDevices)
        self.bitPerfectCheck = BitPerfectCheck(outputDevice: { [weak outputDevices] in
            (outputDevices?.selectedOutputDevice ?? outputDevices?.defaultOutputDevice)?.id
        })
        self.selectedDeviceCancellable = outputDevices.$selectedOutputDevice.dropFirst().sink { [weak self] _ in
            self?.bitPerfectCheck.refreshAfterDeviceChange()
        }
    }
}
