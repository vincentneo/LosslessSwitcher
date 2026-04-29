//
//  AppDelegate.swift
//  Quality
//
//  Created by Vincent Neo on 21/4/22.
//

import Cocoa
import Combine
import SwiftUI
import SimplyCoreAudio
import PrivateMediaRemote

class AppDelegate: NSObject, NSApplicationDelegate {
    
    static private(set) var instance: AppDelegate! = nil
    var outputDevices: OutputDevices!
    private let defaults = Defaults.shared
    private var mrController: MediaRemoteController?
    private var devicesMenu: NSMenu!
    var menuBarController = MenuBarController()
    
    var statusItem: NSStatusItem?
    var cancellable: AnyCancellable?
    
    var currentScriptSelectionMenuItem: NSMenuItem?

    private var _statusItemTitle = "Loading..."
    var statusItemTitle: String {
        get {
            return _statusItemTitle
        }
        set {
            _statusItemTitle = newValue
            statusItemDisplay()
        }
    }
    
    func checkPermissions() {
        do {
            if try !User.current.isAdmin() {
                let alert = NSAlert()
                alert.messageText = "Requires Privileges"
                alert.informativeText = "LosslessSwitcher requires Administrator privileges in order to detect each song's lossless sample rate in the Music app."
                alert.alertStyle = .critical
                alert.runModal()
                NSApp.terminate(self)
            }
        }
        catch {
            let alert = NSAlert()
            alert.messageText = "Requires Privileges"
            alert.informativeText = "LosslessSwitcher could not check if your account has Administrator privileges. If your account lacks Administrator privileges, sample rate detection will not work."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.instance = self
        outputDevices = OutputDevices()
        mrController = MediaRemoteController(outputDevices: outputDevices)
        menuBarController.setup(with: outputDevices)
        
        checkPermissions()
    }
    
    func handleDevicesMenu() {
        self.devicesMenu.removeAllItems()
        let autoItem = DeviceMenuItem(title: "Default Device", action: #selector(deviceSelection(_:)), keyEquivalent: "", device: nil)
        self.devicesMenu.addItem(autoItem)
        autoItem.tag = -1
        let selectedUID = Defaults.shared.selectedDeviceUID
        if selectedUID == nil || (selectedUID != nil && !self.doesDeviceUID(selectedUID, existsIn: outputDevices.outputDevices)) {
            autoItem.state = .on
        }
        outputDevices.selectedOutputDevice = nil
        
        var idx = 0
        for device in outputDevices.outputDevices {

            let uid = device.uid
            let name = device.name
            let item = DeviceMenuItem(title: name, action: #selector(deviceSelection(_:)), keyEquivalent: "", device: device)
            item.tag = idx
            if let uid, uid == Defaults.shared.selectedDeviceUID {
                item.state = .on
                outputDevices.selectedOutputDevice = device
            }
            else {
                item.state = .off
            }
            idx += 1
            self.devicesMenu.addItem(item)
        }
    }
    
    private func doesDeviceUID(_ uid: String?, existsIn outputDevices: [AudioDevice]) -> Bool {
        return !outputDevices.filter({$0.uid == uid}).isEmpty
    }
    
    @objc func deviceSelection(_ sender: DeviceMenuItem) {
        self.devicesMenu.items.forEach({$0.state = .off})
        sender.state = .on
        outputDevices.selectedOutputDevice = sender.device
        Defaults.shared.selectedDeviceUID = sender.device?.uid
    }

    func statusItemDisplay() {
        if defaults.userPreferIconStatusBarItem {
            self.statusItem?.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "")
            self.statusItem?.button?.title = ""
        }
        else {
            self.statusItem?.button?.image = nil
            self.statusItem?.button?.title = statusItemTitle
        }
    }
    
    @objc func toggleSampleRate(item: NSMenuItem) {
        defaults.userPreferIconStatusBarItem = !defaults.userPreferIconStatusBarItem
        self.statusItemDisplay()
        item.title = defaults.statusBarItemTitle
    }
    
    @objc func toggleBitDepthDetection(item: NSMenuItem) {
        Task {
            await defaults.setPreferBitDepthDetection(newValue: !defaults.userPreferBitDepthDetection)
            item.state = defaults.userPreferBitDepthDetection ? .on : .off
        }
    }
}
