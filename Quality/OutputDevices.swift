//
//  OutputDevices.swift
//  Quality
//
//  Created by Vincent Neo on 20/4/22.
//

import Combine
import Foundation
import SimplyCoreAudio

class OutputDevices: ObservableObject {
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]()
    
    @Published var selectedDevice: PickableDevice?
    @Published var pickableDevices = [PickableDevice]()
    
    private let coreAudio = SimplyCoreAudio()
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    
    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        
        selectedDevice = self.defaultOutputDevice?.pickable(isDefault: true) ?? self.outputDevices.first?.pickable()
        self.refreshPickables()
        
        changesCancellable =
            NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { _ in
                self.outputDevices = self.coreAudio.allOutputDevices
                self.refreshPickables()
            })
        
        defaultChangesCancellable =
            NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged).sink(receiveValue: { _ in
                self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
                self.refreshPickables()
            })
    }
    
    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
    }
    
    func refreshPickables() {
        var devices = self.outputDevices.map({PickableDevice(from: $0)})
        
        if let defaultDevice = defaultOutputDevice {
            let pickableDevice = PickableDevice(from: defaultDevice, isDefault: true)
            devices.removeAll(where: {$0.id == pickableDevice.id})
            devices.insert(pickableDevice, at: 0)
        }
        pickableDevices = devices
    }
}

struct PickableDevice: Identifiable, Equatable, Hashable {
    let id: String
    let device: AudioDevice
    let name: String
    let isDefault: Bool
    
    init(from device: AudioDevice, isDefault: Bool = false) {
        self.id = device.uid ?? String(device.id)
        self.device = device
        self.name = "\(device.name) \(isDefault ? "[Default]" : "")"
        self.isDefault = isDefault
    }
}

extension AudioDevice {
    func pickable(isDefault: Bool = false) -> PickableDevice {
        return PickableDevice(from: self, isDefault: isDefault)
    }
}
