import Foundation
import IOKit.ps

/// Manages and monitors battery status changes on the device
/// - Note: This class uses the IOKit framework to monitor battery status
class BatteryActivityManager {

    static let shared = BatteryActivityManager()

    var onBatteryLevelChange: ((Float) -> Void)?
    var onMaxCapacityChange: ((Float) -> Void)?
    var onPowerModeChange: ((Bool) -> Void)?
    var onPowerSourceChange: ((Bool) -> Void)?
    var onChargingChange: ((Bool) -> Void)?
    var onTimeToFullChargeChange: ((Int) -> Void)?

    private var batterySource: CFRunLoopSource?
    private var observers: [(BatteryEvent) -> Void] = []
    private var previousBatteryInfo: BatteryInfo?
    private var notificationQueue: [BatteryEvent] = []
    private var isProcessingNotifications = false

    enum BatteryEvent {
        case powerSourceChanged(isPluggedIn: Bool)
        case batteryLevelChanged(level: Float)
        case lowPowerModeChanged(isEnabled: Bool)
        case isChargingChanged(isCharging: Bool)
        case timeToFullChargeChanged(time: Int)
        case maxCapacityChanged(capacity: Float)
        case error(description: String)
    }

    enum BatteryError: Error {
        case powerSourceUnavailable
        case batteryInfoUnavailable(String)
        case batteryParameterMissing(String)
    }

    private let defaultBatteryInfo = BatteryInfo(
        isPluggedIn: false,
        isCharging: false,
        currentCapacity: 0,
        maxCapacity: 0,
        isInLowPowerMode: false,
        timeToFullCharge: 0
    )

    private init() {
        startMonitoring()
        setupLowPowerModeObserver()
    }
    
