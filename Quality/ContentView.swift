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
    var body: some View {
        Text("Hello, world!")
            .padding()
            .onAppear {
                let coreAudio = SimplyCoreAudio()
                print(coreAudio.allOutputDevices.first?.nominalSampleRates)
                //AudioDeviceFinder.findDevices()
                DispatchQueue.main.async {
                    do {
                        let musicLog = try Console.getRecentEntries()
                        let cmStats = CMPlayerParser.parseMusicConsoleLogs(musicLog)
                        print(cmStats)
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


