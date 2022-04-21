//
//  AppDelegate.swift
//  Quality
//
//  Created by Vincent Neo on 21/4/22.
//

import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    
    var statusItem: NSStatusItem?
    var popup: NSPopover?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let suiView = ContentView()
        let view = NSHostingView(rootView: suiView)
       view.frame = NSRect(x: 0, y: 0, width: 200, height: 150)
        let menuItem = NSMenuItem()
        menuItem.view = view

        let menu = NSMenu()
        menu.addItem(menuItem)

//        popup = NSPopover()
//        popup!.contentSize = NSSize(width: 150, height: 100)
//        popup!.behavior = .transient
//        popup!.contentViewController = NSHostingController(rootView: ContentView())
//
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem?.menu = menu
        self.statusItem?.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "")
    }
    
    @objc func showPopup(sender: NSStatusBarButton?) {
        guard let popup = popup, let sender = sender else { return }
        
        if popup.isShown {
            popup.performClose(sender)
        }
        else {
            popup.show(relativeTo: sender.bounds, of: sender, preferredEdge: NSRectEdge.minY)
        }
    }
}