    /// Setup observer for low power mode changes
    private func setupLowPowerModeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lowPowerModeChanged),
            name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
    }

    /// Called when low power mode is enabled or disabled
    @objc private func lowPowerModeChanged() {
        notifyBatteryChanges()
    }
    
    /// Starts monitoring battery changes
    private func startMonitoring() {
        guard let powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let manager = Unmanaged<BatteryActivityManager>.fromOpaque(context).takeUnretainedValue()
            manager.notifyBatteryChanges()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else {
            return
        }
        batterySource = powerSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), powerSource, .defaultMode)
    }

    /// Stops monitoring battery changes
    private func stopMonitoring() {
        if let powerSource = batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), powerSource, .defaultMode)
            batterySource = nil
        }
    }

    /// Checks for changes in a property and notifies observers
    private func checkAndNotify<T: Equatable>(
        previous: T, 
        current: T, 
        eventGenerator: (T) -> BatteryEvent
    ) {
        if previous != current {
            enqueueNotification(eventGenerator(current))
        }
    }
    
    /// Notifies the observers of battery changes
    /// Checks for changes in battery status and notifies observers
    private func notifyBatteryChanges() {
        let batteryInfo = getBatteryInfo()
        
        // Check for changes
        if let previousInfo = previousBatteryInfo {
            // Usar la función auxiliar para cada propiedad
            checkAndNotify(
                previous: previousInfo.isPluggedIn,
                current: batteryInfo.isPluggedIn,
                eventGenerator: { .powerSourceChanged(isPluggedIn: $0) }
            )
            
            checkAndNotify(
                previous: previousInfo.currentCapacity,
                current: batteryInfo.currentCapacity,
                eventGenerator: { .batteryLevelChanged(level: $0) }
            )
            
            checkAndNotify(
                previous: previousInfo.isCharging,
                current: batteryInfo.isCharging,
                eventGenerator: { .isChargingChanged(isCharging: $0) }
            )
            
            checkAndNotify(
                previous: previousInfo.isInLowPowerMode,
                current: batteryInfo.isInLowPowerMode,
                eventGenerator: { .lowPowerModeChanged(isEnabled: $0) }
            )
            
            checkAndNotify(
                previous: previousInfo.timeToFullCharge,
                current: batteryInfo.timeToFullCharge,
                eventGenerator: { .timeToFullChargeChanged(time: $0) }
            )
            
            checkAndNotify(
                previous: previousInfo.maxCapacity,
                current: batteryInfo.maxCapacity,
                eventGenerator: { .maxCapacityChanged(capacity: $0) }
            )
        } else {
            // First time notification
            enqueueNotification(.powerSourceChanged(isPluggedIn: batteryInfo.isPluggedIn))
            enqueueNotification(.batteryLevelChanged(level: batteryInfo.currentCapacity))
            enqueueNotification(.isChargingChanged(isCharging: batteryInfo.isCharging))
            enqueueNotification(.lowPowerModeChanged(isEnabled: batteryInfo.isInLowPowerMode))
            enqueueNotification(.timeToFullChargeChanged(time: batteryInfo.timeToFullCharge))
            enqueueNotification(.maxCapacityChanged(capacity: batteryInfo.maxCapacity))
        }

        // Update previous battery info
        previousBatteryInfo = batteryInfo

        // Trigger optional callbacks
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onBatteryLevelChange?(batteryInfo.currentCapacity)
            self.onPowerSourceChange?(batteryInfo.isPluggedIn)
            self.onChargingChange?(batteryInfo.isCharging)
            self.onPowerModeChange?(batteryInfo.isInLowPowerMode)
            self.onTimeToFullChargeChange?(batteryInfo.timeToFullCharge)
            self.onMaxCapacityChange?(batteryInfo.maxCapacity)
        }
    }

    /// Enqueues a notification to be processed
    /// - Parameter event: The battery event
    private func enqueueNotification(_ event: BatteryEvent) {
        notificationQueue.append(event)
        processNextNotification()
    }
    
    /// Processes the next notification in the queue
    /// If there are no more notifications, the queue is cleared
    /// and the processing flag is set to false
    private func processNextNotification() {
        guard !isProcessingNotifications, !notificationQueue.isEmpty else { return }
        isProcessingNotifications = true
        
        let event = notificationQueue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.notifyObservers(event: event)
            self.isProcessingNotifications = false
            
            // Check if there are more items in the queue
            if !self.notificationQueue.isEmpty {
                self.processNextNotification()
            }
        }
    }
    
    /// Initializes the battery information when the manager starts
    /// - Returns: Current battery information
    func initializeBatteryInfo() -> BatteryInfo {
        previousBatteryInfo = getBatteryInfo()
        guard let batteryInfo = previousBatteryInfo else {
            return BatteryInfo(
                isPluggedIn: false,
                isCharging: false,
                currentCapacity: 0,
                maxCapacity: 0,
                isInLowPowerMode: false,
                timeToFullCharge: 0
            )
        }
        return batteryInfo
    }

    /// Get the current battery information
    /// - Returns: The current battery information
    private func getBatteryInfo() -> BatteryInfo {
        do {
            // Get power source information
            guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
                throw BatteryError.powerSourceUnavailable
            }
            
            guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
                !sources.isEmpty else {
                throw BatteryError.batteryInfoUnavailable("No power sources available")
            }
            
            let source = sources.first!
            
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                throw BatteryError.batteryInfoUnavailable("Could not get power source description")
            }
            
            // Extract required battery parameters with error handling
            guard let currentCapacity = description[kIOPSCurrentCapacityKey] as? Float else {
                throw BatteryError.batteryParameterMissing("Current capacity")
            }
            
            guard let maxCapacity = description[kIOPSMaxCapacityKey] as? Float else {
                throw BatteryError.batteryParameterMissing("Max capacity")
            }
            
            guard let isCharging = description["Is Charging"] as? Bool else {
                throw BatteryError.batteryParameterMissing("Charging state")
            }
            
            guard let powerSource = description[kIOPSPowerSourceStateKey] as? String else {
                throw BatteryError.batteryParameterMissing("Power source state")
            }
            
            // Create battery info with the extracted parameters
            var batteryInfo = BatteryInfo(
                isPluggedIn: powerSource == kIOPSACPowerValue,
                isCharging: isCharging,
                currentCapacity: currentCapacity,
                maxCapacity: maxCapacity,
                isInLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                timeToFullCharge: 0
            )
            
            // Optional parameters
            if let timeToFullCharge = description[kIOPSTimeToFullChargeKey] as? Int {
                batteryInfo.timeToFullCharge = timeToFullCharge
            }
            
            return batteryInfo
            
        } catch BatteryError.powerSourceUnavailable {
            print("⚠️ Error: Power source information unavailable")
            return defaultBatteryInfo
        } catch BatteryError.batteryInfoUnavailable(let reason) {
            print("⚠️ Error: Battery information unavailable - \(reason)")
            return defaultBatteryInfo
        } catch BatteryError.batteryParameterMissing(let parameter) {
            print("⚠️ Error: Battery parameter missing - \(parameter)")
            return defaultBatteryInfo
        } catch {
            print("⚠️ Error: Unexpected error getting battery info - \(error.localizedDescription)")
            return defaultBatteryInfo
        }
    }
    
    /// Adds an observer to listen to battery changes
    /// - Parameter observer: The observer closure to be called on battery events
    /// - Returns: The ID of the observer for later removal
    func addObserver(_ observer: @escaping (BatteryEvent) -> Void) -> Int {
        observers.append(observer)
        return observers.count - 1
    }

    /// Removes an observer by its ID
    /// - Parameter id: The ID of the observer to be removed
    func removeObserver(byId id: Int) {
        guard id >= 0 && id < observers.count else { return }
        observers.remove(at: id)
    }
    
    /// Notifies all observers of a battery event
    /// - Parameter event: The battery event to notify
    private func notifyObservers(event: BatteryEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for observer in self.observers {
                observer(event)
            }
        }
    }
    
    deinit {
        stopMonitoring()
        NotificationCenter.default.removeObserver(self)
    }
    
}

