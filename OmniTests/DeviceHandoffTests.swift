//
//  DeviceHandoffTests.swift
//  OmniTests
//
//  The hand-off contract as OmnipodKit keeps it: what an export leaves out, what an adopter
//  inherits, what a released controller drops when it takes control back, and that delivery
//  this manager did not command is never booked under a new identity.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import LoopKit
import RileyLinkBLEKit
@testable import OmnipodKit

final class DeviceHandoffTests: XCTestCase {

    let address: UInt32 = 0x17A6219A
    let ltk = Data(hexadecimalString: "fedcba98765432100123456789abcdef")!
    let bolusStart = Date(timeIntervalSinceNow: -30)
    let measuredAt = Date(timeIntervalSinceNow: -60)
    let watchHandle = "0B1D2C3E-0000-4000-8000-00000000B002"

    /// What an adopter that met this pod before saved: its own handle for it.
    var watchLocalState: [String: Any] { ["podAddress": address, "bleIdentifier": watchHandle] }

    /// A DASH pod mid-session: a handle, live session keys, a pending command and a bolus running.
    func makePodState() -> PodState {
        var pod = PodState(address: address, firmwareVersion: "4.10.0", iFirmwareVersion: "1.1.0",
                           lotNo: 43620, lotSeq: 560313, insulinType: .novolog, podType: dashType,
                           bleMessageTransportState: BleMessageTransportState(
                               ck: Data(repeating: 0xAB, count: 16), noncePrefix: Data(repeating: 0xCD, count: 8),
                               eapSeq: 41, msgSeq: 7, nonceSeq: 9, messageNumber: 3),
                           ltk: ltk, bleIdentifier: "0B1D2C3E-0000-4000-8000-00000000A001")
        pod.setupProgress = .completed
        pod.unfinalizedBolus = UnfinalizedDose(decisionId: nil, bolusAmount: 2.0, startTime: bolusStart,
                                               scheduledCertainty: .certain, insulinType: .novolog)
        pod.unacknowledgedCommand = .stopProgram(.tempBasal, 3, Date(), false)
        pod.lastInsulinMeasurements = PodInsulinMeasurements(insulinDelivered: 12.35, reservoirLevel: nil,
                                                             validTime: measuredAt)
        return pod
    }

    /// The manager's state. A manager itself cannot be built here: its BLE central needs a host
    /// app with the bluetooth-central background mode.
    func makeState(released: Bool = false, pod: PodState? = nil) -> OmniPumpManagerState {
        var state = OmniPumpManagerState(isOnboarded: true, podState: pod ?? makePodState(), timeZone: .current,
                                         basalSchedule: BasalSchedule(entries: [BasalScheduleEntry(rate: 1.0, startTime: 0, podType: dashType)]),
                                         maxBasalRateUnitsPerHour: 3, maxBolusUnits: 5, insulinType: .novolog,
                                         podType: dashType, podKeepAlive: .disabled,
                                         controllerId: 0x1234_5678, podId: 0x1234_5679)
        state.podConnectionReleased = released
        return state
    }

    func export(_ state: OmniPumpManagerState) -> SharedDeviceConfiguration {
        state.sharedConfiguration(managerIdentifier: "Omni")
    }

    func adopt(_ configuration: SharedDeviceConfiguration, localState: [String: Any]? = nil) throws -> OmniPumpManagerState {
        let raw = try XCTUnwrap(OmniPumpManager.adoptedRawState(from: configuration, localState: localState))
        return try XCTUnwrap(OmniPumpManagerState(rawValue: raw))
    }

    func exportedPod(_ configuration: SharedDeviceConfiguration) -> [String: Any]? {
        configuration.state["podState"] as? [String: Any]
    }

    // MARK: - Export

    func testExportLeavesOutLocalStateSessionMaterialAndThePendingCommand() {
        var state = makeState(released: true)
        state.configuredByAnotherController = true
        let configuration = export(state)
        let pod = exportedPod(configuration)
        let transport = pod?["bleMessageTransportState"] as? [String: Any]

        XCTAssertNil(pod?["bleIdentifier"], "the handle is this controller's")
        XCTAssertNotNil(state.localState, "it stays behind in this controller's local state")
        XCTAssertEqual(configuration.state["podConnectionReleased"] as? Bool, false, "the released flag is this controller's")
        XCTAssertEqual(configuration.state["configuredByAnotherController"] as? Bool, false)
        XCTAssertNil(pod?["unacknowledgedCommand"], "no pending command travels")
        XCTAssertEqual(transport?["ck"] as? String, "", "no session key travels")
        XCTAssertEqual(transport?["noncePrefix"] as? String, "", "no nonce prefix travels")
        XCTAssertEqual(transport?["nonceSeq"] as? Int, 0)
        XCTAssertEqual(transport?["msgSeq"] as? Int, 0)
    }

    func testExportKeepsTheFactsAboutThePod() {
        let configuration = export(makeState())
        let pod = exportedPod(configuration)
        let transport = pod?["bleMessageTransportState"] as? [String: Any]

        XCTAssertEqual(configuration.managerIdentifier, "Omni")
        XCTAssertEqual(pod?["address"] as? UInt32, address)
        XCTAssertEqual(pod?["ltk"] as? String, ltk.hexadecimalString)
        XCTAssertEqual(transport?["eapSeq"] as? Int, 41, "the pod resyncs the EAP sequence; it still travels")
        XCTAssertEqual(transport?["messageNumber"] as? Int, 3)
        XCTAssertNotNil(pod?["unfinalizedBolus"], "in-flight doses travel with the export")
        XCTAssertEqual(configuration.deliveredUnits, 12.35)
        XCTAssertEqual(configuration.asOf, measuredAt, "the total is as of its reading")
    }

    // MARK: - Adopt

