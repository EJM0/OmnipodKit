//
//  OmniPumpManager+DeviceHandoff.swift
//  OmnipodKit
//
//  Handing the pod to another controller: LoopKit's DeviceConfigurationSharing,
//  ExclusiveDeviceControl and PumpDeliveryOdometer. The kit keeps the contract's rules here:
//  an export carries no local state, live session or pending command; this controller's own
//  handle for the pod travels only in its `localState`, which the host saves and hands back at
//  the next adopt; an adopter owns the in-flight doses under the exporter's identities; a
//  controller that released drops its copies when it takes control back; and none books
//  delivery it did not command (PodState). A faulted pod can be ended by the controller holding
//  it, and the other forgets it without booking.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import os.log

// MARK: - Configuration sharing

extension OmniPumpManager: DeviceConfigurationSharing {

    /// Marks the pod shared: another controller may run it from this copy.
    public func exportConfiguration() -> SharedDeviceConfiguration {
        if state.podState?.sharedWithAnotherController == false {
            podComms.markSharedWithAnotherController()
        }
        return state.sharedConfiguration(managerIdentifier: pluginIdentifier)
    }

    /// The state `init(adopting:localState:)` builds from, with this controller's own handle if
    /// `localState` holds one for the same pod; `takeControl()` searches if not.
    static func adoptedRawState(from configuration: SharedDeviceConfiguration, localState: [String: Any]?) -> RawStateValue? {
        guard let shared = OmniPumpManagerState(rawValue: configuration.state) else {
            return nil
        }
        let handle = shared.podState.flatMap { OmniPumpManagerState.handle(in: localState, forPodAddress: $0.address) }
        return shared.adopted(handle: handle).rawValue
    }

    /// This controller's handle for its pod, from the manager's state.
    public var localState: [String: Any]? {
        state.localState
    }
}

extension OmniPumpManagerState {

    /// This controller's CoreBluetooth handle for the pod, with the pod's address so it is never
    /// used for another pod. Handles are per device, so the export never carries one.
    var localState: [String: Any]? {
        guard let pod = podState, let handle = pod.bleIdentifier else { return nil }
        return ["podAddress": pod.address, "bleIdentifier": handle]
    }

    /// The handle in `localState`, if it is for the pod at `address`.
    static func handle(in localState: [String: Any]?, forPodAddress address: UInt32) -> String? {
        guard let localState, localState["podAddress"] as? UInt32 == address else { return nil }
        return localState["bleIdentifier"] as? String
    }

    /// The export: facts about the pod, none of this controller's relationship to it.
    func sharedConfiguration(managerIdentifier: String) -> SharedDeviceConfiguration {
        var shared = self
        shared.podConnectionReleased = false
        shared.configuredByAnotherController = false
        shared.inFlightDosesInheritedAway = false
        shared.rileyLinkConnectionManagerState = nil
        shared.updatePodStateFromPodComms(podState?.sharedFacts)
        let measured = shared.podState?.lastInsulinMeasurements
        return SharedDeviceConfiguration(managerIdentifier: managerIdentifier,
                                         asOf: measured?.validTime ?? Date(),
                                         deliveredUnits: measured?.delivered,
                                         state: shared.rawValue)
    }

    /// Another controller's shared state as this one's: in-flight doses keep the exporter's
    /// identities, and delivery this controller did not command is not booked.
    func adopted(handle: String?) -> OmniPumpManagerState {
        var state = self
        var pod = podState?.sharedFacts
        pod?.bleIdentifier = handle
        pod?.untrackedDeliveryIsForeign = true
        pod?.sharedWithAnotherController = true
        pod?.expectsSessionResync = true
        state.updatePodStateFromPodComms(pod)
        state.podConnectionReleased = false
        state.configuredByAnotherController = true
        state.inFlightDosesInheritedAway = false
        state.rileyLinkConnectionManagerState = nil
        return state
    }

    /// Not while a command to the pod is unconfirmed, sent or still being sent: the export leaves it
    /// out, and only this controller could settle it.
    var mayReleaseControl: Bool { podState?.unacknowledgedCommand == nil }

    /// Copies of a bolus or temp basal still in flight now belong to the controller taking over.
    mutating func releaseControl() {
        podConnectionReleased = true
        inFlightDosesInheritedAway = podState?.unfinalizedBolus != nil || podState?.unfinalizedTempBasal != nil
    }
}

