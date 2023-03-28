//
//  Defaults.swift
//  Quality
//
//  Created by Vincent Neo on 23/4/22.
//

import Foundation

class Defaults {
    static let shared = Defaults()
    private let kUserPreferIconStatusBarItem = "com.vincent-neo.LosslessSwitcher-Key-UserPreferIconStatusBarItem"
    private let kSelectedDeviceUID = "com.vincent-neo.LosslessSwitcher-Key-SelectedDeviceUID"
    
    private init() {
        UserDefaults.standard.register(defaults: [
            kUserPreferIconStatusBarItem : true
        ])
    }
    
    var userPreferIconStatusBarItem: Bool {
        get {
            return UserDefaults.standard.bool(forKey: kUserPreferIconStatusBarItem)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: kUserPreferIconStatusBarItem)
        }
    }
    
    var selectedDeviceUID: String? {
        get {
            return UserDefaults.standard.string(forKey: kSelectedDeviceUID)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: kSelectedDeviceUID)
        }
    }

    var statusBarItemTitle: String {
        let title = self.userPreferIconStatusBarItem ? "Show Sample Rate" : "Show Icon"
        return title
    }
}
