//
//  Defaults.swift
//  Quality
//
//  Created by Vincent Neo on 23/4/22.
//

import Foundation

class Defaults: ObservableObject {
    static let shared = Defaults()
    private let kUserPreferIconStatusBarItem = "com.vincent-neo.LosslessSwitcher-Key-UserPreferIconStatusBarItem"
    private let kSelectedDeviceUID = "com.vincent-neo.LosslessSwitcher-Key-SelectedDeviceUID"
    private let kUserPreferBitDepthDetection = "com.vincent-neo.LosslessSwitcher-Key-BitDepthDetection"
    private let kShellScriptPath = "KeyShellScriptPath"
    private let kUserPreferSampleRateMultiples = "PreferSampleRateMultiples"
    private let kUserPreferLocalFileDetection = "PreferLocalFileDetection"
    private let kUserPreferPauseWhileSwitching = "PreferPauseWhileSwitching"
    private let kSwitchGap = "SwitchGap"
    private let kUserPreferRendererEngine = "PreferRendererEngine"
    static let kRendererReleaseWhenIdle = "RendererReleaseWhenIdle"
    
    private init() {
        UserDefaults.standard.register(defaults: [
            kUserPreferIconStatusBarItem : true,
            kUserPreferBitDepthDetection : false,
            kUserPreferSampleRateMultiples : false,
            kUserPreferLocalFileDetection : false,
            kUserPreferPauseWhileSwitching : false,
            kUserPreferRendererEngine : false,
            Self.kRendererReleaseWhenIdle : true
        ])
        
        self.shellScriptPath = UserDefaults.standard.string(forKey: kShellScriptPath)
        self.userPreferIconStatusBarItem = UserDefaults.standard.bool(forKey: kUserPreferIconStatusBarItem)
        self.userPreferBitDepthDetection = UserDefaults.standard.bool(forKey: kUserPreferBitDepthDetection)
        self.userPreferSampleRateMultiples = UserDefaults.standard.bool(forKey: kUserPreferSampleRateMultiples)
        self.userPreferLocalFileDetection = UserDefaults.standard.bool(forKey: kUserPreferLocalFileDetection)
        self.userPreferPauseWhileSwitching = UserDefaults.standard.bool(forKey: kUserPreferPauseWhileSwitching)
        self.switchGap = SwitchGap(rawValue: UserDefaults.standard.string(forKey: kSwitchGap) ?? "") ?? .normal
        self.userPreferRendererEngine = UserDefaults.standard.bool(forKey: kUserPreferRendererEngine)
        self.rendererReleaseWhenIdle = UserDefaults.standard.bool(forKey: Self.kRendererReleaseWhenIdle)
    }

    /// Renderer Engine: give the DAC and the default output back while Music is idle (engine reads
    /// the UserDefaults key; the delay is RendererIdleSeconds, default 60).
    @Published var rendererReleaseWhenIdle: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: Self.kRendererReleaseWhenIdle)
        }
    }

    /// Experimental: RendererEngine owns rate switching and plays Music's audio through a process tap.
    @Published var userPreferRendererEngine: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferRendererEngine)
        }
    }

    @Published var switchGap: SwitchGap {
        willSet {
            UserDefaults.standard.set(newValue.rawValue, forKey: kSwitchGap)
        }
    }
    
    @Published var userPreferPauseWhileSwitching: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferPauseWhileSwitching)
        }
    }
    
    @Published var userPreferLocalFileDetection: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferLocalFileDetection)
        }
    }
    
    @Published var userPreferSampleRateMultiples: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferSampleRateMultiples)
        }
    }
    
    @Published var userPreferIconStatusBarItem: Bool {
        willSet {
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
    
    @Published var shellScriptPath: String? {
        willSet {
            UserDefaults.standard.setValue(newValue, forKey: kShellScriptPath)
        }
    }
    
    @Published var userPreferBitDepthDetection: Bool
    
    
    @MainActor func setPreferBitDepthDetection(newValue: Bool) {
        UserDefaults.standard.set(newValue, forKey: kUserPreferBitDepthDetection)
        self.userPreferBitDepthDetection = newValue
    }
    
    @MainActor func setShellScriptPath(newValue: String?) {
        self.shellScriptPath = newValue
    }
    
    @MainActor func setPreferSampleRateMultiple(newValue: Bool) {
        self.userPreferSampleRateMultiples = newValue
    }

    var statusBarItemTitle: String {
        let title = self.userPreferIconStatusBarItem ? "Show Sample Rate" : "Show Icon"
        return title
    }
}