    func testAdoptRoundTripsIdentityKeysAndInFlightDoses() throws {
        let exporter = makeState()
        let configuration = try XCTUnwrap(SharedDeviceConfiguration(rawValue: export(exporter).rawValue))

        let adopter = try adopt(configuration)
        let pod = try XCTUnwrap(adopter.podState)

        XCTAssertTrue(adopter.configuredByAnotherController)
        XCTAssertFalse(adopter.podConnectionReleased)
        XCTAssertEqual(pod.address, address)
        XCTAssertEqual(pod.ltk, ltk)
        XCTAssertEqual(adopter.controllerId, exporter.controllerId)
        XCTAssertEqual(adopter.podId, exporter.podId)
        XCTAssertNil(pod.unacknowledgedCommand)
        XCTAssertNil(pod.bleMessageTransportState.ck, "no session falls through from the exporter")
        XCTAssertNil(pod.bleMessageTransportState.noncePrefix)

        // The same dose reported under the same identity, from either manager.
        let theirs = NewPumpEvent(try XCTUnwrap(exporter.podState?.unfinalizedBolus))
        let ours = NewPumpEvent(try XCTUnwrap(pod.unfinalizedBolus))
        XCTAssertEqual(ours.raw, theirs.raw)
        XCTAssertEqual(ours.dose?.syncIdentifier, theirs.dose?.syncIdentifier)
    }

    /// A missing session key, saved and loaded, is still missing: an empty one would reach the pod's encryption.
    func testMissingSessionKeysSurviveASaveAndLoad() throws {
        let saved = BleMessageTransportState(ck: nil, noncePrefix: nil, eapSeq: 41, messageNumber: 3)
        let loaded = try XCTUnwrap(BleMessageTransportState(rawValue: saved.rawValue))
        XCTAssertNil(loaded.ck)
        XCTAssertNil(loaded.noncePrefix)
        XCTAssertEqual(loaded.eapSeq, 41)
    }

    func testAnAdopterThatNeverMetThePodSearches() throws {
        let adopter = try adopt(export(makeState()))
        XCTAssertNil(adopter.podState?.bleIdentifier, "the exporter's handle means nothing here")
    }

    func testAnAdopterThatMetThePodUsesItsOwnHandle() throws {
        let adopter = try adopt(export(makeState()), localState: watchLocalState)
        XCTAssertEqual(adopter.podState?.bleIdentifier, watchHandle)
        XCTAssertEqual(adopter.localState?["bleIdentifier"] as? String, watchHandle, "and hands it back to the host")
    }

    func testAHandleForAnotherPodIsIgnored() throws {
        let otherPod: [String: Any] = ["podAddress": address &+ 1, "bleIdentifier": watchHandle]
        XCTAssertNil(try adopt(export(makeState()), localState: otherPod).podState?.bleIdentifier)
        XCTAssertTrue(OmniPumpManager.takeControlNeedsSearch(adopting: export(makeState()), localState: otherPod))
    }