extension PodState {

    /// The pod without this controller's handle, session keys, per-session counters or pending
    /// command. The EAP sequence and message number travel; the pod resynchronizes both.
    var sharedFacts: PodState {
        var pod = self
        pod.bleIdentifier = nil
        pod.unacknowledgedCommand = nil
        pod.lastDeliveryStatusReceived = nil
        pod.untrackedDeliveryIsForeign = false
        pod.expectsSessionResync = false
        pod.foreignSessionDetectedAt = nil
        pod.supersedingTake = nil
        pod.refusesSessions = false
        pod.bleMessageTransportState = BleMessageTransportState(ck: nil, noncePrefix: nil,
                                                                eapSeq: bleMessageTransportState.eapSeq,
                                                                messageNumber: bleMessageTransportState.messageNumber)
        return pod
    }

    /// Another controller ran the pod: forget the last delivery status, book no untracked delivery,
    /// and with `dropInFlight` drop the in-flight copies so the pod's status resolves them. A command
    /// still unconfirmed is dropped with nothing booked: the pod's status now answers for the other
    /// controller's commands, and the host's check of the pod's delivered total books any excess.
    mutating func resolveAfterForeignControl(dropInFlight: Bool) {
        lastDeliveryStatusReceived = nil
        reportedBolusEndsAt = nil
        untrackedDeliveryIsForeign = true
        unacknowledgedCommand = nil
        if dropInFlight {
            unfinalizedBolus = nil
            unfinalizedTempBasal = nil
        }
    }

    /// The pod's session counter was found ahead of this controller's. On a shared pod, another
    /// controller may have run it: resolve as after foreign control, keeping in-flight copies. A pod
    /// never shared resyncs as before: only this controller's own counter, saved late, can be
    /// behind. Unless this controller has just adopted or taken the pod, another controller is using
    /// it: see `foreignSessionDetectedAt`. Returns whether another controller may have run the pod.
    mutating func resolveAfterSessionResync() -> Bool {
        guard sharedWithAnotherController else { return false }
        resolveAfterForeignControl(dropInFlight: false)
        if !expectsSessionResync {
            let now = Date()
            foreignSessionDetectedAt = now
            if supersedingTake?.covers() != true {
                refusesSessions = true
            }
        }
        return true
    }

    // MARK: Handshakes (BlePodComms.establishNewSession)

    /// The EAP SQN for this controller's next handshake; nil while it refuses sessions.
    mutating func nextHandshakeSqn() -> Int? {
        refusesSessions ? nil : incrementEapSeq()
    }

    /// The pod answered a handshake with its own counter. At or below the last handshake the pod accepted
    /// from this controller (`AcceptedEapSqn`, saved at once, unlike this state), only this controller's own
    /// counter was behind. Returns whether another controller may have run the pod.
    mutating func handshakeResynced(to podSqn: Int, lastAcceptedHere: Int?) -> Bool {
        bleMessageTransportState.eapSeq = podSqn
        if let lastAcceptedHere, podSqn <= lastAcceptedHere {
            return false
        }
        return resolveAfterSessionResync()
    }

    /// A handshake established a session.
    mutating func sessionEstablished() {
        expectsSessionResync = false
    }
}

/// A superseding take's scope. Within one boot it ends by `CLOCK_MONOTONIC_RAW`, which counts sleep and which a
/// clock change can't stretch; across a reboot it falls back to the wall clock, and a clock set back before the
/// take ends it.
struct SupersedingTake: RawRepresentable, Equatable, CustomStringConvertible {
    typealias RawValue = [String: Any]

    let since: Date
    let until: Date
    let monotonicAtTake: TimeInterval
    let bootSession: String?

    init(until: Date, now: Date = Date(), monotonic: TimeInterval = SupersedingTake.monotonicNow(),
         bootSession: String? = SupersedingTake.currentBootSession) {
        self.since = now
        self.until = until
        self.monotonicAtTake = monotonic
        self.bootSession = bootSession
    }

    func covers(now: Date = Date(), monotonic: TimeInterval = SupersedingTake.monotonicNow(),
                bootSession: String? = SupersedingTake.currentBootSession) -> Bool {
        if let bootSession, bootSession == self.bootSession {
            let elapsed = monotonic - monotonicAtTake
            return elapsed >= 0 && elapsed < until.timeIntervalSince(since)
        }
        return since <= now && now < until
    }

