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
    // One instance for the whole app: AppDelegate reads its OutputDevices too.
    static let shared = MenuBarController()

    @ObservationIgnored
    var outputDevices: OutputDevices!
    
    @ObservationIgnored
    private var mrController: MediaRemoteController!

    @ObservationIgnored
    var bitPerfectCheck: BitPerfectCheck!

    @ObservationIgnored
    private var selectedDeviceCancellable: AnyCancellable?
    
    // Owned here, next to the only OutputDevices, so there is exactly one switcher.
    @ObservationIgnored
    private var trackBoundarySwitcher: TrackBoundarySwitcher!
    
    private init() {
        let outputDevices = OutputDevices()
        self.outputDevices = outputDevices
        self.mrController = MediaRemoteController(outputDevices: outputDevices)
        self.trackBoundarySwitcher = TrackBoundarySwitcher(outputDevices: outputDevices)
        self.bitPerfectCheck = BitPerfectCheck(outputDevice: { [weak outputDevices] in
            (outputDevices?.selectedOutputDevice ?? outputDevices?.defaultOutputDevice)?.id
        })
        self.selectedDeviceCancellable = outputDevices.$selectedOutputDevice.dropFirst().sink { [weak self] _ in
            self?.bitPerfectCheck.refreshAfterDeviceChange()
        }
    }
}