/// Struct to hold battery information
struct BatteryInfo {
    var isPluggedIn: Bool
    var isCharging: Bool
    var currentCapacity: Float
    var maxCapacity: Float
    var isInLowPowerMode: Bool
    var timeToFullCharge: Int
}


// Local additions share this compilation unit with the existing activity manager.
import AppKit
import Combine
import Defaults
import IOBluetooth
import CoreAudio
import OSLog

/// Listens for baseband events without scanning for, pairing, or connecting devices.
@MainActor
final class NotchActivityManager: NSObject, ObservableObject {
    static let shared = NotchActivityManager()

    struct BluetoothEvent: Identifiable {
        let id = UUID()
        let name: String
        let connected: Bool
        let icon: String
        var status: String? = nil
        var audioDeviceID: AudioDeviceID? = nil
        var bluetoothAddress: String? = nil
    }

    @Published private(set) var lockState = NotchLockPresentationState()
    var isLocked: Bool { lockState.phase == .locked }
    var isUnlocking: Bool { lockState.phase == .unlocking }
    var isLockPresentationActive: Bool { lockState.phase != .unlocked }
    private var unlockTask: Task<Void, Never>?
    private var returnAudioTask: Task<Void, Never>?
    @Published private(set) var isReturningAudio = false
    @Published private(set) var bluetoothEvent: BluetoothEvent?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var connectedAddresses: Set<String> = []
    private var dismissTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var nativeRoutingTask: Task<Void, Never>?
    private var nativeStates: [String: (connected: Bool, received: Date)] = [:]
    @Published private(set) var smartRoutingMonitorError: String?
    private var bluetoothTracker = BluetoothConnectionTracker()
    private var audioTracker = BluetoothConnectionTracker()
    private var routeTracker = BluetoothAudioRouteTracker()
    private var knownAudioDeviceIDs: [String: AudioDeviceID] = [:]
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var lastReportedStates: [String: Bool] = [:]
    private let logger = Logger(subsystem: "local.arjun.boringnotch.custom", category: "BluetoothActivity")

