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
    
    // Owned here, next to the only OutputDevices, so there is exactly one switcher.
    @ObservationIgnored
    private var trackBoundarySwitcher: TrackBoundarySwitcher!

    @ObservationIgnored
    var bitPerfectCheck: BitPerfectCheck!

    @ObservationIgnored
    private var rendererEngine: RendererEngine!

    @ObservationIgnored
    private var virtualEngine: VirtualDeviceEngine!

    @ObservationIgnored
    private var rendererCancellable: AnyCancellable?

    @ObservationIgnored
    private var selectedDeviceCancellable: AnyCancellable?
    
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
        let engine = RendererEngine(outputDevices: outputDevices)
        let vEngine = VirtualDeviceEngine(outputDevices: outputDevices)
        self.rendererEngine = engine
        self.virtualEngine = vEngine
        // an earlier run that died can leave the virtual device as the default output
        VirtualDeviceEngine.recoverOutput()
        self.rendererCancellable = Defaults.shared.$userPreferRendererEngine
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                if on { self?.startRenderer() } else { self?.stopRendererEngines() }
            }
    }

    /// Exclusive Mode needs the virtual output device (HAL plug-in): it's what allows hog mode and
    /// integer output on the DAC. Without the plug-in nothing starts and the setting goes off (the
    /// menu only offers Exclusive Mode once the driver is installed). The process-tap engine is a
    /// developer path only (RendererForceTapEngine).
    private func startRenderer() {
        if UserDefaults.standard.bool(forKey: "RendererForceTapEngine") {
            rendererEngine.startupNote = "RendererForceTapEngine is set; using the process-tap engine"
            rendererEngine.start()
            return
        }
        if VirtualDeviceEngine.findDevice() != nil {
            virtualEngine.start()
            return
        }
        guard VirtualOutputPlugin.shared.isInstalledOnDisk else {
            print("[Exclusive Mode] the virtual output device isn't installed; Exclusive Mode stays off")
            Defaults.shared.userPreferRendererEngine = false
            return
        }
        // installed, but the HAL lists the device a moment later (login, coreaudiod restarting)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let end = Date().addingTimeInterval(10)
            while Date() < end, VirtualDeviceEngine.findDevice() == nil { Thread.sleep(forTimeInterval: 0.25) }
            let found = VirtualDeviceEngine.findDevice() != nil
            DispatchQueue.main.async {
                guard let self, Defaults.shared.userPreferRendererEngine else { return }
                if found { self.virtualEngine.start() } else {
                    print("[Exclusive Mode] the virtual output device is installed but coreaudiod doesn't list it; Exclusive Mode stays off")
                    Defaults.shared.userPreferRendererEngine = false
                }
            }
        }
    }

    private func stopRendererEngines() {
        virtualEngine.stop()
        rendererEngine.stop()
    }

    /// Install/update (true) or remove (false) the virtual output device. The engine is stopped
    /// first (it hands the DAC and the default output back) and started again afterwards.
    /// `enableAfter`: turn Exclusive Mode on when the install succeeds (the menu's "Install Exclusive
    /// Mode Driver…"). Removing the driver turns Exclusive Mode off (startRenderer finds no device).
    func changeVirtualDevice(install: Bool, enableAfter: Bool = false) {
        let wasOn = Defaults.shared.userPreferRendererEngine
        stopRendererEngines()
        let plugin = VirtualOutputPlugin.shared
        let after: (Bool) -> Void = { [weak self] ok in
            VirtualDeviceEngine.recoverOutput()
            if install, ok, enableAfter, !wasOn {
                Defaults.shared.userPreferRendererEngine = true // the sink starts it
            } else if wasOn {
                self?.startRenderer()
            }
        }
        if install { plugin.install(done: after) } else { plugin.remove(done: after) }
    }

    /// Called on quit: stops the renderer, gives the DAC back, restores the default output and
    /// Music's volume.
    func stopRenderer() {
        stopRendererEngines()
        mrController?.stop()
    }
}
