import AsyncHTTPClient
import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat

public actor Sentry: Sendable {
    enum SwiftSentryError: Error {
        // case CantEncodeEvent
        // case CantCreateRequest
        case NoResponseBody(status: UInt)
        case InvalidArgumentException(_ msg: String)
    }

    internal static let VERSION = "SentrySwift/2.0.0"

    private let dsn: Dsn
    private let httpClient: HTTPClient
    internal let servername: String?
    internal let release: String?
    internal let environment: String?
    internal let maxAttachmentSize: Int
    // These ones are set by Sentry
    internal static let maxEnvelopeCompressedSize = 20_000_000
    internal static let maxEnvelopeUncompressedSize = 100_000_000
    internal static let maxAllAtachmentsCombined = 100_000_000
    internal static let maxEachAtachment = 100_000_000
    internal static let maxEventAndTransaction = 1_000_000
    internal static let maxSessionsPerEnvelope = 100
    internal static let maxSessionBucketPerSessions = 100

    internal static let maxRequestTime: TimeAmount = .seconds(30)
    internal static let maxResponseSize = 1024 * 1024

    private let beforeSend: (@Sendable (Event) -> Event?)?
    private let sampleRate: Double

    private var rateLimitUntil: Date?

    // MARK: Rate limiting

    func isRateLimited(now: Date = .now) -> Bool {
        guard let rateLimitUntil else {
            return false
        }

        return rateLimitUntil > now
    }

    func rateLimit(until: Date) {
        rateLimitUntil = until
    }

    private let logger = Logger(
        label: "swift-sentry", factory: StreamLogHandler.standardOutput(label:))

    private let _numRunningUploadTasks: NIOLockedValueBox<Int> = .init(0)
    private var numRunningUploadTasks: Int {
        get { _numRunningUploadTasks.withLockedValue { $0 } }
        set { _numRunningUploadTasks.withLockedValue { $0 = newValue } }
    }

    private var events: [Event] = []

    public init(
        dsn: String,
        httpClient: HTTPClient = .shared,
        servername: String? = getHostname(),
        release: String? = nil,
        environment: String? = nil,
        maxAttachmentSize: Int = 20_971_520,
        /// The sample rate to apply to events. A value of 0.0 will deny sending events, and 1.0 will send all events.
        sampleRate: Double = 1.0,
        /// This function is called before sending the event. If it returns nil, the event will not be sent.
        beforeSend: (@Sendable (Event) -> Event?)? = nil
    ) throws {
        self.dsn = try Dsn(fromString: dsn)
        self.maxAttachmentSize = maxAttachmentSize
        self.beforeSend = beforeSend

        guard sampleRate >= 0.0 && sampleRate <= 1.0 else {
            throw SwiftSentryError.InvalidArgumentException(
                "sampleRate must be between 0.0 and 1.0")
        }
        self.sampleRate = sampleRate

        self.httpClient = httpClient

        self.servername = servername
        self.release = release
        self.environment = environment
    }

    public func flush(timeout: TimeInterval = 2) async throws {

        if numRunningUploadTasks > 0 && timeout > 0 {
            logger.info(
                "Waiting for \(numRunningUploadTasks) upload tasks to finish for up to \(timeout) seconds"
            )
            let deadline = Date().addingTimeInterval(timeout)
            do {
                while numRunningUploadTasks > 0 && Date() < deadline {
                    // Not so sure about this, but sleep will always just throw when the task is cancelled AFAIK.
                    try await Task.sleep(for: .milliseconds(10))
                }
            } catch {
                logger.error("Failed to wait for upload tasks to finish: \(error)")
            }

        }
    }

    /// Get hostname from linux C function `gethostname`. The integrated function `ProcessInfo.processInfo.hostName` does not seem to work reliable on linux
    public static func getHostname() -> String {
        var data = [CChar](repeating: 0, count: 265)
        let string: String? = data.withUnsafeMutableBufferPointer {
            guard let ptr = $0.baseAddress else {
                return nil
            }
            gethostname(ptr, 256)
            return String(cString: ptr, encoding: .utf8)
        }
        return string ?? ""
    }

    nonisolated func capture(event: Event) {
        Task {
            await appendEvent(event)
        }
    }

    private func appendEvent(_ event: Event) {

        if sampleRate < 1.0 && Double.random(in: 0.0...1.0) > sampleRate {
            logger.debug("Skipping event due to sample rate setting")
            return
        }

        if let beforeSend {
            if let event = beforeSend(event) {
                events.append(event)
            } else {
                logger.debug("Skipping event due to beforeSend")
            }
        } else {
            events.append(event)
        }
    }

    // @discardableResult
    // public func capture(
    //     envelope: Envelope
    // ) async throws -> UUID? {
    //     try await send(envelope: envelope)
    // }

    // @discardableResult
    // public func uploadStackTrace(path: String) async throws -> [UUID] {

    //     // read all lines from the error log
    //     guard let content = try? String(contentsOfFile: path) else {
    //         return [UUID]()
    //     }

    //     // empty the error log (we don't want to send events twice)
    //     try "".write(toFile: path, atomically: true, encoding: .utf8)

    //     let events = FatalError.parseStacktrace(content).map {
    //         $0.getEvent(servername: servername, release: release, environment: environment)
    //     }

    //     var ids = [UUID]()

    //     for event in events {
    //         if let id = try await send(event: event) {
    //             ids.append(id)
    //         }
    //     }

    //     return ids
    // }

    struct SentryUUIDResponse: Codable {
        public var id: String
    }

    private func flush() async {

        numRunningUploadTasks += 1
        defer {
            numRunningUploadTasks -= 1
        }

        guard events.isEmpty == false else {
            return
        }

        guard await rateLimiter.isRateLimited() == false else {
            logger.debug("Skipping event due to rate limiting")
            return
        }

        let events = self.events
        self.events = []

        let encoder = JSONEncoder()

        let envelope: Envelope = try .init(
            header: .init(eventId: nil, dsn: nil, sdk: nil),
            items: events.map { event in
                .init(
                    header: .init(
                        type: "event", filename: nil, contentType: "application/json"),
                    data: try encoder.encode(event)
                )
            }
        )

        do {

            var request = HTTPClientRequest(url: dsn.getEnvelopeApiEndpointUrl())
            request.method = .POST

            request.headers.replaceOrAdd(
                name: "Content-Type", value: "application/x-sentry-envelope")
            request.headers.replaceOrAdd(name: "User-Agent", value: Sentry.VERSION)
            request.headers.replaceOrAdd(name: "X-Sentry-Auth", value: dsn.getAuthHeader())
            request.body = .bytes(ByteBuffer(data: try envelope.dump(encoder: JSONEncoder())))

            let response: HTTPClientResponse = try await httpClient.execute(
                request, timeout: Self.maxRequestTime)

            await updateRateLimiter(from: response)

            // we don't care about the returned body

            if response.status.code >= 400 {
                logger.error("Failed to send events to Sentry: \(response.status.code)")

            }

            // let body = try await response.body.collect(upTo: Self.maxResponseSize)

            // guard
            //     let decodable = try body.getJSONDecodable(
            //         SentryUUIDResponse.self, at: 0, length: body.readableBytes),
            //     let id = UUID(fromHexadecimalEncodedString: decodable.id)
            // else {
            //     throw SwiftSentryError.NoResponseBody(status: response.status.code)
            // }

        } catch {
            self.events.insert(contentsOf: events, at: 0)
        }
    }

    private func updateRateLimiter(from response: HTTPClientResponse) async {
        if response.status.code == 429 {
            if let retryAfter = response.headers["Retry-After"].first,
                let retryAfterInterval = TimeInterval(retryAfter)
            {
                rateLimit(until: Date().addingTimeInterval(retryAfterInterval))
                logger.debug("Rate limited for \(retryAfterInterval) seconds")
            } else {
                // On 429 responses without the above headers, assume a 60s rate limit for all categories
                rateLimit(until: Date().addingTimeInterval(60))
                logger.debug("Rate limited for 60 seconds")
            }
        }
    }
}
