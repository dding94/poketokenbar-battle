import CoreGraphics
import Foundation
import Vision

/// Every OCR call in the tests goes through here, so a stuck Vision call fails its test instead of hanging
/// the whole run. On macOS 27 `VNImageRequestHandler.perform` was seen never to return (defect log).
enum VisionOCR {
    struct Stalled: Error, CustomStringConvertible {
        let description: String
    }

    /// A normal call takes well under a second, but the first one after a new build took 31 s on macOS 27
    /// while Vision prepared its models, so only a real stall may reach this.
    static let limit: Duration = .seconds(120)

    private static let shared = Gate()

    static func perform(_ request: VNRequest, on image: CGImage, limit: Duration = limit) throws {
        let call = Gate.Call { try VNImageRequestHandler(cgImage: image).perform([request]) }
        do {
            try shared.run(limit: limit, call)
        } catch is Stalled {
            request.cancel()
            throw Stalled(description: "OCR failed: Vision did not answer within \(limit)")
        }
    }

    /// Runs each call on its own thread and waits at most `limit`. A thread cannot be killed, so a stuck call
    /// stays parked there, and while it does the gate fails later calls at once. The stuck frame sits inside
    /// Vision's serial detector queue, so they would most likely wait behind it, one full limit per test.
    final class Gate: @unchecked Sendable {
        /// Vision's types are not `Sendable`, but the caller waits and never touches them during the call.
        struct Call: @unchecked Sendable {
            let body: () throws -> Void
            init(_ body: @escaping () throws -> Void) { self.body = body }
        }

        private final class Attempt: @unchecked Sendable {
            var result: Result<Void, Error>?
            var abandoned = false
        }

        private let lock = NSLock()
        private var stuck = 0

        func run(limit: Duration, _ call: Call) throws {
            try lock.withLock {
                if stuck > 0 { throw Stalled(description: "An earlier call is still stuck") }
            }
            let attempt = Attempt()
            let finished = DispatchSemaphore(value: 0)
            Thread.detachNewThread { [self] in
                let result = Result<Void, Error> { try call.body() }
                lock.withLock {
                    attempt.result = result
                    if attempt.abandoned { stuck -= 1 }
                }
                finished.signal()
            }
            let (seconds, attoseconds) = limit.components
            let deadline = DispatchTime.now() + Double(seconds) + Double(attoseconds) / 1e18
            _ = finished.wait(timeout: deadline)
            try lock.withLock {
                guard let result = attempt.result else {
                    attempt.abandoned = true
                    stuck += 1
                    throw Stalled(description: "No answer within \(limit)")
                }
                try result.get()
            }
        }
    }
}
