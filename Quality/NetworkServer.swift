//
//  NetworkServer.swift
//  LosslessSwitcher
//
//  Created by Kris Roberts on 4/7/23.
//

import Foundation
import Network
import SystemConfiguration

class NetworkServer {
    var outputDevices: OutputDevices

    private let defaults = Defaults.shared
    private let hostName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Unknown"
    private var listener: NWListener?
    private var clientConnections: [NWConnection] = []
    
    init(_ outputDevices: OutputDevices) {
        self.outputDevices = outputDevices
    }
    
    func startListener() {
        let txtRecordData: [String: String] = ["serverHostName": hostName]
        let txtRecord = NWTXTRecord(txtRecordData)

        let tcpParameters = NWParameters.tcp
        let endpointPort = NWEndpoint.Port.any
        
        do {
            listener = try NWListener(using: tcpParameters, on: endpointPort)
        } catch {
            print("Failed to create listener: \(error)")
            return
        }
        
        listener?.service = NWListener.Service(name: "lossless-switcher", type: "_lossless-switcher._tcp", domain: "local", txtRecord: txtRecord)

        listener?.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                print("Listener ready")
            case .failed(let error):
                print("Listener failed with error: \(error)")
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { newConnection in
            newConnection.start(queue: .main)
            newConnection.stateUpdateHandler = { newState in
                // Check if the connection already exists in the array
                if !self.clientConnections.contains(where: { $0 === newConnection }) {
                    // Add the new connection to the clientConnections array if it doesn't already exist
                    self.clientConnections.append(newConnection)
                }
                switch newState {
                case .ready:
                    //self.lastConnection = newConnection
                    self.receiveClientMessage(connection: newConnection)
                default:
                    break
                }
            }
        }
        
        listener?.start(queue: .main)
    }
    
    func receiveClientMessage(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            if let data = data {
                do {
                    let clientMessage = try JSONDecoder().decode(ClientMessage.self, from: data)
                    print("Received: \(clientMessage)")
                    self.processClientMessage(clientMessage, connection: connection)
                } catch {
                    print("Error decoding ClientMessage: \(error)")
                }
            } else if let error = error {
                print("Error receiving ClientMessage: \(error)")
            }
        }
    }

    func processClientMessage(_ clientMessage: ClientMessage, connection: NWConnection) {
        switch clientMessage.request {
        case .refresh:
            self.sendServerResponse(self.getResponseData(), connection: connection)
            break
        case .toggleAutoSwitching:
            Task {
                await MainActor.run {
                    defaults.setPreferAutoSwitch(newValue: !defaults.userPreferAutoSwitch)
                    AppDelegate.instance.updateAutoSwitchingMenuItemState()
                }
            }
            break
        case .setDeviceSampleRate(let sampleRate):
            outputDevices.setDeviceSampleRate(sampleRate)
            break
        }
        
        // Call receiveClientMessage(connection:) again to continue listening for messages
        self.receiveClientMessage(connection: connection)

    }
    
    func getResponseData() -> ServerResponse {
        let response = ServerResponse(
            currentSampleRate: (self.outputDevices.currentSampleRate ?? 1) / 1000,
            detectedSampleRate: (self.outputDevices.detectedSampleRate ?? 1) / 1000,
            autoSwitchingEnabled: self.outputDevices.enableAutoSwitch,
            supportedSampleRates: self.outputDevices.supportedSampleRates,
            defaultOutputDeviceName: self.outputDevices.defaultOutputDevice?.name ?? "Unknown Output Device",
            serverHostName: self.hostName
        )
        return response
    }
    
    // Add a function to clean up inactive connections
    func cleanupInactiveConnections() {
        clientConnections.removeAll { connection in
            connection.state != .ready
        }
    }
    
    func updateClients() {
        // Call cleanupInactiveConnections to remove connections that are not in .ready state
        cleanupInactiveConnections()

        // Iterate through the client connections and send updates to any that are .ready
        for connection in clientConnections {
            if connection.state == .ready {
                sendServerResponse(getResponseData(), connection: connection)
            }
        }
    }
    
    func sendServerResponse(_ response: ServerResponse, connection: NWConnection) {
        do {
            let data = try JSONEncoder().encode(response)
            print("Sending: \(response)")
            connection.send(content: data, completion: .contentProcessed({ error in
                if let error = error {
                    print("Error sending ServerResponse: \(error)")
                } else {
                    print("ServerResponse sent")
                }
            }))
        } catch {
            print("Error encoding ServerResponse: \(error)")
        }
    }
    
}

struct ServerResponse: Codable, CustomStringConvertible {
    let currentSampleRate: Float64
    let detectedSampleRate: Float64
    let autoSwitchingEnabled: Bool
    let supportedSampleRates: [Float64] 
    let defaultOutputDeviceName: String
    let serverHostName: String
    
    var description: String {
        return "ServerResponse(currentSampleRate: \(currentSampleRate), detectedSampleRate: \(detectedSampleRate), autoSwitchingEnabled: \(autoSwitchingEnabled), serverHostName: \(serverHostName), defaultOutputDeviceName: \(defaultOutputDeviceName), supportedSampleRates: \(supportedSampleRates))"
    }
}

enum ClientRequest: Codable, CustomStringConvertible {
    case refresh
    case toggleAutoSwitching
    case setDeviceSampleRate(Float64)
    
    var description: String {
        switch self {
        case .refresh:
            return "ClientRequest.refresh"
        case .toggleAutoSwitching:
            return "ClientRequest.toggleAutoSwitching"
        case .setDeviceSampleRate(let sampleRate):
            return "ClientRequest.setDeviceSampleRate(\(sampleRate))"
        }
    }
    
    private enum CodingKeys: CodingKey {
        case type
        case sampleRate
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "refresh":
            self = .refresh
        case "toggleAutoSwitching":
            self = .toggleAutoSwitching
        case "setDeviceSampleRate":
            let sampleRate = try container.decode(Float64.self, forKey: .sampleRate)
            self = .setDeviceSampleRate(sampleRate)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid request type")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .refresh:
            try container.encode("refresh", forKey: .type)
        case .toggleAutoSwitching:
            try container.encode("toggleAutoSwitching", forKey: .type)
        case .setDeviceSampleRate(let sampleRate):
            try container.encode("setDeviceSampleRate", forKey: .type)
            try container.encode(sampleRate, forKey: .sampleRate)
        }
    }
}

struct ClientMessage: Codable, CustomStringConvertible {
    let request: ClientRequest
    
    var description: String {
        return "ClientMessage(request: \(request))"
    }
}
