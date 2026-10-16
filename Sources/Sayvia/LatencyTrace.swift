import Foundation

// All offsets use one monotonic origin. Overlapping spans are evidence, not
// additive costs. Nil means unmeasured, including speech end and upload alone.
struct TraceSpan: Codable, Equatable {
    var stage: String
    var startMS: Double
    var endMS: Double?
    var outcome: String
    var durationMS: Double? { endMS.map { max(0, $0 - startMS) } }
}
struct RequestTrace: Codable, Equatable {
    var stage: String
    var clientMS: Double
    var upstreamMS: Double?
    var uploadMS: Double? = nil
    var statusCode: Int?
}
struct LatencyTrace: Codable, Equatable {
    var version = 1
    var origin: String
    var stopTrigger: String?
    var lastSpeechToStopMS: Double? = nil
    var elapsedMS: Double
    var spans: [TraceSpan]
    var requests: [RequestTrace]
    var flags: [String]
}
struct ServiceTiming {
    var stage: String
    var start: Double
    var end: Double
    var outcome: String
    var statusCode: Int? = nil
    var upstreamMS: Double? = nil
    var isRequest = false
}

// Service callbacks can resume off the main executor; snapshots and writes
// share this small lock. No user text, endpoint or credential enters a trace.
final class LatencyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let now: () -> Double
    private let originTime: Double
    private let origin: String
    private let stopTrigger: String?
    private var spans: [TraceSpan] = []
    private var requests: [RequestTrace] = []
    private var flags: [String] = []
    init(origin: String, stopTrigger: String? = nil, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now; originTime = now(); self.origin = origin; self.stopTrigger = stopTrigger
    }
    @discardableResult func begin(_ stage: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        spans.append(TraceSpan(stage: stage, startMS: (now() - originTime) * 1000, outcome: "pending"))
        return spans.count - 1
    }
    func end(_ index: Int, outcome: String = "completed") {
        lock.lock(); defer { lock.unlock() }
        guard spans.indices.contains(index), spans[index].endMS == nil else { return }
        spans[index].endMS = (now() - originTime) * 1000; spans[index].outcome = outcome
    }
    func measure<T>(_ stage: String, _ action: () throws -> T) rethrows -> T {
        let index = begin(stage)
        do { let value = try action(); end(index); return value }
        catch { end(index, outcome: "failed"); throw error }
    }
    func record(_ event: ServiceTiming, prefix: String) {
        lock.lock(); defer { lock.unlock() }
        let stage = prefix + "." + event.stage
        spans.append(TraceSpan(stage: stage, startMS: (event.start - originTime) * 1000, endMS: (event.end - originTime) * 1000, outcome: event.outcome))
        if event.isRequest {
            requests.append(RequestTrace(stage: stage, clientMS: max(0, (event.end - event.start) * 1000), upstreamMS: event.upstreamMS, statusCode: event.statusCode))
        }
    }
    func flag(_ name: String) { lock.lock(); defer { lock.unlock() }; if !flags.contains(name) { flags.append(name) } }
    func snapshot() -> LatencyTrace {
        lock.lock(); defer { lock.unlock() }
        return LatencyTrace(origin: origin, stopTrigger: stopTrigger, elapsedMS: max(0, (now() - originTime) * 1000), spans: spans, requests: requests, flags: flags)
    }
}

struct InputIdentity: Codable, Equatable, Sendable {
    var pid: Int32
    var window: UInt
    var element: UInt
    var container: UInt? = nil
    var row: Int? = nil
    var column: Int? = nil
}
struct InputCaptureEvidence: Codable, Equatable {
    var capability = "none"
    var identity: InputIdentity?
    var interactionGeneration: String?
    var interactionSerial: UInt64?
    var failure: String?
}
struct InputDeliveryEvidence: Codable, Equatable {
    var version = 1
    var capture = InputCaptureEvidence()
    var route = "none"
    var status = "saved_only"
    var failureStage: String?
    var failureReason: String?
    // Nil is the durable pre-dispatch intent: a crash cannot tell whether the
    // subsequent external write happened. False is reserved for proven no-write.
    var dispatchAttempted: Bool? = false
    var plannedSegments = 0
    var dispatchedSegments = 0
    var confirmation = "none"
    var checkpoints: [String] = []
}
