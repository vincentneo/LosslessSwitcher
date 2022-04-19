//
//  ContentView.swift
//  Quality
//
//  Created by Vincent Neo on 18/4/22.
//

import SwiftUI
import OSLog
import SimplyCoreAudio

struct ContentView: View {
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    let coreAudio = SimplyCoreAudio()
    
    var body: some View {
        Text("Hello, world!")
            .padding()
            .onAppear {
                print(coreAudio.defaultOutputDevice)
                print(coreAudio.defaultOutputDevice?.nominalSampleRates)
                //AudioDeviceFinder.findDevices()
            }
            .onReceive(timer) { input in
                DispatchQueue.main.async {
                    do {
                        let musicLog = try Console.getRecentEntries()
                        let cmStats = CMPlayerParser.parseMusicConsoleLogs(musicLog)
                        if let first = cmStats.first, let supported = coreAudio.defaultOutputDevice?.nominalSampleRates {
                            let sampleRate = Float64(first.sampleRate)
                            // https://stackoverflow.com/a/65060134
                            let nearest = supported.enumerated().min(by: {
                                abs($0.element - sampleRate) < abs($1.element - sampleRate)
                            })
                            if let nearest = nearest {
                                let nearestSampleRate = nearest.element
                                coreAudio.defaultOutputDevice?.setNominalSampleRate(nearestSampleRate)
                            }
                        }
                    }
                    catch {
                        print(error)
                    }
                }
            }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}