    /// Seconds since boot, asleep or awake (`systemUptime` stops while the device sleeps).
    static func monotonicNow() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    static var currentBootSession: String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    init?(rawValue: RawValue) {
        guard let since = rawValue["since"] as? Date, let until = rawValue["until"] as? Date,
              let monotonicAtTake = rawValue["monotonicAtTake"] as? TimeInterval else { return nil }
        self.since = since
        self.until = until
        self.monotonicAtTake = monotonicAtTake
        self.bootSession = rawValue["bootSession"] as? String
    }

    var rawValue: RawValue {
        var raw: RawValue = ["since": since, "until": until, "monotonicAtTake": monotonicAtTake]
        raw["bootSession"] = bootSession
        return raw
    }

    var description: String { "\(since) – \(until)" }
}

extension PodComms {

    /// Drops this controller's handle for the pod; the manager's state follows through the delegate.
    func forgetHandle() {
        podStateLock.lock()
        podState?.bleIdentifier = nil
        podStateLock.unlock()
    }

    /// See PodState.sharedWithAnotherController. Once per pod; waits out a session in progress,
    /// like an insulin type change.
    func markSharedWithAnotherController() {
        podStateLock.lock()
        podState?.sharedWithAnotherController = true
        podStateLock.unlock()
    }

    /// A take: the next resync shows the other controller's sessions before it. Only a dated take (`until` set)
    /// also lifts a refusal, and starts a scope if `until` is still ahead; a plain one leaves both as they are.
    /// Waits out a session in progress.
    func expectSessionResync(supersedingAnotherControllerUntil until: Date?) {
        podStateLock.lock()
        podState?.expectsSessionResync = true
        if let until {
            podState?.foreignSessionDetectedAt = nil
            podState?.refusesSessions = false
            podState?.supersedingTake = until > Date() ? SupersedingTake(until: until) : nil
        }
        podStateLock.unlock()
    }

    /// The superseded controller has stopped, or this one let the pod go: a foreign session stops it again.
    /// Waits out a session in progress.
    func stopSupersedingAnotherController() {
        podStateLock.lock()
        podState?.supersedingTake = nil
        podStateLock.unlock()
    }
}

// MARK: - Exclusive control

extension OmniPumpManager: ExclusiveDeviceControl {

    public var isControlReleased: Bool {
        state.podConnectionReleased
    }

    /// Stops bidding for the pod's one BLE connection; pod state, pairing and keys are kept.
    /// Copies of a bolus or temp basal still in flight now belong to the controller taking over.
    /// Refused while a command to the pod is unconfirmed: the export leaves it out, so the controller
    /// taking over would book nothing from it. The host reads `isControlReleased` to see the refusal.
    public func releaseControl() {
        guard state.mayReleaseControl else {
            let sending = state.podState?.unacknowledgedCommand?.isInFlight == true
            omnipodLogDeviceEvent("[release] refused — the pod has not confirmed the last command (\(sending ? "still being sent" : "answer lost")); control kept")
            return
        }
        setState { $0.releaseControl() }
        (podComms as? BlePodComms)?.releaseConnection()
        // letting the pod go ends a superseding take
        podComms.stopSupersedingAnotherController()

        // A saved handle that never connected is wrong: drop it from the pod state, so
        // `localState` goes nil and the next adopt searches.
        if let unproven = connectClock?.adoptedHandleThatNeverConnected() {
            podComms.forgetHandle()
            omnipodLogDeviceEvent("saved handle \(unproven) never connected — forgotten; the next adopt searches")
        }
    }

    /// Lifts a release, then connects: by the handle this device has, or by the search an adopted
    /// manager needs. It connects with or without a release here: another controller can take the pod
    /// without this one releasing it (a watch's offline start), and the take's settle waits for this
    /// link.
    public func takeControl() {
        takeControl(supersedingAnotherControllerUntil: nil)
    }

