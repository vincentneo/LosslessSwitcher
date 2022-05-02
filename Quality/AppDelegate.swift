//
//  AppDelegate.swift
//  Quality
//
//  Created by Vincent Neo on 21/4/22.
//

import Cocoa
import SwiftUI
import PrivateMediaRemote

class AppDelegate: NSObject, NSApplicationDelegate {
    
    // https://stackoverflow.com/a/66160164
    static private(set) var instance: AppDelegate! = nil
    private var outputDevices: OutputDevices!
    private let defaults = Defaults.shared
    private var mrController: MediaRemoteController!
    
    var statusItem: NSStatusItem?
    
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
        
        checkPermissions()
        
        let menu = NSMenu()

        let sampleRateView = ContentView().environmentObject(outputDevices)
        let view = NSHostingView(rootView: sampleRateView)
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let sampleRateItem = NSMenuItem()
        sampleRateItem.view = view
        menu.addItem(sampleRateItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let showSampleRateItem = NSMenuItem(title: defaults.statusBarItemTitle, action: #selector(toggleSampleRate(item:)), keyEquivalent: "")
        menu.addItem(showSampleRateItem)
        
        
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
    
}
