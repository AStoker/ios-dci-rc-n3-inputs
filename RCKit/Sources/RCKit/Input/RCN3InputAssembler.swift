/// Turns RC-N3 DUML frames into `RCInputSample`s. Pure logic, no I/O, so it's unit-tested.
///
/// Two inputs (hardware test 2):
/// - **06/01 replies** to our poll: sticks + gimbal, refreshed by the remote at ~50-60 Hz.
///   A reply whose values changed becomes a sample; repeats are dropped.
/// - **06/05 pushes** (~7-9/s): flight mode switch and buttons (plus sticks). While polling is
///   fresh, a push only produces a sample when the mode or buttons changed. If no poll reply has
///   arrived for `pollStaleAfter`, pushes drive the sticks too.
struct RCN3InputAssembler: Sendable {
    static let pollStaleAfter: Double = 0.25

    private(set) var index: UInt64 = 0
    private var push: RCPushParams?
    /// 06/01 channels 0-4: right X, right Y, left Y, left X, gimbal.
    private var pollChannels: [UInt16]?
    private var pollTime = -Double.infinity
    private var hasEmitted = false

    mutating func ingest(_ frame: DUMLFrame, at time: Double) -> RCInputSample? {
        switch (frame.commandSet, frame.commandID, frame.isResponse) {
        case (0x06, 0x05, false):
            guard let params = RCPushParams(payload: frame.payload) else { return nil }
            let previous = push
            push = params
            if time - pollTime < Self.pollStaleAfter, let pollChannels {
                let unchanged = previous?.buttonsA == params.buttonsA && previous?.buttonsB == params.buttonsB
                return unchanged ? nil : emit(pollChannels, time: time, source: .push)
            }
            return emit([params.aileron, params.elevator, params.throttle, params.rudder, params.gimbal],
                        time: time, source: .push)

        case (0x06, 0x01, true):
            guard let report = RCChannelReport(payload: frame.payload), report.status == 0,
                  report.channels.count >= 5 else { return nil }
            let channels = report.channels.prefix(5).map(\.raw)
            pollTime = time
            if hasEmitted, channels == pollChannels { return nil }
            pollChannels = channels
            return emit(channels, time: time, source: .poll)

        default:
            return nil
        }
    }

    /// `channels` in 06/01 order: right X, right Y, left Y, left X, gimbal.
    private mutating func emit(_ channels: [UInt16], time: Double, source: RCSampleSource) -> RCInputSample {
        var buttons: RCButtons = []
        if let push {
            if push.goHomePressed { buttons.insert(.pauseRTH) }
            if push.shutter { buttons.insert(.shutterRecord) }
            if push.photoVideo { buttons.insert(.photoVideo) }
            if push.custom1 { buttons.insert(.customizableTap) }
            if push.custom2 { buttons.insert(.customizableDoubleTap) }
        }
        let raw = RCRawInput(leftX: channels[3], leftY: channels[2], rightX: channels[0], rightY: channels[1],
                             gimbal: channels[4], flagsA: push?.buttonsA ?? 0, flagsB: push?.buttonsB ?? 0)
        let sample = RCInputSample(time: time, index: index, raw: raw,
                                   flightMode: push?.flightMode ?? .unknown, buttons: buttons, source: source)
        index += 1
        hasEmitted = true
        return sample
    }
}