    /// With a date, the host has taken the pod, at the user's request, from a controller that may not know yet:
    /// until then (`SupersedingTake`), `stopSupersedingAnotherController()` or a release, that controller's
    /// sessions are reported (`foreignSessionDetectedAt`) but don't stop this one. Only one side of a pairing
    /// may ever take with a date (in Trio, the phone): two scopes in opposite directions would let both command.
    /// A dated take lifts a refusal (`refusesSessions`); so does `takeControlLiftingRefusal()`, without a scope.
    /// Without a date, a refusal and a scope stay as they are, a refused manager stays off the radio, and the
    /// next resync is expected only if this controller had released the pod. Call it off the main thread: it
    /// waits out a session in progress.
    public func takeControl(supersedingAnotherControllerUntil until: Date?) {
        if until == nil, state.podState?.refusesSessions == true {
            omnipodLogDeviceEvent("[trust] plain take of a refused pod: stays refused and off the radio")
            return
        }
        if until != nil, let pod = state.podState, pod.refusesSessions || pod.supersedingTake != nil {
            omnipodLogDeviceEvent("[trust] superseding take: \(pod.refusesSessions ? "refusal lifted" : "scope replaced")")
        }
        if until != nil || state.podConnectionReleased {
            podComms.expectSessionResync(supersedingAnotherControllerUntil: until)
        }
        if state.podConnectionReleased {
            resumeControl()
        }
        guard let ble = podComms as? BlePodComms else { return }
        if takeControlNeedsSearch, let address = state.podState?.address {
            ble.beginTakeoverSearch(podId: address)
        } else {
            ble.rearmConnection()
        }
        // A take whose pod has not answered by then goes looking for it by address, until it
        // answers or control is released. The pod's first answer (a session established) cancels
        // the pending escalation and ends an armed one; a link dropped after it does not count.
        // A take of a pod already connected has its answer: nothing to wait for.
        if !isControlReady, let address = state.podState?.address {
            ble.scheduleTakeEscalation(podId: address, after: Self.takeEscalateAfter) { [weak self] in
                guard let self, !self.isControlReleased, !self.isControlReady else { return nil }
                return self.connectionDiagnostics()
            }
        }
    }

    /// How long a take waits for the pod's answer before it scans for the pod by address.
    static let takeEscalateAfter: TimeInterval = 12

    /// Lifts the release (see PodState.resolveAfterForeignControl).
    private func resumeControl() {
        connectClock?.beginAttempt(adoptedHandle: nil)
        (podComms as? BlePodComms)?.resolveAfterForeignControl(dropInFlight: state.inFlightDosesInheritedAway)
        setState { state in
            state.podConnectionReleased = false
            state.inFlightDosesInheritedAway = false
        }
    }

    /// When another controller was last found using the pod after this one adopted or took it. Each one
    /// updates the state, so the host is told every time.
    public var foreignSessionDetectedAt: Date? {
        state.podState?.foreignSessionDetectedAt
    }

    /// After a foreign session outside a superseding take, this manager runs no session, sends the pod
    /// nothing and lets go of its link, until the host takes control with a date.
    public var refusesSessions: Bool {
        state.podState?.refusesSessions ?? false
    }

    /// Lifts a refusal without superseding anyone, at the user's request, when the other controller is known to
    /// have stopped, and takes control. A later foreign session stops this controller again. Call it off the
    /// main thread: it waits out a session in progress.
    public func takeControlLiftingRefusal() {
        takeControl(supersedingAnotherControllerUntil: .distantPast)
    }

    /// The superseded controller has acknowledged that it stopped. Call it off the main thread: it waits out
    /// a session in progress.
    public func stopSupersedingAnotherController() {
        podComms.stopSupersedingAnotherController()
    }

    public var isControlReady: Bool {
        // A mocked pod has no radio, so no peripheral ever connects; any pod counts as ready.
        if mocksPod { return state.podState != nil }
        return (podComms as? BlePodComms)?.manager?.peripheral.state == .connected
    }

    /// The BLE layer's connect clock; nil for a pod without one (Eros).
    var connectClock: ConnectClock? { (podComms as? BlePodComms)?.bluetoothManager?.connectClock }

    /// What the link has been doing, for the device log.
    func connectionDiagnostics() -> String? {
        guard let ble = (podComms as? BlePodComms)?.bluetoothManager else { return nil }
        return "\(ble.loanBleDiagnostics) pod=\(peripheralStateDescription) · \(ble.connectClock.summary(since: ble.connectClock.attemptStartedAt))"
    }