    private override init() {
        super.init()
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if session["CGSSessionScreenIsLocked"] as? Bool == true {
                lockState.lock()
            }
        }
        // Seed existing connections silently; launching must not announce old connections.
        for device in IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [] {
            if device.isConnected(), let address = device.addressString {
                connectedAddresses.insert(address)
                watchDisconnect(device)
            }
        }
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
            selector: #selector(didConnect(_:device:)))
        // CoreAudio is prompt-free and reports AirPods becoming available even
        // when macOS fails to deliver the legacy IOBluetooth callback.
        refreshConnections()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshConnections() }
        }
        audioListener = listener
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { break }
                self?.refreshConnections()
            }
        }
        nativeRoutingTask = Task { [weak self] in
            var wasEnabled = false
            while !Task.isCancelled {
                if Defaults[.bluetoothLiveActivity] {
                    wasEnabled = true
                    if let reply = await XPCHelperClient.shared.smartRoutingEvents() {
                        self?.smartRoutingMonitorError = reply.error
                        for event in reply.events { self?.receiveNativeRoutingEvent(event) }
                    } else {
                        self?.smartRoutingMonitorError = "AirPods handoff monitor is unavailable."
                    }
                } else if wasEnabled {
                    wasEnabled = false
                    XPCHelperClient.shared.stopSmartRoutingMonitor()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        logger.info("Connection monitoring started: native smart routing, Bluetooth callbacks, CoreAudio, and reconciliation")
        // Explicit local preview arguments exercise the rendered states without
        // locking the Mac or interrupting a real Bluetooth connection.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--preview-lock") {
            setLocked(true)
            if arguments.contains("--preview-lock-cycle") {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.setLocked(false)
                }
            }
        } else if arguments.contains("--preview-bluetooth-handoff") {
            bluetoothEvent = BluetoothEvent(name: "Preview AirPods Pro", connected: false,
                                            icon: "airpodspro", status: "Audio moved", audioDeviceID: 0)
        } else if arguments.contains("--preview-bluetooth-connected") || arguments.contains("--preview-bluetooth-disconnected") {
            bluetoothEvent = BluetoothEvent(name: "Preview AirPods Pro", connected: arguments.contains("--preview-bluetooth-connected"), icon: "airpodspro")
        }
    }

    func setLocked(_ locked: Bool) {
        if locked {
            unlockTask?.cancel()
            lockState.lock()
        } else {
            guard isLocked else { return }
            unlockTask?.cancel()
            if let generation = lockState.beginUnlock(showTransition: Defaults[.showOnLockScreen]) {
                unlockTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    self?.lockState.finishUnlock(generation: generation)
                }
            }
        }
        dismissTask?.cancel()
        bluetoothEvent = nil
    }

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        guard let address = device.addressString,
              disconnectNotifications[address] == nil else { return }
        disconnectNotifications[address] = device.register(forDisconnectNotification: self,
            selector: #selector(didDisconnect(_:device:)))
    }

    @objc private func didConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        watchDisconnect(device)
        guard connectedAddresses.insert(address).inserted else { return }
        show(name: device.name ?? "Bluetooth device", connected: true, source: "callback")
    }

    @objc private func didDisconnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        disconnectNotifications.removeValue(forKey: address)?.unregister()
        guard connectedAddresses.remove(address) != nil else { return }
        show(name: device.name ?? "Bluetooth device", connected: false, source: "callback")
    }

    private func refreshConnections() {
        // A failed Bluetooth query is not an empty snapshot: retain the old
        // baseline rather than incorrectly reporting every device disconnected.
        if let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            var snapshot: [String: String] = [:]
            for device in devices where device.isConnected() {
                guard let address = device.addressString else { continue }
                snapshot[address] = device.name ?? "Bluetooth device"
                connectedAddresses.insert(address)
                watchDisconnect(device)
            }
            for event in bluetoothTracker.update(snapshot) {
                show(name: event.name, connected: event.connected, source: "Bluetooth reconciliation")
            }
        }
        if let snapshot = Self.connectedBluetoothAudioDevices() {
            for event in audioTracker.update(snapshot) {
                show(name: event.name, connected: event.connected, source: "CoreAudio")
            }
            let route = Self.defaultBluetoothOutput()
            if let route { knownAudioDeviceIDs[route.name] = route.id }
            for change in routeTracker.update(route?.name) {
                // A physical removal already produces Disconnected. A route
                // change while the headset remains available is a handoff.
                if !change.connected && !snapshot.values.contains(change.name) { continue }
                show(name: change.name, connected: change.connected, source: "audio route",
                     status: change.connected ? "On this Mac" : "Audio moved",
                     audioDeviceID: change.connected ? nil : knownAudioDeviceIDs[change.name], force: true)
            }
        }
    }

    private static func defaultBluetoothOutput() -> (id: AudioDeviceID, name: String)? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else { return nil }
        address.mSelector = kAudioObjectPropertyName
        var rawName: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rawName) == noErr,
              let name = rawName?.takeRetainedValue() as String? else { return nil }
        return (id, name)
    }

    func returnAudioToMac(_ event: BluetoothEvent) {
        guard !isReturningAudio else { return }
        let started = Date()
        let key = Self.normalizedDeviceName(event.name)
        let address = event.bluetoothAddress ?? (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?
            .first { Self.normalizedDeviceName($0.name ?? "") == key }?.addressString
        isReturningAudio = true
        dismissTask?.cancel()
        bluetoothEvent = BluetoothEvent(name: event.name, connected: false, icon: event.icon, status: "Switching…")
        logger.info("Return to Mac requested through native UIRoute command")
        returnAudioTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isReturningAudio = false; self.returnAudioTask = nil }
            var submitted = false
            if let address { submitted = await XPCHelperClient.shared.returnBluetoothAudio(address: address) }
            if submitted {
                for _ in 0..<20 {
                    if Task.isCancelled { return }
                    if let native = self.nativeStates[key], native.connected, native.received >= started {
                        self.logger.info("Return to Mac confirmed by native smart routing")
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            guard !Task.isCancelled else { return }
            self.logger.error("Native audio return was not confirmed; request submitted=\(submitted, privacy: .public)")
            self.bluetoothEvent = BluetoothEvent(name: event.name, connected: false, icon: event.icon,
                status: "Select in Sound", audioDeviceID: event.audioDeviceID,
                bluetoothAddress: event.bluetoothAddress)
            self.dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.bluetoothEvent = nil
            }
        }
    }

    private static func connectedBluetoothAudioDevices() -> [String: String]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return nil }
        var snapshot: [String: String] = [:]
        for device in devices {
            address.mSelector = kAudioDevicePropertyTransportType
            var transport: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else { continue }
            address.mSelector = kAudioDevicePropertyDeviceIsAlive
            var alive: UInt32 = 0
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr, alive != 0 else { continue }
            address.mSelector = kAudioObjectPropertyName
            var rawName: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rawName) == noErr,
                  let name = rawName?.takeRetainedValue() as String? else { continue }
            // HAL exposes separate input/output endpoints for the same headset.
            // Coalesce them so profile changes do not create duplicate alerts.
            snapshot[name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)] = name
        }
        return snapshot
    }

    private static func normalizedDeviceName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    private func receiveNativeRoutingEvent(_ event: SmartRoutingBannerEvent) {
        let connected = event.kind == "Connected"
        nativeStates[Self.normalizedDeviceName(event.name)] = (connected, Date())
        let deviceID = knownAudioDeviceIDs.first {
            Self.normalizedDeviceName($0.key) == Self.normalizedDeviceName(event.name)
        }?.value
        show(name: event.name, connected: connected, source: "native smart routing",
             status: connected ? "On this Mac" : "Audio moved",
             audioDeviceID: connected ? nil : deviceID,
             bluetoothAddress: connected ? nil : event.address, force: true)
    }

    private func show(name: String, connected: Bool, source: String, status: String? = nil,
                      audioDeviceID: AudioDeviceID? = nil, bluetoothAddress: String? = nil, force: Bool = false) {
        guard Defaults[.bluetoothLiveActivity], !isLockPresentationActive else { return }
        let key = Self.normalizedDeviceName(name)
        if isReturningAudio && source != "native smart routing" { return }
        // Native ownership events outrank delayed HAL/baseband callbacks.
        if source != "native smart routing", let native = nativeStates[key],
           Date().timeIntervalSince(native.received) < 3 { return }
        // Legacy callbacks can lag HAL events by several seconds. Suppress
        // the same state until an opposite transition has been reported.
        guard force || lastReportedStates[key] != connected else { return }
        lastReportedStates[key] = connected
        logger.info("Activity received: connected=\(connected, privacy: .public), source=\(source, privacy: .public)")
        let lower = name.lowercased()
        let icon: String
        if lower.contains("airpods") { icon = "airpodspro" }
        else if lower.contains("head") || lower.contains("beats") { icon = "headphones" }
        else if lower.contains("mouse") { icon = "computermouse" }
        else if lower.contains("keyboard") { icon = "keyboard" }
        else { icon = "antenna.radiowaves.left.and.right" }
        dismissTask?.cancel()
        let event = BluetoothEvent(name: name, connected: connected, icon: icon, status: status,
                                   audioDeviceID: audioDeviceID, bluetoothAddress: bluetoothAddress)
        bluetoothEvent = event
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(audioDeviceID == nil && bluetoothAddress == nil ? 4 : 10))
            guard !Task.isCancelled, self?.bluetoothEvent?.id == event.id else { return }
            self?.bluetoothEvent = nil
        }
    }
}


