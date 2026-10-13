import Foundation
import CryptoKit

/// Evidence from a real permission request, not a self-ping or a toggle in our UI.
/// Only the digest and the last completed check survive a restart. Commands,
/// tokens, session IDs and project paths are never saved here.
struct HookVerification {
    enum Phase: String { case notInstalled, unverified, waiting, received, replied, verified, timedOut, interrupted, failed }
    struct Saved: Codable {
        let digest: String
        let verifiedAt: Date
    }
    private struct Attempt {
        let id: UUID
        let sessionID: String
        let receivedAt: Date
        let baseline: Date?
        var repliedAt: Date?
    }

    private(set) var digest: String?
    private(set) var verifiedAt: Date?
    private(set) var checkingSince: Date?
    private var attempt: Attempt?
    private var failure: Phase?
    static let wait: TimeInterval = 120
    static let evidenceLifetime: TimeInterval = 86400

    init(saved: Saved? = nil) {
        digest = saved?.digest
        verifiedAt = saved?.verifiedAt
    }

    var saved: Saved? {
        guard let digest, let verifiedAt, checkingSince == nil, failure == nil else { return nil }
        return Saved(digest: digest, verifiedAt: verifiedAt)
    }

    mutating func configure(_ current: String?) {
        guard digest != current else { return }
        self = HookVerification()
        digest = current
    }

    mutating func invalidate() {
        let current = digest
        self = HookVerification()
        digest = current
    }

    func phase(now: Date = Date()) -> Phase {
        guard digest != nil else { return .notInstalled }
        if let failure { return failure }
        if let verifiedAt, checkingSince == nil, now >= verifiedAt,
           now.timeIntervalSince(verifiedAt) < Self.evidenceLifetime { return .verified }
        if let attempt {
            let start = attempt.repliedAt ?? attempt.receivedAt
            if now.timeIntervalSince(start) >= Self.wait { return .timedOut }
            return attempt.repliedAt == nil ? .received : .replied
        }
        if let checkingSince { return now.timeIntervalSince(checkingSince) < Self.wait ? .waiting : .timedOut }
        return .unverified
    }

    mutating func begin(now: Date = Date()) {
        guard digest != nil else { return }
        checkingSince = now
        attempt = nil
        failure = nil
    }

    mutating func received(id: UUID, sessionID: String, baseline: Date? = nil, now: Date = Date()) {
        guard digest != nil, !sessionID.isEmpty else { return }
        attempt = Attempt(id: id, sessionID: sessionID, receivedAt: now, baseline: baseline)
        failure = nil
    }

    mutating func replied(id: UUID, success: Bool, now: Date = Date()) {
        guard attempt?.id == id else { return }
        if success { attempt?.repliedAt = now } else { failure = .failed; verifiedAt = nil; attempt = nil }
    }

    mutating func disconnected(id: UUID) {
        guard attempt?.id == id, attempt?.repliedAt == nil else { return }
        attempt = nil
        // The agent taking over a normal prompt is expected. It doesn't undo
        // an earlier successful check; an explicitly requested recheck is different.
        if verifiedAt != nil, checkingSince == nil { return }
        failure = .interrupted
    }

    func awaitingProgress(now: Date = Date()) -> Bool {
        guard let repliedAt = attempt?.repliedAt, failure == nil else { return false }
        return now.timeIntervalSince(repliedAt) < Self.wait
    }

    /// A matching transcript must advance *after* our reply, without another
    /// waiting/error state. Socket delivery alone does not confirm the agent acted.
    mutating func progressed(sessionID: String, since: Date, runningOrDone: Bool, now: Date = Date()) {
        guard let attempt, let repliedAt = attempt.repliedAt, attempt.sessionID == sessionID,
              runningOrDone, since > repliedAt, since > (attempt.baseline ?? .distantPast),
              since <= now.addingTimeInterval(1), now.timeIntervalSince(repliedAt) < Self.wait else { return }
        verifiedAt = now
        checkingSince = nil
        self.attempt = nil
        failure = nil
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
