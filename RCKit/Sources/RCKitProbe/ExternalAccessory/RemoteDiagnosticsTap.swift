#if os(iOS)
import Foundation
import RCKit
import Synchronization

/// Feeds an `RCN3Remote`'s raw traffic into a `StreamAnalyzer` and the probe log, so the probe's
/// hex, changed-bytes and DUML views keep working while the app runs on the clean input API.
///
/// ```swift
/// let tap = RemoteDiagnosticsTap(log: log)
/// let remote = RCN3Remote(diagnostics: tap.handle)
/// ```
public final class RemoteDiagnosticsTap: Sendable {
    public static let sessionID = "rcn3remote"

    private struct State {
        var analyzer: StreamAnalyzer
        var remoteState: RCConnectionState = .stopped
        var openedAt = ProbeClock.now()
    }
    private let state: Mutex<State>
    private let log: ProbeLog
    private let protocolString: String

    public init(log: ProbeLog, protocolString: String = "com.dji.logiclink") {
        self.log = log
        self.protocolString = protocolString
        state = Mutex(State(analyzer: StreamAnalyzer(name: "\(protocolString) (RCN3Remote)")))
    }

    public func handle(_ event: RCN3Remote.DiagnosticEvent) {
        switch event {
        case let .received(bytes, time):
            _ = state.withLock { $0.analyzer.ingestIncoming(bytes, at: time, log: log) }
        case let .sent(bytes, note, frame, time):
            state.withLock { $0.analyzer.recordOutgoing(bytes, at: time, note: note, frame: frame, log: log) }
        case let .state(newState):
            state.withLock { s in
                if case .connecting = newState, !s.remoteState.isStreaming {
                    // A fresh connection: start a new analyzer so stats aren't mixed across sessions.
                    s.analyzer = StreamAnalyzer(name: s.analyzer.name)
                    s.openedAt = ProbeClock.now()
                }
                s.remoteState = newState
            }
            if let accessory = newState.accessory, case .connecting = newState {
                log.log(.ea, "RCN3Remote: \(newState.label) \(accessory.logDescription)")
            } else {
                log.log(.ea, "RCN3Remote: \(newState.label)")
            }
        }
    }

    /// The remote's traffic as a probe session snapshot (for the Streams and DUML views).
    public func snapshot() -> AccessoryStreamSession.Snapshot {
        let now = ProbeClock.now()
        return state.withLock { s in
            s.analyzer.refreshRates(at: now)
            let sessionState: AccessoryStreamSession.State = switch s.remoteState {
            case .streaming, .connecting: .open
            case let .failed(reason): .failed(reason)
            default: .closed(s.remoteState.label)
            }
            return AccessoryStreamSession.Snapshot(
                id: Self.sessionID, accessoryID: s.remoteState.accessory?.connectionID ?? 0,
                accessoryName: s.remoteState.accessory?.name ?? "RC-N3", protocolString: protocolString,
                state: sessionState, openedAt: s.openedAt, inputOpen: sessionState == .open, outputOpen: sessionState == .open,
                pendingWriteBytes: 0, poll: nil, pollTimeouts: 0, analyzer: s.analyzer)
        }
    }

    public func resetDiffBaselines() {
        state.withLock { $0.analyzer.resetDiffBaselines() }
    }
}
#endif