    var takeControlNeedsSearch: Bool {
        podComms is BlePodComms && state.podState != nil && state.podState?.bleIdentifier == nil
    }

    /// An adopter searches for a BLE pod unless `localState` holds this controller's handle for it.
    public static func takeControlNeedsSearch(adopting configuration: SharedDeviceConfiguration, localState: [String: Any]?) -> Bool {
        guard let shared = OmniPumpManagerState(rawValue: configuration.state),
              shared.podType == dashType || shared.podType == omnipod5Type,
              let pod = shared.podState else { return false }
        return OmniPumpManagerState.handle(in: localState, forPodAddress: pod.address) == nil
    }


    /// The pod peripheral's CoreBluetooth state, for diagnostics.
    var peripheralStateDescription: String {
        guard let peripheral = (podComms as? BlePodComms)?.manager?.peripheral else {
            return "no-peripheral"
        }
        switch peripheral.state {
        case .disconnected:  return "disconnected"
        case .connecting:    return "connecting"
        case .connected:     return "connected"
        case .disconnecting: return "DISCONNECTING(wedged?)"
        @unknown default:    return "unknown(\(peripheral.state.rawValue))"
        }
    }
}

// MARK: - Ending a faulted pod

extension OmniPumpManager {

    /// A faulted pod alarms until it is deactivated, and only the controller holding it can do that.
    public var failedDeviceDeactivationTitle: String? {
        guard state.podState?.fault != nil else { return nil }
        return LocalizedString("Deactivate Pod", comment: "Action that deactivates a faulted pod from the controller holding it")
    }

    /// The pod settings' Deactivate Pod: deactivate, then forget the pod, booking its end here.
    public func deactivateFailedDevice() async throws {
        let error: OmniPumpManagerError? = await withCheckedContinuation { done in
            DispatchQueue.main.async { self.deactivatePod { done.resume(returning: $0) } }
        }
        if let error { throw error }
        await withCheckedContinuation { done in
            DispatchQueue.main.async { self.forgetPod { done.resume() } }
        }
    }

    /// The controller that ended the pod booked its last delivery: this copy's in-flight doses are
    /// dropped as at a take-back, and the pod is forgotten without booking a discard.
    public func forgetDeviceDeactivatedElsewhere() async {
        guard state.podState != nil, state.podConnectionReleased else { return }
        (podComms as? BlePodComms)?.resolveAfterForeignControl(dropInFlight: state.inFlightDosesInheritedAway)
        setState { state in
            state.podConnectionReleased = false
            state.inFlightDosesInheritedAway = false
        }
        omnipodLogDeviceEvent("[release] the pod was deactivated by another controller; forgotten here")
        await withCheckedContinuation { done in
            DispatchQueue.main.async { self.forgetPod(bookingDiscardedDosing: false) { done.resume() } }
        }
    }
}

// MARK: - Delivered-total odometer

extension OmniPumpManager: PumpDeliveryOdometer {

    public var deliveredUnits: (units: Double, at: Date)? {
        guard let measured = state.podState?.lastInsulinMeasurements else { return nil }
        return (measured.delivered, measured.validTime)
    }

    public var deliveryPulseUnits: Double { Pod.pulseSize }

    /// A faulted pod delivers nothing more, and its fault carried its last total.
    public var deliveredUnitsAreFinal: Bool { state.podState?.fault != nil }

    /// From the pod's own status, so it includes a bolus another controller started.
    public var bolusUnderWayEndsAt: Date? {
        guard let endsAt = state.podState?.reportedBolusEndsAt, endsAt > Date() else { return nil }
        return endsAt
    }

    /// A real status read, bypassing the freshness shortcut in ensureCurrentPumpData.
    public func refreshDeliveredUnits() async -> Bool {
        // A mocked pod has no radio: fake the round-trip and stamp a measurement, as jumpStartPod does.
        if mocksPod {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            setState { state in
                if state.podState?.lastInsulinMeasurements == nil {
                    var pod = state.podState
                    let delivered = pod?.setupUnitsDelivered ?? Pod.primeUnits
                    pod?.lastInsulinMeasurements = PodInsulinMeasurements(
                        insulinDelivered: delivered, reservoirLevel: nil, validTime: Date())
                    state.updatePodStateFromPodComms(pod)
                }
            }
            log.default("refreshDeliveredUnits simulated OK (mocked pod, no radio)")
            return true
        }
        return await withCheckedContinuation { done in
            getPodStatus(canOptimize: false) { result in
                if case .success(let status) = result, status != nil {
                    done.resume(returning: true)
                } else {
                    done.resume(returning: false)
                }
            }
        }
    }
}