/// Pure state comparison, shared by callback reconciliation and CoreAudio.
/// Initial state is silent; subsequent additions/removals are real transitions.
struct BluetoothConnectionTracker {
    struct Change: Equatable {
        let name: String
        let connected: Bool
    }
    private var previous: [String: String]?

    mutating func update(_ snapshot: [String: String]) -> [Change] {
        defer { previous = snapshot }
        guard let previous else { return [] }
        var changes: [Change] = []
        for id in previous.keys.sorted() where snapshot[id] == nil {
            changes.append(Change(name: previous[id]!, connected: false))
        }
        for id in snapshot.keys.sorted() where previous[id] == nil {
            changes.append(Change(name: snapshot[id]!, connected: true))
        }
        return changes
    }
}


/// Route changes are independent of the Bluetooth link: AirPods may keep the
/// link while iPhone owns audio, then return without any new connect callback.
struct BluetoothAudioRouteTracker {
    private var seeded = false
    private var previous: String?

    mutating func update(_ current: String?) -> [BluetoothConnectionTracker.Change] {
        defer { seeded = true; previous = current }
        guard seeded, current != previous else { return [] }
        var changes: [BluetoothConnectionTracker.Change] = []
        if let previous { changes.append(.init(name: previous, connected: false)) }
        if let current { changes.append(.init(name: current, connected: true)) }
        return changes
    }
}


