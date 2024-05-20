//
//  MixBotApp.swift
//  MixBot
//
//  Created by Francisco Lobo on 21/03/24.
//

import SwiftUI

@main
struct MixBotApp: App {
//    let bluetoothEngine = BluetoothEngine(targetPeripheralUUIDString: "94635d24-cf8d-4ff8-9191-de713f39db89")
    let remoteEngine = RemoteEngine(targetPeripheralUUIDString: "94635d24-cf8d-4ff8-9191-de713f39db89")
       
    
    var body: some Scene {
           WindowGroup {
               DrinkMenuView()
                   .environmentObject(remoteEngine) // Inject BluetoothEngine into the environment
           }
       }
}