    func testTheLocalStateSurvivesAPropertyListRoundTrip() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: watchLocalState, format: .binary, options: 0)
        let saved = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(try adopt(export(makeState()), localState: saved).podState?.bleIdentifier, watchHandle)
    }

    /// Asked of a standing copy before Start: only a pod this controller holds no handle for.
    func testAnExportSaysWhetherAdoptingItWillSearch() {
        XCTAssertTrue(OmniPumpManager.takeControlNeedsSearch(adopting: export(makeState()), localState: nil))
        XCTAssertFalse(OmniPumpManager.takeControlNeedsSearch(adopting: export(makeState()), localState: watchLocalState))
        XCTAssertFalse(OmniPumpManager.takeControlNeedsSearch(
            adopting: SharedDeviceConfiguration(managerIdentifier: "Omni", asOf: Date(), state: [:]), localState: nil))
    }

    /// What `releaseControl()` does with an unproven handle, through the pod comms as it does it.
    func testAHandleThatNeverConnectedIsDroppedAtRelease() throws {
        var adopter = try adopt(export(makeState()), localState: watchLocalState)
        let podComms = PodComms(podState: adopter.podState, podType: dashType)
        let clock = ConnectClock()
        clock.beginAttempt(adoptedHandle: adopter.podState?.bleIdentifier)   // as `init(adopting:)` does
        XCTAssertEqual(clock.adoptedHandleThatNeverConnected(), watchHandle)
        podComms.forgetHandle()
        adopter.updatePodStateFromPodComms(podComms.podState)
        XCTAssertNil(adopter.localState, "the host saves nil, so the next adopt searches")
        XCTAssertTrue(OmniPumpManager.takeControlNeedsSearch(adopting: export(makeState()), localState: adopter.localState))
    }

    func testAHandleThatConnectedIsKept() throws {
        let adopted = try adopt(export(makeState()), localState: watchLocalState)
        let clock = ConnectClock()
        clock.beginAttempt(adoptedHandle: adopted.podState?.bleIdentifier)
        clock.noteConnect(appState: "fg")
        XCTAssertNil(clock.adoptedHandleThatNeverConnected())
    }

    func testAHandleFoundBySearchingIsNotDroppedAtRelease() throws {
        let adopted = try adopt(export(makeState()))
        let clock = ConnectClock()
        clock.beginAttempt(adoptedHandle: adopted.podState?.bleIdentifier)
        XCTAssertNil(clock.adoptedHandleThatNeverConnected(), "only a handle the adopt attached is on trial")
    }

    /// Each manager has its own clock: a re-adopt on the watch never reads the previous manager's attempt.
    func testEachManagersConnectClockIsItsOwn() {
        let first = ConnectClock(), second = ConnectClock()
        first.beginAttempt(adoptedHandle: watchHandle)
        second.beginAttempt(adoptedHandle: nil)
        second.noteConnect(appState: "fg")
        XCTAssertEqual(first.adoptedHandleThatNeverConnected(), watchHandle, "the second manager's connect is not the first's")
    }

    /// A command the pod has not confirmed, sent or still being sent, keeps the pod with this controller.
    func testControlIsNotReleasedWhileACommandIsUnconfirmed() {
        var pod = makePodState()
        pod.unacknowledgedCommand = .stopProgram(.tempBasal, 3, Date(), false)
        XCTAssertFalse(makeState(pod: pod).mayReleaseControl, "an answer that never arrived")
        pod.unacknowledgedCommand = .stopProgram(.tempBasal, 3, Date(), true)
        XCTAssertFalse(makeState(pod: pod).mayReleaseControl, "a command still being sent")
        pod.unacknowledgedCommand = nil
        XCTAssertTrue(makeState(pod: pod).mayReleaseControl)
    }

    func testAnAdopterBooksNoUntrackedBolusAsItsOwn() throws {
        var pod = makePodState()
        pod.unfinalizedBolus = nil
        var adopted = try XCTUnwrap(try adopt(export(makeState(pod: pod))).podState)

        adopted.updateFromStatusResponse(status(.bolusInProgress, bolusNotDelivered: 1.5))

        XCTAssertNil(adopted.unfinalizedBolus, "a bolus the adopter did not command gets no identity of its own")
    }

    // MARK: - Release and take

    func testReleaseHandsInFlightDosesToTheOtherController() {
        var state = makeState()
        state.releaseControl()

        XCTAssertTrue(state.podConnectionReleased)
        XCTAssertTrue(state.inFlightDosesInheritedAway)
        XCTAssertNotNil(state.podState?.unfinalizedBolus, "kept until take: nothing reports while released")
    }

    func testTakeDropsInFlightCopiesAndResolvesFromThePodsStatus() throws {
        var state = makeState()
        state.releaseControl()
        var pod = try XCTUnwrap(state.podState)
        pod.resolveAfterForeignControl(dropInFlight: state.inFlightDosesInheritedAway)

        XCTAssertNil(pod.unfinalizedBolus, "the frozen copy is dead")
        XCTAssertNil(pod.lastDeliveryStatusReceived, "read before writing")
        XCTAssertTrue(pod.untrackedDeliveryIsForeign)

        // The pod still bolusing (the other controller's bolus) books nothing here.
        pod.updateFromStatusResponse(status(.bolusInProgress, bolusNotDelivered: 0.8))
        XCTAssertNil(pod.unfinalizedBolus)
        XCTAssertTrue(pod.finalizedDoses.isEmpty, "nor is the dropped copy finalized from the frozen view")

        // Once the pod shows no bolus, this controller books its own again.
        pod.updateFromStatusResponse(status(.scheduledBasal))
        XCTAssertFalse(pod.untrackedDeliveryIsForeign)
    }

    /// A controller taking the pod back asks whether the pod is giving a bolus. Its own record has
    /// none (the other controller started it); the pod's status says so, and when it ends.
    func testAfterATakeThePodsStatusSaysWhenAnotherControllersBolusEnds() throws {
        var state = makeState()
        state.releaseControl()
        var pod = try XCTUnwrap(state.podState)
        pod.resolveAfterForeignControl(dropInFlight: state.inFlightDosesInheritedAway)
        XCTAssertNil(pod.reportedBolusEndsAt, "nothing known until the pod is read")

        let readAt = Date()
        pod.updateFromStatusResponse(status(.bolusInProgress, bolusNotDelivered: 0.8), at: readAt)
        XCTAssertNil(pod.unfinalizedBolus, "still not booked as this controller's")
        let endsAt = try XCTUnwrap(pod.reportedBolusEndsAt)
        XCTAssertEqual(endsAt.timeIntervalSince(readAt), 0.8 / Pod.bolusDeliveryRate, accuracy: 0.01, "the pod's own rate")

        pod.updateFromStatusResponse(status(.scheduledBasal))
        XCTAssertNil(pod.reportedBolusEndsAt, "finished")
    }

    func testAReleaseWithNothingInFlightKeepsTheFinishedRecords() throws {
        var pod = makePodState()
        pod.unfinalizedBolus = nil
        pod.finalizedDoses = [UnfinalizedDose(decisionId: nil, bolusAmount: 1.0, startTime: Date(timeIntervalSinceNow: -3600),
                                              scheduledCertainty: .certain, insulinType: .novolog)]
        var state = makeState(pod: pod)
        state.releaseControl()
        XCTAssertFalse(state.inFlightDosesInheritedAway)

        pod.resolveAfterForeignControl(dropInFlight: state.inFlightDosesInheritedAway)
        XCTAssertEqual(pod.finalizedDoses.count, 1, "finished doses are still this controller's to report")
    }

    func testTheHandOffFlagsSurviveARelaunch() throws {
        var state = makeState()
        state.releaseControl()
        state.configuredByAnotherController = true
        var pod = try XCTUnwrap(state.podState)
        pod.untrackedDeliveryIsForeign = true
        pod.sharedWithAnotherController = true
        state.updatePodStateFromPodComms(pod)

        let relaunched = try XCTUnwrap(OmniPumpManagerState(rawValue: state.rawValue))
        XCTAssertTrue(relaunched.podConnectionReleased)
        XCTAssertTrue(relaunched.inFlightDosesInheritedAway)
        XCTAssertTrue(relaunched.configuredByAnotherController)
        XCTAssertEqual(relaunched.podState?.untrackedDeliveryIsForeign, true)
        XCTAssertEqual(relaunched.podState?.sharedWithAnotherController, true)
    }

    // MARK: - Session resync

    func testExportingOrAdoptingMarksThePodShared() throws {
        let comms = PodComms(podState: makePodState(), podType: dashType)
        XCTAssertEqual(comms.podState?.sharedWithAnotherController, false)
        comms.markSharedWithAnotherController()
        XCTAssertEqual(comms.podState?.sharedWithAnotherController, true, "this controller handed out a copy")

        let adopted = try adopt(export(makeState()))
        XCTAssertEqual(adopted.podState?.sharedWithAnotherController, true, "this one started from a copy")
    }

    /// This controller's command was unconfirmed when another started from its copy. The pod's status
    /// now answers for the other controller's commands, so the command is dropped with nothing booked.
    func testOnASharedPodAResyncDropsTheUnconfirmedCommandAndBooksNothing() {
        var pod = makePodState()
        pod.unfinalizedBolus = nil
        pod.sharedWithAnotherController = true
        pod.unacknowledgedCommand = .program(.bolus(volume: 1.0, automatic: true), 5, Date(), false)
        pod.lastDeliveryStatusReceived = .scheduledBasal

        XCTAssertTrue(pod.resolveAfterSessionResync())

        XCTAssertNil(pod.unacknowledgedCommand, "nobody can settle it now")
        XCTAssertTrue(makeState(pod: pod).mayReleaseControl, "so it no longer keeps the pod")
        XCTAssertNil(pod.lastDeliveryStatusReceived, "read before writing")
        // The status a matching message number would once have taken as this controller's bolus.
        pod.updateFromStatusResponse(status(.bolusInProgress, bolusNotDelivered: 0.8))
        XCTAssertNil(pod.unfinalizedBolus, "the other controller's bolus is not booked here")
    }

    /// Normal looping: only this controller's own counter, saved late, can be behind, so the pod's
    /// status still settles the command, as before.
    func testOnAPodNeverSharedAResyncChangesNothing() {
        var pod = makePodState()
        pod.lastDeliveryStatusReceived = .scheduledBasal
        let before = pod

        XCTAssertFalse(pod.resolveAfterSessionResync())
        XCTAssertEqual(pod, before)
        XCTAssertNotNil(pod.unacknowledgedCommand)
    }

    // MARK: - Untracked delivery (stock behaviour unchanged)

    func testAnUntrackedBolusIsStillBookedWhenNoOtherControllerIsInPlay() {
        var pod = makePodState()
        pod.unfinalizedBolus = nil
        pod.updateFromStatusResponse(status(.bolusInProgress, bolusNotDelivered: 1.5))
        XCTAssertEqual(pod.unfinalizedBolus?.units, 1.5)
    }

    // MARK: - Key and handle

    func testTheKeyDecodesWithoutAHandle() throws {
        var raw = makePodState().rawValue
        raw.removeValue(forKey: "bleIdentifier")
        let pod = try XCTUnwrap(PodState(rawValue: raw))
        XCTAssertEqual(pod.ltk, ltk, "dropping the per-device handle must not drop the pod's key")
        XCTAssertNil(pod.bleIdentifier)
    }

    func testTheAdoptersKeyComesThroughAnExportWithNoHandle() throws {
        XCTAssertEqual(try adopt(export(makeState())).podState?.ltk, ltk)
    }

    // MARK: - Fault text for the host

    func faulted(code: UInt8) throws -> PodState {
        var pod = makePodState()
        let hex = String(format: "020d000000060000%02x000003ff0000000003a20386a0", code)
        pod.fault = try DetailedStatus(encodedData: Data(hexadecimalString: hex)!)
        return pod
    }

    func testTheFaultTextIsTheFaultAlarmsTitle() throws {
        XCTAssertNil(makePodState().localizedFaultDescription, "a working pod has no fault text")
        XCTAssertEqual(try faulted(code: 0x14).localizedFaultDescription, "Occlusion Detected")
        XCTAssertEqual(try faulted(code: 0x18).localizedFaultDescription, "Empty Reservoir")
        XCTAssertEqual(try faulted(code: 0x1C).localizedFaultDescription, "Pod Expired")
        XCTAssertEqual(try faulted(code: 0x8F).localizedFaultDescription, "Critical Pod Fault 143",
                       "the fault code the pod reported")
    }

    func testAFaultWithNoCodeStillHasText() {
        var pod = makePodState()
        pod.setupProgress = .activationTimeout
        XCTAssertEqual(pod.localizedFaultDescription, "Pod Error")
    }

    // MARK: - Foreign session

    /// A controller as the pod double sees it: its pod state, and the last handshake the pod accepted from
    /// it (`AcceptedEapSqn`, which survives a relaunch the saved pod state may not).
    struct Controller {
        var pod: PodState
        var lastAccepted: Int?
    }

    /// The pod's EAP counter and latest session keys, as the pod keeps them: a handshake has to be above the
    /// counter, or the pod answers with a resync and the handshake changes nothing; a message under other
    /// keys can't be decrypted. Every decision is PodState's, taken in the order
    /// `BlePodComms.establishNewSession` takes them.
    final class PodDouble {
        var sqn: Int
        var sessionKey = Data()
        init(sqn: Int) { self.sqn = sqn }

        /// One session by `controller`; true when it ran.
        func runSession(_ controller: inout Controller) -> Bool {
            for _ in 0 ..< 2 {
                guard let sent = controller.pod.nextHandshakeSqn() else { return false }
                if sent > sqn {
                    sqn = sent
                    sessionKey = Data(repeating: UInt8(truncatingIfNeeded: sent), count: 16)
                    controller.pod.bleMessageTransportState.ck = sessionKey
                    controller.pod.sessionEstablished()
                    controller.lastAccepted = sent
                    return true
                }
                _ = controller.pod.handshakeResynced(to: sqn, lastAcceptedHere: controller.lastAccepted)
            }
            return false
        }

        /// A message on a link that stayed up, under the keys the controller already has: no handshake.
        func acceptsWithoutHandshake(_ controller: Controller) -> Bool {
            controller.pod.bleMessageTransportState.ck == sessionKey
        }
    }

    let takeoverWindow: TimeInterval = .hours(6)

    /// Taking control, as `OmniPumpManager.takeControl(supersedingAnotherControllerUntil:)` does it to the pod.
    func take(_ pod: PodState, supersedingUntil until: Date?) throws -> PodState {
        let comms = PodComms(podState: pod, podType: dashType)
        comms.expectSessionResync(supersedingAnotherControllerUntil: until)
        return try XCTUnwrap(comms.podState)
    }

    func take(_ controller: Controller, supersedingUntil until: Date?) throws -> Controller {
        Controller(pod: try take(controller.pod, supersedingUntil: until), lastAccepted: controller.lastAccepted)
    }

    /// The phone hands the pod to the watch; both have run sessions on it since.
    func lend(_ pod: PodDouble) throws -> (phone: Controller, watch: Controller) {
        var phonePod = makePodState()
        phonePod.unacknowledgedCommand = nil
        let configuration = export(makeState(pod: phonePod))
        phonePod.sharedWithAnotherController = true // as exportConfiguration() marks it
        var phone = Controller(pod: phonePod)
        XCTAssertTrue(pod.runSession(&phone), "a session after the export, such as cancelling the temp")

        var watch = Controller(pod: try XCTUnwrap(try adopt(configuration).podState))
        XCTAssertTrue(pod.runSession(&watch), "the resync shows the phone's session before the hand-off")
        XCTAssertTrue(pod.runSession(&watch))
        XCTAssertNil(watch.pod.foreignSessionDetectedAt, "expected after an adopt")
        return (phone, watch)
    }

    var withinTheWindow: Date { Date().addingTimeInterval(takeoverWindow) }

    func testAHandOffAndAHandBackFindNoForeignSession() throws {
        let pod = PodDouble(sqn: 41)
        var (phone, watch) = try lend(pod)

        phone = try take(phone, supersedingUntil: nil) // the watch released it
        XCTAssertTrue(pod.runSession(&phone), "the resync shows the watch's sessions before the take")
        XCTAssertTrue(pod.runSession(&phone))
        XCTAssertNil(phone.pod.foreignSessionDetectedAt)
        XCTAssertNil(watch.pod.foreignSessionDetectedAt)
    }

    /// Take Back while the watch is out of reach: the watch doesn't know, and its next session finds the phone's.
    func testAControllerThatLostThePodRunsNoSessionAndSaysSo() throws {
        let pod = PodDouble(sqn: 41)
        var (phone, watch) = try lend(pod)
        phone = try take(phone, supersedingUntil: withinTheWindow)
        XCTAssertTrue(pod.runSession(&phone))

        let before = pod.sqn
        XCTAssertFalse(pod.runSession(&watch), "no session, so no command of any kind: not even a status read")
        XCTAssertNotNil(watch.pod.foreignSessionDetectedAt, "the host can see it")
        XCTAssertEqual(pod.sqn, before, "no second handshake: the phone's counter still leads")
        XCTAssertFalse(pod.runSession(&watch), "still refused, without touching the pod")

        XCTAssertTrue(pod.runSession(&phone), "the phone sees no foreign session")
        XCTAssertNil(phone.pod.foreignSessionDetectedAt)
    }

    /// The stale watch reaches the pod first after the phone's take. That one session can't be told apart from
    /// the watch's own, so it runs (the phone's audit has to find its insulin); the next is refused.
    func testTheStaleControllerHandshakingFirstAfterATakeIsRefusedFromItsNextSession() throws {
        let pod = PodDouble(sqn: 41)
        var (phone, watch) = try lend(pod)
        phone = try take(phone, supersedingUntil: withinTheWindow)

        XCTAssertTrue(pod.runSession(&watch), "a limit: nothing on the pod shows the take yet")
        XCTAssertTrue(pod.runSession(&phone), "the take expects the resync the watch's session causes")
        XCTAssertNil(phone.pod.foreignSessionDetectedAt)

        XCTAssertFalse(pod.runSession(&watch))
        XCTAssertNotNil(watch.pod.foreignSessionDetectedAt)
        XCTAssertTrue(pod.runSession(&phone))
        XCTAssertNil(phone.pod.foreignSessionDetectedAt, "the owner keeps dosing")
    }

    /// A session the phone didn't expect after its Take Back, from a peer the rule doesn't stop: reported, and
    /// the phone, which superseded that peer, keeps commanding. The host audits and alerts.
    func testAControllerThatSupersededAPeerReportsItsSessionAndKeepsCommanding() throws {
        let pod = PodDouble(sqn: 41)
        var (phone, _) = try lend(pod)
        phone = try take(phone, supersedingUntil: withinTheWindow)
        XCTAssertTrue(pod.runSession(&phone))
        XCTAssertNil(phone.pod.foreignSessionDetectedAt)

        pod.sqn += 1 // a session by the superseded peer
        XCTAssertTrue(pod.runSession(&phone), "not locked out")
        let first = try XCTUnwrap(phone.pod.foreignSessionDetectedAt, "but the host can see it")

        pod.sqn += 1
        XCTAssertTrue(pod.runSession(&phone))
        XCTAssertGreaterThan(try XCTUnwrap(phone.pod.foreignSessionDetectedAt), first, "every one is reported")
        XCTAssertFalse(phone.pod.refusesSessions)
    }

    /// The superseding take is scoped: after its window, once the peer has stopped, or with the clock set back
    /// before the take, a foreign session stops the phone too.
    func testASupersedingTakeStopsAtAForeignSessionOutsideItsScope() throws {
        let pod = PodDouble(sqn: 41)
        var (phone, _) = try lend(pod)
        phone = try take(phone, supersedingUntil: Date(timeIntervalSinceNow: -1)) // the window has passed
        XCTAssertTrue(pod.runSession(&phone))
        pod.sqn += 1
        XCTAssertFalse(pod.runSession(&phone))
        XCTAssertTrue(phone.pod.refusesSessions)
        XCTAssertNotNil(phone.pod.foreignSessionDetectedAt)

        phone = try take(phone, supersedingUntil: withinTheWindow)
        XCTAssertTrue(pod.runSession(&phone))
        let comms = PodComms(podState: phone.pod, podType: dashType)
        comms.stopSupersedingAnotherController() // the peer acknowledged that it stopped
        phone.pod = try XCTUnwrap(comms.podState)
        pod.sqn += 1
        XCTAssertFalse(pod.runSession(&phone))
        XCTAssertTrue(phone.pod.refusesSessions)

        phone = try take(phone, supersedingUntil: withinTheWindow)
        XCTAssertTrue(pod.runSession(&phone))
        // taken in another boot, with the clock since set back before the take
        phone.pod.supersedingTake = SupersedingTake(until: withinTheWindow.addingTimeInterval(.hours(1)),
                                                    now: Date(timeIntervalSinceNow: .hours(1)), monotonic: 0, bootSession: "another boot")
        pod.sqn += 1
        XCTAssertFalse(pod.runSession(&phone))
        XCTAssertTrue(phone.pod.refusesSessions)
    }

    /// The same session, seen by a controller that believed it held the pod alone (an ordinary hand-back).
    func testAControllerThatHeldThePodAloneStopsAtAForeignSession() throws {
        let pod = PodDouble(sqn: 41)
        var (phone, _) = try lend(pod)
        phone = try take(phone, supersedingUntil: nil)
        XCTAssertTrue(pod.runSession(&phone))

        pod.sqn += 1
        XCTAssertFalse(pod.runSession(&phone))
        XCTAssertNotNil(phone.pod.foreignSessionDetectedAt)
        XCTAssertTrue(phone.pod.refusesSessions)
    }

    /// The process ended after a handshake but before the host saved the pod state: the saved counter is behind
    /// the pod, through no other controller. The counter saved at the handshake tells the two apart.
    func testThisControllersOwnLateSavedCounterIsNotAForeignSession() throws {
        let pod = PodDouble(sqn: 41)
        var (_, watch) = try lend(pod)
        let savedByTheHost = watch.pod
        XCTAssertTrue(pod.runSession(&watch))

        var relaunched = Controller(pod: savedByTheHost, lastAccepted: watch.lastAccepted)
        XCTAssertTrue(pod.runSession(&relaunched))
        XCTAssertNil(relaunched.pod.foreignSessionDetectedAt)
        XCTAssertFalse(relaunched.pod.refusesSessions)

        var withoutTheSavedCounter = Controller(pod: savedByTheHost, lastAccepted: nil)
        XCTAssertFalse(pod.runSession(&withoutTheSavedCounter), "what the saved counter prevents")
    }

    /// A stale controller whose link stayed up never handshakes, so it never sees the resync. Its saved keys
    /// are the pod's old session's, and a message under them can't be decrypted (the pod-side half is this
    /// double's model, not a pod trace). A process on a shared pod never trusts saved keys
    /// (`BlePodComms.init`), so its next session handshakes, and the refusal stops it.
    func testKeysFromBeforeATakeoverOpenNothing() throws {
        let pod = PodDouble(sqn: 41)
        var (phone, watch) = try lend(pod)
        XCTAssertTrue(pod.acceptsWithoutHandshake(watch), "the watch's own session is the pod's latest")

        phone = try take(phone, supersedingUntil: withinTheWindow)
        XCTAssertTrue(pod.runSession(&phone))
        XCTAssertFalse(pod.acceptsWithoutHandshake(watch), "the phone's handshake replaced the keys")
        XCTAssertFalse(pod.runSession(&watch), "and a new handshake is refused")
    }

    /// The scope's own clock is `CLOCK_MONOTONIC_RAW`, which keeps counting while the device sleeps
    /// (`systemUptime` doesn't, and a mostly-asleep phone would stretch 6 h to days).
    func testTheScopeRunsOnAClockThatCountsSleep() {
        let before = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
        let take = SupersedingTake(until: Date().addingTimeInterval(takeoverWindow))
        let after = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
        XCTAssertGreaterThanOrEqual(take.monotonicAtTake, before)
        XCTAssertLessThanOrEqual(take.monotonicAtTake, after)
        XCTAssertTrue(take.covers())
        XCTAssertFalse(take.covers(monotonic: take.monotonicAtTake + takeoverWindow + 1),
                       "six hours on that clock end it, whatever the wall clock says")
    }

    /// Within one boot the scope runs on that clock, so a clock change can't stretch it; across a reboot it runs
    /// on the wall clock, and a clock set back before the take ends it.
    func testTheScopeSurvivesClockChanges() {
        let takenAt = Date()
        let take = SupersedingTake(until: takenAt.addingTimeInterval(takeoverWindow), now: takenAt, monotonic: 100, bootSession: "A")

        XCTAssertTrue(take.covers(now: takenAt.addingTimeInterval(.hours(1)), monotonic: 100 + .hours(1), bootSession: "A"))
        XCTAssertFalse(take.covers(now: takenAt.addingTimeInterval(.hours(1)), monotonic: 100 + .hours(7), bootSession: "A"),
                       "seven hours have passed, whatever the clock says")
        XCTAssertFalse(take.covers(now: takenAt.addingTimeInterval(.hours(1)), monotonic: 50, bootSession: "A"))

        XCTAssertTrue(take.covers(now: takenAt.addingTimeInterval(.hours(1)), monotonic: 5, bootSession: "B"))
        XCTAssertFalse(take.covers(now: takenAt.addingTimeInterval(-.hours(1)), monotonic: 5, bootSession: "B"))
        XCTAssertFalse(take.covers(now: takenAt.addingTimeInterval(.hours(7)), monotonic: 5, bootSession: "B"))
        XCTAssertTrue(take.covers(now: takenAt.addingTimeInterval(.hours(1)), monotonic: 5, bootSession: nil),
                      "no boot session: the wall clock decides")
        XCTAssertNotNil(SupersedingTake(rawValue: take.rawValue))
        XCTAssertEqual(SupersedingTake(rawValue: take.rawValue), take)
    }

    /// Lifting a refusal takes the explicit, superseding form; a plain take (a relaunch, a hand-back) keeps it,
    /// and keeps a scope too.
    func testOnlyASupersedingTakeLiftsARefusal() throws {
        var pod = makePodState()
        pod.sharedWithAnotherController = true
        XCTAssertTrue(pod.resolveAfterSessionResync())
        XCTAssertTrue(pod.refusesSessions)

        XCTAssertTrue(try take(pod, supersedingUntil: nil).refusesSessions)
        let superseding = try take(pod, supersedingUntil: withinTheWindow)
        XCTAssertFalse(superseding.refusesSessions)
        XCTAssertNotNil(try take(superseding, supersedingUntil: nil).supersedingTake)
    }

    func testTheRefusalSurvivesARelaunchAndATakeLiftsIt() throws {
        var pod = makePodState()
        pod.sharedWithAnotherController = true
        XCTAssertTrue(pod.resolveAfterSessionResync())
        let detectedAt = try XCTUnwrap(pod.foreignSessionDetectedAt)

        let relaunched = try XCTUnwrap(PodState(rawValue: pod.rawValue))
        XCTAssertEqual(relaunched.foreignSessionDetectedAt, detectedAt)
        XCTAssertTrue(relaunched.refusesSessions)

        let until = withinTheWindow
        let taken = try take(relaunched, supersedingUntil: until)
        XCTAssertNil(taken.foreignSessionDetectedAt, "taking control is the host's claim")
        XCTAssertFalse(taken.refusesSessions)
        let relaunchedAfterTake = try XCTUnwrap(PodState(rawValue: taken.rawValue))
        XCTAssertTrue(relaunchedAfterTake.expectsSessionResync)
        XCTAssertEqual(relaunchedAfterTake.supersedingTake?.until, until)
        XCTAssertEqual(relaunchedAfterTake.supersedingTake, taken.supersedingTake)
    }

    func testAnExportCarriesNoForeignSessionAndTheAdopterExpectsAResync() throws {
        var pod = makePodState()
        pod.foreignSessionDetectedAt = Date()
        pod.expectsSessionResync = true
        pod.supersedingTake = SupersedingTake(until: withinTheWindow)
        pod.refusesSessions = true
        let configuration = export(makeState(pod: pod))
        for key in ["foreignSessionDetectedAt", "expectsSessionResync", "supersedingTake", "refusesSessions"] {
            XCTAssertNil(exportedPod(configuration)?[key], key)
        }

        let adopted = try XCTUnwrap(try adopt(configuration).podState)
        XCTAssertTrue(adopted.expectsSessionResync)
        XCTAssertNil(adopted.foreignSessionDetectedAt)
        XCTAssertNil(adopted.supersedingTake, "an adopter holds the pod alone")
        XCTAssertFalse(adopted.refusesSessions)
    }

    // MARK: - Bounded adopt

    /// The phone releases the pod, then exports it, as Trio lends it.
    func releasedExport(_ pod: PodDouble) -> (phone: Controller, configuration: SharedDeviceConfiguration) {
        var phonePod = makePodState()
        phonePod.unacknowledgedCommand = nil
        phonePod.sharedWithAnotherController = true
        phonePod.bleMessageTransportState.eapSeq = pod.sqn
        return (Controller(pod: phonePod), export(makeState(released: true, pod: phonePod)))
    }

    /// The phone's superseding Take Back lands between the export and the watch adopt's first handshake. The
    /// adopt may only meet the sessions up to the release; the phone's new one is another controller's.
    func testAnAdoptRefusesASessionMadeAfterTheRelease() throws {
        let pod = PodDouble(sqn: 41)
        var (phone, configuration) = releasedExport(pod)

        phone = try take(phone, supersedingUntil: withinTheWindow)
        XCTAssertTrue(pod.runSession(&phone))

        var watch = Controller(pod: try XCTUnwrap(try adopt(configuration).podState))
        XCTAssertEqual(watch.pod.releasedEapSqn, 41)
        let before = pod.sqn
        XCTAssertFalse(pod.runSession(&watch), "the adopt doesn't absorb the phone's new session")
        XCTAssertTrue(watch.pod.refusesSessions)
        XCTAssertNotNil(watch.pod.foreignSessionDetectedAt)
        XCTAssertEqual(pod.sqn, before)

        XCTAssertTrue(pod.runSession(&phone))
        XCTAssertNil(phone.pod.foreignSessionDetectedAt, "the phone alone commands")
    }

    func testAnAdoptWithNothingAfterTheReleaseRuns() throws {
        let pod = PodDouble(sqn: 41)
        let (_, configuration) = releasedExport(pod)

        var watch = Controller(pod: try XCTUnwrap(try adopt(configuration).podState))
        XCTAssertTrue(pod.runSession(&watch))
        XCTAssertNil(watch.pod.foreignSessionDetectedAt)
        XCTAssertNil(watch.pod.releasedEapSqn, "spent with the first session")

        let relaunched = try XCTUnwrap(PodState(rawValue: try XCTUnwrap(try adopt(configuration).podState).rawValue))
        XCTAssertEqual(relaunched.releasedEapSqn, 41, "an adopt relaunched before its first session keeps the bound")
    }

    /// An export made before a release (#177's offline start) carries no bound: the adopt expects the resync.
    func testAnExportWithoutAReleaseCarriesNoBound() throws {
        let pod = PodDouble(sqn: 41)
        var phonePod = makePodState()
        phonePod.unacknowledgedCommand = nil
        phonePod.sharedWithAnotherController = true
        let configuration = export(makeState(released: false, pod: phonePod))
        var phone = Controller(pod: phonePod)
        XCTAssertTrue(pod.runSession(&phone))

        var watch = Controller(pod: try XCTUnwrap(try adopt(configuration).podState))
        XCTAssertNil(watch.pod.releasedEapSqn)
        XCTAssertTrue(pod.runSession(&watch))
        XCTAssertNil(watch.pod.foreignSessionDetectedAt)
    }

    // MARK: - The manager's refusal

    /// No RileyLink: a session that gets past `OmniPumpManager.runSession` fails for that instead.
    final class NoRileyLinks: RileyLinkDeviceProvider {
        weak var delegate: RileyLinkDeviceProviderDelegate?
        var idleListeningState: RileyLinkBluetoothDevice.IdleListeningState = .disabled
        var idleListeningEnabled = false
        var timerTickEnabled = false
        var connectingCount = 0
        func deprioritize(_ device: RileyLinkDevice, completion: (() -> Void)?) { completion?() }
        func assertIdleListening(forcingRestart: Bool) {}
        func getDevices(_ completion: @escaping ([RileyLinkDevice]) -> Void) { completion([]) }
        func connect(_ device: RileyLinkDevice) {}
        func disconnect(_ device: RileyLinkDevice) {}
        func setScanningEnabled(_ enabled: Bool) {}
        func shouldConnect(to deviceID: String) -> Bool { false }
        var debugDescription: String { "NoRileyLinks" }
    }

    /// The refusal lives in `OmniPumpManager.runSession`, the same for every pod type, so an Eros manager
    /// (no Bluetooth central to build) shows it. Eros pods never set it themselves.
    func makeManager(refusing: Bool) -> OmniPumpManager {
        var pod = PodState(address: address, firmwareVersion: "2.7.0", iFirmwareVersion: "2.7.0", lotNo: 43620,
                           lotSeq: 560313, insulinType: .novolog, podType: erosType)
        pod.setupProgress = .completed
        pod.sharedWithAnotherController = true
        pod.refusesSessions = refusing
        let state = OmniPumpManagerState(isOnboarded: true, podState: pod, timeZone: .current,
                                         basalSchedule: BasalSchedule(entries: [BasalScheduleEntry(rate: 1.0, startTime: 0, podType: erosType)]),
                                         maxBasalRateUnitsPerHour: 3, maxBolusUnits: 5, insulinType: .novolog,
                                         podType: erosType, podKeepAlive: .disabled,
                                         controllerId: 0x1234_5678, podId: 0x1234_5679)
        return OmniPumpManager(state: state, rileyLinkDeviceProvider: NoRileyLinks())
    }

    func statusError(_ manager: OmniPumpManager) -> Error? {
        let done = expectation(description: "status")
        var failure: Error?
        manager.getPodStatus { result in
            if case .failure(let error) = result, case .communication(let underlying) = error {
                failure = underlying
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return failure
    }

    func zeroTempError(_ manager: OmniPumpManager) -> Error? {
        let done = expectation(description: "zero temp")
        var failure: Error?
        manager.enactTempBasal(decisionId: nil, unitsPerHour: 0, for: .minutes(30)) { error in
            if case .communication(let underlying) = error {
                failure = underlying
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return failure
    }

    func isRefusal(_ error: Error?) -> Bool {
        if case .podUsedByAnotherController = error as? PodCommsError { return true }
        return false
    }

    func testARefusingManagerSendsThePodNothing() {
        let manager = makeManager(refusing: true)
        XCTAssertTrue(manager.refusesSessions)
        XCTAssertTrue(isRefusal(statusError(manager)), "not even a status read")
        XCTAssertTrue(isRefusal(zeroTempError(manager)), "nor a reduction")

        XCTAssertFalse(isRefusal(statusError(makeManager(refusing: false))), "the same manager, not refusing, gets to the radio")
    }

    func testOnlyASupersedingTakeLiftsTheManagersRefusalAndAReleaseEndsTheScope() {
        let manager = makeManager(refusing: true)
        manager.takeControl()
        XCTAssertTrue(manager.refusesSessions, "a plain take keeps it")
        XCTAssertTrue(isRefusal(statusError(manager)))

        manager.takeControl(supersedingAnotherControllerUntil: withinTheWindow)
        XCTAssertFalse(manager.refusesSessions)
        XCTAssertFalse(isRefusal(statusError(manager)))
        let scope = manager.state.podState?.supersedingTake
        XCTAssertNotNil(scope)

        manager.takeControl()
        XCTAssertEqual(manager.state.podState?.supersedingTake, scope, "a plain take inside the scope doesn't end it")

        manager.releaseControl()
        XCTAssertTrue(manager.isControlReleased)
        XCTAssertNil(manager.state.podState?.supersedingTake, "letting the pod go ends the take")
    }

    /// The manager's own export after a release carries the bound; one before a release doesn't.
    func testAReleasedManagersExportBoundsTheAdopt() throws {
        let manager = makeManager(refusing: false)
        let unbounded = try XCTUnwrap(OmniPumpManager.adoptedRawState(from: manager.exportConfiguration(), localState: nil))
        XCTAssertNil(OmniPumpManagerState(rawValue: unbounded)?.podState?.releasedEapSqn)

        manager.releaseControl()
        let sqn = try XCTUnwrap(manager.state.podState?.bleMessageTransportState.eapSeq)
        let bounded = try XCTUnwrap(OmniPumpManager.adoptedRawState(from: manager.exportConfiguration(), localState: nil))
        XCTAssertEqual(OmniPumpManagerState(rawValue: bounded)?.podState?.releasedEapSqn, sqn)
        XCTAssertNil(manager.state.podState?.releasedEapSqn, "the exporter's own state carries none")
    }

    /// A plain take leaves a refused manager where it is: still refused, still released, off the radio.
    func testAPlainTakeOfARefusedManagerStaysOffTheRadio() {
        let manager = makeManager(refusing: true)
        manager.releaseControl()
        XCTAssertTrue(manager.isControlReleased)
        manager.takeControl()
        XCTAssertTrue(manager.isControlReleased, "no re-arm, no search")
        XCTAssertTrue(manager.refusesSessions)
    }

    /// Lifting a refusal without superseding anyone starts no scope.
    func testLiftingARefusalStartsNoScope() {
        let manager = makeManager(refusing: true)
        manager.takeControlLiftingRefusal()
        XCTAssertFalse(manager.refusesSessions)
        XCTAssertNil(manager.state.podState?.supersedingTake)
        XCTAssertEqual(manager.state.podState?.expectsSessionResync, true)
    }

    /// A plain take by a controller that never let the pod go (a relaunch, a check) expects no resync: the
    /// next one is a foreign session, as it would be without the take.
    func testAPlainTakeWithoutAReleaseExpectsNoResync() {
        let manager = makeManager(refusing: false)
        manager.takeControl()
        XCTAssertEqual(manager.state.podState?.expectsSessionResync, false)

        manager.releaseControl()
        manager.takeControl()
        XCTAssertEqual(manager.state.podState?.expectsSessionResync, true, "taking back what it let go")
    }

    // MARK: -

    func status(_ deliveryStatus: DeliveryStatus, bolusNotDelivered: Double = 0) -> StatusResponse {
        StatusResponse(deliveryStatus: deliveryStatus, podProgressStatus: .aboveFiftyUnits, timeActive: .hours(10),
                       reservoirLevel: Pod.reservoirLevelAboveThresholdMagicNumber, insulinDelivered: 13,
                       bolusNotDelivered: bolusNotDelivered, lastProgrammingMessageSeqNum: 5, alerts: AlertSet(slots: []))
    }
}
