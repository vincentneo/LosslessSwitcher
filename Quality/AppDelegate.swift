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
    
    // https://stackoverflow.com/a/66160164
    static private(set) var instance: AppDelegate! = nil
    private var outputDevices: OutputDevices!
    private let defaults = Defaults.shared
    private var mrController: MediaRemoteController!
    private var networkServer: NetworkServer!
    private var devicesMenu: NSMenu!
    private var rateMenu: NSMenu!
    private var bitDepthMenu: NSMenu!
    
    var statusItem: NSStatusItem?
    var cancellable: AnyCancellable?
    private var refreshedSampleRatesAndBitDepths: AnyCancellable?

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
        networkServer = NetworkServer(outputDevices)
        
        checkPermissions()
        
        let menu = NSMenu()

        let sampleRateView = ContentView().environmentObject(outputDevices)
        let view = NSHostingView(rootView: sampleRateView)
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let sampleRateItem = NSMenuItem()
        sampleRateItem.view = view
        menu.addItem(sampleRateItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let setSampleRateItem = NSMenuItem(title: "Set Current to Detected", action: #selector(setCurrentToDetected), keyEquivalent: "")
        menu.addItem(setSampleRateItem)
        
        let enableAutoSwitchItem = NSMenuItem(title: "Auto Switching", action: #selector(toggleAutoSwitching(item:)), keyEquivalent: "")
        menu.addItem(enableAutoSwitchItem)
        enableAutoSwitchItem.state = defaults.userPreferAutoSwitch ? .on : .off
     
        let enableBitDepthItem = NSMenuItem(title: "Bit Depth Detection", action: #selector(toggleBitDepthDetection(item:)), keyEquivalent: "")
        menu.addItem(enableBitDepthItem)
        enableBitDepthItem.state = defaults.userPreferBitDepthDetection ? .on : .off
        
        let setRateItem = NSMenuItem(title: "Set Rate", action: nil, keyEquivalent: "")
        self.rateMenu = NSMenu()
        setRateItem.submenu = self.rateMenu
        menu.addItem(setRateItem)
        self.handleRateMenu()
        
        let setBitDepthItem = NSMenuItem(title: "Set Bit Depth", action: nil, keyEquivalent: "")
        self.bitDepthMenu = NSMenu()
        setBitDepthItem.submenu = self.bitDepthMenu
        menu.addItem(setBitDepthItem)
        self.handleBitDepthMenu()
        
        let selectedDeviceItem = NSMenuItem(title: "Selected Device", action: nil, keyEquivalent: "")
        self.devicesMenu = NSMenu()
        selectedDeviceItem.submenu = self.devicesMenu
        menu.addItem(selectedDeviceItem)
        self.handleDevicesMenu()
        
        let showSampleRateItem = NSMenuItem(title: defaults.statusBarItemTitle, action: #selector(toggleSampleRate(item:)), keyEquivalent: "")
        menu.addItem(showSampleRateItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let aboutItem = NSMenuItem(title: "About", action: nil, keyEquivalent: "")
        let versionItem = NSMenuItem(title: "Version - \(currentVersion)", action: nil, keyEquivalent: "")
        let buildItem = NSMenuItem(title: "Build - \(currentBuild)", action: nil, keyEquivalent: "")
        
        aboutItem.submenu = NSMenu()
        aboutItem.submenu?.addItem(versionItem)
        aboutItem.submenu?.addItem(buildItem)
        menu.addItem(aboutItem)
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApp.terminate(_:)), keyEquivalent: "")
        menu.addItem(quitItem)

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem?.menu = menu
        self.statusItem?.button?.title = "Loading..."
        self.statusItemDisplay()
        
        cancellable = NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { _ in
            self.handleDevicesMenu()
        })
       
        refreshedSampleRatesAndBitDepths = NotificationCenter.default.publisher(for: .refreshedSampleRatesAndBitDepths).sink(receiveValue: { _ in
            self.handleRateMenu()
            self.handleBitDepthMenu()
        })
        
        networkServer.startListener()
    }
    
    func handleRateMenu() {
        self.rateMenu.removeAllItems()
        var idx = 0
        for rate in outputDevices.sampleRatesForCurrentBitDepth {
            //let rateTitle = "\(rate.mSampleRate / 1000) kHz - \(rate.mBitsPerChannel) bit"
            let rateTitle = "\(rate.mSampleRate / 1000) kHz"
            let rateItem = NSMenuItem(title: rateTitle, action: #selector(sampleRateSelected(_:)), keyEquivalent: "")
            rateItem.tag = idx
            rateItem.target = self
            self.rateMenu.addItem(rateItem)
            idx += 1
        }
    }
    
    func handleBitDepthMenu() {
        self.bitDepthMenu.removeAllItems()
        var idx = 0
        for format in outputDevices.bitDepthsForCurrentSampleRate {
            //let formatTitle = "\(format.mBitsPerChannel) bit - \(format.mSampleRate / 1000) kHz"
            let formatTitle = "\(format.mBitsPerChannel) bit"
            let formatItem = NSMenuItem(title: formatTitle, action: #selector(formatSelected(_:)), keyEquivalent: "")
            formatItem.tag = idx
            formatItem.target = self
            self.bitDepthMenu.addItem(formatItem)
            idx += 1
        }
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
    
    @objc func toggleAutoSwitching(item: NSMenuItem) {
        Task {
            await defaults.setPreferAutoSwitch(newValue: !defaults.userPreferAutoSwitch)
            item.state = defaults.userPreferAutoSwitch ? .on : .off
        }
    }
    
    @objc func setCurrentToDetected() {
        outputDevices.setCurrentToDetected()
    }
    
    
    @objc func sampleRateSelected(_ sender: NSMenuItem) {
        let selectedIndex = sender.tag
        let selectedRate = outputDevices.sampleRatesForCurrentBitDepth[selectedIndex]
        outputDevices.manualSetFormat(selectedRate)
    }
    
    @objc func formatSelected(_ sender: NSMenuItem) {
        let selectedIndex = sender.tag
        let selectedFormat = outputDevices.bitDepthsForCurrentSampleRate[selectedIndex]
        outputDevices.manualSetFormat(selectedFormat)
    }
    
    func updateAutoSwitchingMenuItemState() {
        if let menu = statusItem?.menu,
           let enableAutoSwitchItem = menu.item(withTitle: "Auto Switching") {
            enableAutoSwitchItem.state = outputDevices.enableAutoSwitch ? .on : .off
        }
    }
    
    func updateClients() {
        if let networkServer = self.networkServer {
            networkServer.updateClients()
        }
    }

    deinit {
        cancellable?.cancel()
        refreshedSampleRatesAndBitDepths?.cancel()
    }
    
}
