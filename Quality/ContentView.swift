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
    @StateObject var outputDevices = OutputDevices()
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack {
            Picker("Picker", selection: $outputDevices.selectedDevice) {
                ForEach(outputDevices.pickableDevices, id: \.id) { item in
                    Text(item.name)
                }
            }
            .onAppear {
                print(outputDevices.pickableDevices)
            }
        }
            .onReceive(timer) { input in
                DispatchQueue.main.async {
                    self.switchLatestSampleRate()
                }
            }
    }
    
    func switchLatestSampleRate() {
        do {
            let musicLog = try Console.getRecentEntries()
            let cmStats = CMPlayerParser.parseMusicConsoleLogs(musicLog)
            
            let defaultDevice = outputDevices.defaultOutputDevice
            if let first = cmStats.first, let supported = defaultDevice?.nominalSampleRates {
                let sampleRate = Float64(first.sampleRate)
                // https://stackoverflow.com/a/65060134
                let nearest = supported.enumerated().min(by: {
                    abs($0.element - sampleRate) < abs($1.element - sampleRate)
                })
                if let nearest = nearest {
                    let nearestSampleRate = nearest.element
                    if nearestSampleRate != defaultDevice?.nominalSampleRate {
                        defaultDevice?.setNominalSampleRate(nearestSampleRate)
                    }
                }
            }
        }
        catch {
            print(error)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}


