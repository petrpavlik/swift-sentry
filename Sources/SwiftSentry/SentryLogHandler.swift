import Foundation
import Logging

public struct SentryLogHandler: LogHandler {
    private let label: String
    private let sentry: Sentry
    public var metadata = Logger.Metadata()
    public var logLevel: Logger.Level
    private let attachmentKey: String?
    public var metadataProvider: Logger.MetadataProvider?

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            metadata[metadataKey]
        }
        set {
            metadata[metadataKey] = newValue
        }
    }

    public init(label: String, sentry: Sentry, level: Logger.Level, attachmentKey: String? = "Attachment") {
        self.label = label
        self.sentry = sentry
        logLevel = level
        self.attachmentKey = attachmentKey
    }

    private func convertToSentryStacktrace(_ stackTrace: StackTrace) -> Stacktrace {
        let frames = stackTrace.frames.map { frame -> Frame in
            let components = frame.file.components(separatedBy: "/")
            let filename = components.last ?? frame.file
            
            return Frame(
                filename: filename,
                function: frame.function,
                raw_function: frame.function,
                lineno: nil,  // Our StackTrace doesn't capture line numbers
                colno: nil,
                abs_path: frame.file,
                instruction_addr: nil
            )
        }
        return Stacktrace(frames: frames)
    }

    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let metadataEscaped = (metadata ?? [:])
            .merging(self.metadata, uniquingKeysWith: { a, _ in a })
            .merging(self.metadataProvider?.get() ?? [:], uniquingKeysWith: { (a, _) in a })
        let tags = metadataEscaped.mapValues { "\($0)" }
        
        // Capture stack trace for error levels and above
        let stackTrace: StackTrace? = (level >= .error) ? .capture(skip: 1) : nil
        
        if let attachment = evalMetadata(metadata: metadataEscaped, attachmentKey: attachmentKey) {
            let uid = UUID()
            do {
                let eventData = try makeEventData(
                    message: message.description,
                    level: Level(from: level),
                    uid: uid,
                    servername: sentry.servername,
                    release: sentry.release,
                    environment: sentry.environment,
                    logger: source,
                    transaction: metadataEscaped["transaction"]?.description,
                    tags: tags.isEmpty ? nil : tags,
                    file: file,
                    function: function,
                    line: Int(line),
                    stackTrace: stackTrace.map(convertToSentryStacktrace)
                )
                let envelope: Envelope = .init(
                    header: .init(eventId: uid, dsn: nil, sdk: nil),
                    items: [
                        .init(
                            header: .init(type: "event", filename: nil, contentType: "application/json"),
                            data: eventData
                        ),
                        try? attachment.toEnvelopeItem(),
                    ].compactMap { $0 }
                )
                
                Task {
                    try await sentry.capture(envelope: envelope)
                }
                
                return
            } catch {}
        }
        
        Task {
            try await sentry.capture(
                message: message.description,
                level: Level(from: level),
                logger: source,
                transaction: metadataEscaped["transaction"]?.description,
                tags: tags.isEmpty ? nil : tags,
                file: file,
                filePath: nil,
                function: function,
                line: Int(line),
                column: nil,
                stackTrace: stackTrace.map(convertToSentryStacktrace)
            )
        }
    }
}