// MARK: - Connect clock

/// CoreBluetooth's connect and disconnect edges, stamped as they happen, so a host polling on a
/// deferred timer can tell "connected late" from "looked late". Observation only. One per
/// `BluetoothManager`, so an adopt, release and re-adopt never reads another manager's attempt.
final class ConnectClock {
    private let lock = NSLock()
    private var _lastConnectAt: Date?
    private var _lastDisconnectAt: Date?
    private var _connectCount = 0
    private var _lastReason: String?
    private var _reasons: [String] = []
    /// Kept apart from `_lastReason`: a retry storm floods failures and would evict the one
    /// reason an established link died for.
    private var _lastDisconnectReason: String?
    private var _attemptStartedAt: Date?
    private var _adoptedHandle: String?

    /// When the current take began: at adopt, or at a take after a release.
    var attemptStartedAt: Date? { lock.lock(); defer { lock.unlock() }; return _attemptStartedAt }
    var connectCount: Int { lock.lock(); defer { lock.unlock() }; return _connectCount }

    func beginAttempt(adoptedHandle: String?) {
        lock.lock()
        _lastConnectAt = nil; _lastDisconnectAt = nil; _connectCount = 0
        _lastReason = nil; _reasons = []; _lastDisconnectReason = nil
        _attemptStartedAt = Date()
        _adoptedHandle = adoptedHandle
        lock.unlock()
    }

    /// The handle this attempt's adopt attached from `localState`, if it never connected. Once per
    /// attempt; the caller drops it.
    func adoptedHandleThatNeverConnected() -> String? {
        lock.lock()
        let adopted = _adoptedHandle, connected = _connectCount > 0
        _adoptedHandle = nil
        lock.unlock()
        guard let adopted, !connected else { return nil }
        return adopted
    }

    /// CoreBluetooth's reason a link ended; nil means this process cancelled it.
    private func describe(_ error: Error?) -> String {
        guard let error = error else { return "reason=nil(local-cancel?)" }
        let ns = error as NSError
        return "reason=\(ns.domain)#\(ns.code)"
    }

    func noteConnect(appState: String) {
        lock.lock()
        _lastConnectAt = Date(); _connectCount += 1
        _reasons.append("+\(_connectCount)@\(appState)")
        if _reasons.count > 12 { _reasons.removeFirst() }
        lock.unlock()
    }

    func noteDisconnect(error: Error?, appState: String) {
        let d = describe(error)
        lock.lock()
        _lastDisconnectAt = Date(); _lastDisconnectReason = d
        _reasons.append("-\(d)@\(appState)")
        if _reasons.count > 12 { _reasons.removeFirst() }
        lock.unlock()
    }

    func noteFailToConnect(error: Error?, appState: String) {
        let d = describe(error)
        lock.lock()
        _lastReason = d
        _reasons.append("x\(d)@\(appState)")
        if _reasons.count > 12 { _reasons.removeFirst() }
        lock.unlock()
    }

    /// One field for a log line, relative to the attempt's start: the flap trail with each edge's
    /// reason and the app state it fired in.
    func summary(since start: Date?) -> String {
        lock.lock()
        let c = _lastConnectAt, d = _lastDisconnectAt, n = _connectCount
        let r = _lastReason, trail = _reasons, dr = _lastDisconnectReason
        lock.unlock()
        guard let start = start else { return "cb: (no anchor)" }
        func rel(_ t: Date?) -> String { t.map { String(format: "+%.1fs", $0.timeIntervalSince(start)) } ?? "never" }
        let why = r.map { " · lastFail=\($0)" } ?? ""
        let dwhy = dr.map { " · lastDrop=\($0)" } ?? ""
        let tr = trail.isEmpty ? "" : " · trail[\(trail.joined(separator: " "))]"
        return "cb: didConnect \(rel(c)) (n=\(n)) · didDisconnect \(rel(d))\(dwhy)\(why)\(tr)"
    }
}
