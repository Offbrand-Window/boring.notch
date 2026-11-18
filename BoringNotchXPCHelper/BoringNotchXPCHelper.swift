//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import ObjectiveC
import ApplicationServices
import IOKit
import CoreGraphics

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    private let routingMonitor = NativeSmartRoutingMonitor()
    private var audioRoutingRequests: [UUID: NSObject] = [:]

    func headphoneBannerProfileInstalled(with reply: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/profiles")
            process.arguments = ["list"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { process.terminate() }
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                reply(String(decoding: data, as: UTF8.self)
                    .contains("local.arjun.boringnotch.custom.headphone-banners"))
            } catch { reply(false) }
        }
    }

    func returnBluetoothAudio(_ address: String, with reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            guard address.range(of: #"^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$"#,
                                options: .regularExpression) != nil else { reply(false); return }
            _ = dlopen("/System/Library/PrivateFrameworks/BluetoothServices.framework/BluetoothServices", RTLD_NOW)
            guard let cls = NSClassFromString("BTAudioRoutingRequest") as? NSObject.Type else {
                reply(false)
                return
            }
            let request = cls.init()
            guard request.responds(to: NSSelectorFromString("activate")),
                  request.responds(to: NSSelectorFromString("setDeviceAddress:")),
                  request.responds(to: NSSelectorFromString("setFlags:")),
                  request.responds(to: NSSelectorFromString("setResponseHandler:")) else {
                reply(false)
                return
            }
            let token = UUID()
            self.audioRoutingRequests[token] = request
            request.setValue(address.replacingOccurrences(of: "-", with: ":"), forKey: "deviceAddress")
            // Native BluetoothServices identifies bit 0 as Hijack and bit 2 as
            // UIRoute. This is a user-requested route, not background playback.
            request.setValue(NSNumber(value: UInt32(0x5)), forKey: "flags")
            request.setValue(NSNumber(value: 301), forKey: "audioScore")
            request.setValue("local.arjun.boringnotch.custom", forKey: "appBundleID")
            request.setValue("User selected Return to Mac", forKey: "reason")
            request.setValue(DispatchQueue.main, forKey: "dispatchQueue")
            let finish: (Bool) -> Void = { [weak self] accepted in
                guard let request = self?.audioRoutingRequests.removeValue(forKey: token) else { return }
                request.perform(NSSelectorFromString("invalidate"))
                reply(accepted)
            }
            let handler: @convention(block) (NSObject) -> Void = { response in
                finish(response.value(forKey: "error") == nil)
            }
            request.setValue(handler, forKey: "responseHandler")
            request.perform(NSSelectorFromString("activate"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(false) }
        }
    }

    func smartRoutingEvents(with reply: @escaping (Data) -> Void) {
        routingMonitor.drain(reply)
    }

    func stopSmartRoutingMonitor() {
        routingMonitor.stop()
    }

    
    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        if promptIfNeeded {
            requestAccessibilityAuthorization()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(AXIsProcessTrusted())
        }
    }
    
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        var isAvailable: Bool { clientInstance != nil }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.isAvailable)
    }

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    @objc func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        var b: Float = 0
        reply(displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) || ioServiceFor(displayID: CGMainDisplayID()) != nil)
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        var b: Float = 0
        if displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        if displayServicesSetBrightness(displayID: CGMainDisplayID(), value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}


/// Read only the native AirPods banner events. No system logs are stored or
/// transmitted; the helper returns just the device name, address and event kind.
/// This supplements HAL because smart routing can leave its output unchanged.
private final class NativeSmartRoutingMonitor {
    private let queue = DispatchQueue(label: "local.arjun.boringnotch.smart-routing")
    private var process: Process?
    private var pending: [SmartRoutingBannerEvent] = []
    private var carry = Data()
    private var lastStart = Date.distantPast
    private var lastError: String?
    private var lastDrain = Date()
    private var leaseTimer: DispatchSourceTimer?

    func drain(_ reply: @escaping (Data) -> Void) {
        queue.async {
            self.lastDrain = Date()
            self.startIfNeeded()
            let response = SmartRoutingMonitorReply(running: self.process?.isRunning == true,
                                                   error: self.lastError, events: self.pending)
            self.pending.removeAll(keepingCapacity: true)
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }

    func stop() {
        queue.async {
            self.leaseTimer?.cancel()
            self.leaseTimer = nil
            self.process?.terminationHandler = nil
            self.process?.terminate()
            self.process = nil
            self.pending.removeAll()
            self.carry.removeAll()
            self.lastStart = .distantPast
        }
    }

    private func startIfNeeded() {
        guard process?.isRunning != true, Date().timeIntervalSince(lastStart) >= 5 else { return }
        lastStart = Date()
        carry.removeAll()
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = ["stream", "--style", "ndjson", "--level", "info", "--predicate",
            "process == \"audioaccessoryd\" AND category == \"BTSmartRoutingDaemon\" AND eventMessage BEGINSWITH \"PostingBanner: Type\""]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.consume(data) }
        }
        task.terminationHandler = { [weak self] task in
            self?.queue.async {
                guard self?.process === task else { return }
                self?.lastError = "AirPods handoff monitor stopped (exit \(task.terminationStatus))."
                self?.process = nil
            }
        }
        do {
            try task.run()
            process = task
            lastError = nil
            leaseTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastDrain) > 10 { self.stop() }
            }
            leaseTimer = timer
            timer.resume()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            lastError = "AirPods handoff monitor could not start: \(error.localizedDescription)"
        }
    }

    private func consume(_ data: Data) {
        carry.append(data)
        while let newline = carry.firstIndex(of: 10) {
            let line = Data(carry[..<newline])
            carry.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = object["eventMessage"] as? String,
                  let event = SmartRoutingBannerEvent.parse(message) else { continue }
            pending.append(event)
            if pending.count > 32 { pending.removeFirst(pending.count - 32) }
        }
        if carry.count > 1_048_576 { carry.removeAll() }
    }
}
