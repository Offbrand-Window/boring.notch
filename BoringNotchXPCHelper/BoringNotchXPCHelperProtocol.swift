//
//  BoringNotchXPCHelperProtocol.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol BoringNotchXPCHelperProtocol {
    func headphoneBannerProfileInstalled(with reply: @escaping (Bool) -> Void)
    func returnBluetoothAudio(_ address: String, with reply: @escaping (Bool) -> Void)
    func smartRoutingEvents(with reply: @escaping (Data) -> Void)
    func stopSmartRoutingMonitor()
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func requestAccessibilityAuthorization()
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void)
    // Keyboard backlight / CoreBrightness access (performed by the helper)
    func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Screen brightness access (performed by the helper)
    func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
}

/*
 To use the service from an application or other process, use NSXPCConnection to establish a connection to the service by doing something like this:

     connectionToService = NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringNotchXPCHelper")
     connectionToService.remoteObjectInterface = NSXPCInterface(with: (any BoringNotchXPCHelperProtocol).self)
     connectionToService.resume()

 Once you have a connection to the service, you can use it like this:

     if let proxy = connectionToService.remoteObjectProxy as? BoringNotchXPCHelperProtocol {
         proxy.performCalculation(firstNumber: 23, secondNumber: 19) { result in
             NSLog("Result of calculation is: \(result)")
         }
     }

 And, when you are finished with the service, clean up the connection like this:

     connectionToService.invalidate()
*/


struct SmartRoutingBannerEvent: Codable, Equatable {
    let kind: String
    let name: String
    let address: String

    static func parse(_ message: String) -> Self? {
        let pattern = #"PostingBanner: Type (Connected|ReverseRoute), Name (.*?), Addr ([^,]+), PID "#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let kindRange = Range(match.range(at: 1), in: message),
              let nameRange = Range(match.range(at: 2), in: message),
              let addressRange = Range(match.range(at: 3), in: message) else { return nil }
        let name = String(message[nameRange])
        return Self(kind: String(message[kindRange]), name: name == "<private>" ? "AirPods" : name,
                    address: String(message[addressRange]))
    }
}

struct SmartRoutingMonitorReply: Codable {
    let running: Bool
    let error: String?
    let events: [SmartRoutingBannerEvent]
}