@MainActor
func prepareHeadphoneBannerProfile() {
    let profile: [String: Any] = [
        "PayloadType": "Configuration", "PayloadVersion": 1,
        "PayloadIdentifier": "local.arjun.boringnotch.custom.headphone-banners",
        "PayloadUUID": "6DDE856B-24F0-494F-9C39-4071A66B4C30",
        "PayloadScope": "User",
        "PayloadDisplayName": "Boring Notch: Hide macOS Headphone Banners",
        "PayloadDescription": "Disables Apple's headphone notifications, including AirPods connection and smart-routing banners, so Boring Notch can display them. Applies system-wide while installed, including when Boring Notch is closed. Remove this profile in Device Management to restore Apple's headphone banners. No enrollment, network, certificates, or other settings are included.",
        "PayloadOrganization": "Boring Notch — Offbrand-Window fork",
        "PayloadRemovalDisallowed": false,
        "PayloadContent": [[
            "PayloadType": "com.apple.notificationsettings", "PayloadVersion": 1,
            "PayloadIdentifier": "local.arjun.boringnotch.custom.headphone-banners.notifications",
            "PayloadUUID": "21F51842-EBD7-4C84-AD33-27E11B3C4435",
            "PayloadDisplayName": "Headphone Notifications Only",
            "NotificationSettings": [["BundleIdentifier": "com.apple.BTUserNotifications", "NotificationsEnabled": false]]
        ]]
    ]
    do {
        let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Hide-macOS-Headphone-Banners.mobileconfig")
        try data.write(to: url, options: .atomic)
        NSWorkspace.shared.open(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            openHeadphoneProfileSettings()
        }
    } catch {
        let alert = NSAlert()
        alert.messageText = "Could not prepare headphone banner settings"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}


/// A stale unlock completion must never dismiss a newly locked notch.
struct NotchLockPresentationState {
    enum Phase { case unlocked, locked, unlocking }
    private(set) var phase: Phase = .unlocked
    private var generation = 0

    mutating func lock() {
        generation += 1
        phase = .locked
    }

    mutating func beginUnlock(showTransition: Bool) -> Int? {
        guard phase == .locked else { return nil }
        generation += 1
        phase = showTransition ? .unlocking : .unlocked
        return showTransition ? generation : nil
    }

    mutating func finishUnlock(generation token: Int) {
        guard token == generation, phase == .unlocking else { return }
        phase = .unlocked
    }
}


@MainActor
func openHeadphoneProfileSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension") {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class HeadphoneBannerProfileManager: ObservableObject {
    static let shared = HeadphoneBannerProfileManager()
    @Published private(set) var isInstalled = false
    @Published private(set) var awaitingApproval = false
    @Published private(set) var isChecking = true
    private var refreshTask: Task<Void, Never>?

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            let installed = await XPCHelperClient.shared.headphoneBannerProfileInstalled()
            guard !Task.isCancelled else { return }
            isInstalled = installed
            isChecking = false
            // Returning from System Settings reflects the actual installed state,
            // including installation cancellation or profile removal.
            awaitingApproval = false
        }
    }

    func setOverride(_ enabled: Bool) {
        if enabled {
            guard !isInstalled else { return }
            awaitingApproval = true
            prepareHeadphoneBannerProfile()
        } else if isInstalled {
            openHeadphoneProfileSettings()
        } else {
            awaitingApproval = false
        }
    }
}
