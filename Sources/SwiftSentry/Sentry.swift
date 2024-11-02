import AsyncHTTPClient
import Foundation
import NIO
import NIOFoundationCompat

public final class Sentry: Sendable {
    enum SwiftSentryError: Error {
        case NoResponseBody(status: UInt)
        case InvalidArgumentException(_ msg: String)
    }

    internal static let VERSION = "SentrySwift/1.0.0"

    private let dsn: Dsn
    private let httpClient: HTTPClient
    private let isUsingCustomHttpClient: Bool
    internal let servername: String?
    internal let release: String?
    internal let environment: String?
    // This one can be changed, it's merely the default value
    internal static var maxAttachmentSize = 20_971_520
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

    public init(
        dsn: String,
        httpClient: HTTPClient? = nil,
        servername: String? = getHostname(),
        release: String? = nil,
        environment: String? = nil
    ) throws {
        self.dsn = try Dsn(fromString: dsn)
        
        if let httpClient {
            self.httpClient = httpClient
            self.isUsingCustomHttpClient = true
        } else {
            self.httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            self.isUsingCustomHttpClient = false
        }
        
        self.servername = servername
        self.release = release
        self.environment = environment
    }

    public func shutdown() async throws {
        if isUsingCustomHttpClient == false {
            try await httpClient.shutdown()
        }
    }

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

    @discardableResult
    public func capture(error: Error) async throws -> UUID {
        let stackTrace = StackTrace.capture(skip: 1)
        let sentryStacktrace = stackTrace.map { trace in
            convertToSentryStacktrace(trace)
        }
        
        let edb = ExceptionDataBag(
            type: error.localizedDescription,
            value: nil,
            stacktrace: sentryStacktrace
        )

        let exceptions = Exceptions(values: [edb])

        let event = Event(
            event_id: UUID(),
            timestamp: Date().timeIntervalSince1970,
            level: .error,
            logger: nil,
            transaction: nil,
            server_name: servername,
            release: release,
            tags: nil,
            environment: environment,
            message: .raw(message: "\(error.localizedDescription)"),
            exception: exceptions,
            breadcrumbs: nil,
            user: nil
        )

        return try await send(event: event)
    }

    private func convertToSentryStacktrace(_ stackTrace: StackTrace) -> Stacktrace {
        let frames = stackTrace.frames.map { frame -> Frame in
            let components = frame.file.components(separatedBy: "/")
            let filename = components.last ?? frame.file
            
            return Frame(
                filename: filename,
                function: frame.function,
                raw_function: frame.function,
                lineno: nil,
                colno: nil,
                abs_path: frame.file,
                instruction_addr: nil
            )
        }
        return Stacktrace(frames: frames)
    }

    @discardableResult
    public func capture(
        message: String,
        level: Level,
        logger: String? = nil,
        transaction: String? = nil,
        tags: [String: String]? = nil,
        file: String? = #file,
        filePath: String? = #filePath,
        function: String? = #function,
        line: Int? = #line,
        column: Int? = #column,
        stackTrace: Stacktrace? = nil
    ) async throws -> UUID {
        let frame = Frame(filename: file, function: function, raw_function: nil, lineno: line, colno: column, abs_path: filePath, instruction_addr: nil)
        let stacktrace = stackTrace ?? Stacktrace(frames: [frame])

        let event = Event(
            event_id: UUID(),
            timestamp: Date().timeIntervalSince1970,
            level: level,
            logger: logger,
            transaction: transaction,
            server_name: servername,
            release: release,
            tags: tags,
            environment: environment,
            message: .raw(message: message),
            exception: Exceptions(values: [ExceptionDataBag(type: message, value: nil, stacktrace: stacktrace)]),
            breadcrumbs: nil,
            user: nil
        )

        return try await send(event: event)
    }

    @discardableResult
    public func capture(
        envelope: Envelope
    ) async throws -> UUID {
        try await send(envelope: envelope)
    }

    @discardableResult
    public func uploadStackTrace(path: String)  async throws -> [UUID] {
        guard let content = try? String(contentsOfFile: path) else {
            return [UUID]()
        }

        try "".write(toFile: path, atomically: true, encoding: .utf8)

        let events = FatalError.parseStacktrace(content).map {
            $0.getEvent(servername: servername, release: release, environment: environment)
        }
        
        var ids = [UUID]()
        
        for event in events {
            let id = try await send(event: event)
            ids.append(id)
        }

        return ids
    }

    struct SentryUUIDResponse: Codable {
        public var id: String
    }

    @discardableResult
    internal func send(event: Event) async throws -> UUID {
        let data = try JSONEncoder().encode(event)
        var request = HTTPClientRequest(url: dsn.getStoreApiEndpointUrl())
        request.method = .POST

        request.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
        request.headers.replaceOrAdd(name: "User-Agent", value: Sentry.VERSION)
        request.headers.replaceOrAdd(name: "X-Sentry-Auth", value: dsn.getAuthHeader())
        request.body = .bytes(ByteBuffer(data: data))
        
        let response: HTTPClientResponse = try await httpClient.execute(request, timeout: Self.maxRequestTime)
        
        let body = try await response.body.collect(upTo: Self.maxResponseSize)

        guard let decodable = try body.getJSONDecodable(SentryUUIDResponse.self, at: 0, length: body.readableBytes),
              let id = UUID(fromHexadecimalEncodedString: decodable.id)
        else {
            throw SwiftSentryError.NoResponseBody(status: response.status.code)
        }
        
        return id
    }

    @discardableResult
    internal func send(envelope: Envelope) async throws -> UUID {
        var request = HTTPClientRequest(url: dsn.getEnvelopeApiEndpointUrl())
        request.method = .POST

        request.headers.replaceOrAdd(name: "Content-Type", value: "application/x-sentry-envelope")
        request.headers.replaceOrAdd(name: "User-Agent", value: Sentry.VERSION)
        request.headers.replaceOrAdd(name: "X-Sentry-Auth", value: dsn.getAuthHeader())
        request.body = .bytes(ByteBuffer(data: try envelope.dump(encoder: JSONEncoder())))
        
        let response: HTTPClientResponse = try await httpClient.execute(request, timeout: Self.maxRequestTime)
        
        let body = try await response.body.collect(upTo: Self.maxResponseSize)
                
        guard let decodable = try body.getJSONDecodable(SentryUUIDResponse.self, at: 0, length: body.readableBytes),
              let id = UUID(fromHexadecimalEncodedString: decodable.id)
        else {
            throw SwiftSentryError.NoResponseBody(status: response.status.code)
        }
        
        return id
    }
}
