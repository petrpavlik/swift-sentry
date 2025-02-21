import Foundation
import Logging

// docs at https://develop.sentry.dev/sdk/event-payloads/
public struct Event: Encodable {
    /// Unique identifier of this event.
    /// Hexadecimal string representing a uuid4 value. The length is exactly 32 characters. Dashes are not allowed. Has to be lowercase.
    /// Even though this field is backfilled on the server with a new uuid4, it is strongly recommended to generate that uuid4 clientside.
    /// There are some features like user feedback which are easier to implement that way, and debugging in case events get lost in your Sentry installation is also easier.
    @UUIDHexadecimalEncoded
    public var event_id: UUID

    /// Indicates when the event was created in the Sentry SDK. The format is a numeric (integer or float) value representing the number of seconds that have elapsed since the Unix epoch.
    public let timestamp: Double

    /// Platform identifier of this event (defaults to "other").
    /// A string representing the platform the SDK is submitting from. This will be used by the Sentry interface to customize various components in the interface.
    /// Acceptable values are: `as3`, `c`, `cfml`, `cocoa`, `csharp`, `elixir`, `haskell`, `go`, `groovy`, `java`, `javascript`, `native`, `node`, `objc`, `other`, `perl`, `php`, `python`, `ruby`
    public let platform: String = "other"

    /// The record severity. Defaults to `error`.
    public let level: Level?

    /// The name of the logger which created the record.
    public let logger: String?

    /// The name of the transaction which caused this exception.
    /// For example, in a web app, this might be the route name.
    public let transaction: String?

    /// Server or device name the event was generated on.
    /// This is supposed to be a hostname.
    public let server_name: String?

    /// The release version of the application. Release versions must be unique across all projects in your organization.
    public let release: String?

    /// Optional. A map or list of tags for this event. Each tag must be less than 200 characters.
    public let tags: [String: String]?

    /// The environment name, such as `production` or `staging`.
    public let environment: String?

    /// The Message Interface carries a log message that describes an event or error.
    public let message: Message?

    /// One or multiple chained (nested) exceptions.
    public let exception: Exceptions?

    /// List of breadcrumbs recorded before this event.
    public let breadcrumbs: Breadcrumbs?

    /// Information about the user who triggered this event.
    public let user: User?
}

public enum Level: String, Encodable {
    case fatal
    case error
    case warning
    case info
    case debug

    init(from: Logger.Level) {
        switch from {
        case .trace, .debug:
            self = .debug
        case .info, .notice:
            self = .info
        case .warning:
            self = .warning
        case .error:
            self = .error
        case .critical:
            self = .fatal
        }
    }
}

// Make Message enum public
public enum Message: Encodable {
    enum CodingKeys: String, CodingKey {
        case message
        case params
    }

    case raw(message: String)
    case format(message: String, params: [String])

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .raw(let message):
            var container = encoder.singleValueContainer()
            try container.encode(message)
        case .format(let message, let params):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(message, forKey: .message)
            try container.encode(params, forKey: .params)
        }
    }
}

// Make Exceptions struct public
public struct Exceptions: Encodable {
    public let values: [ExceptionDataBag]
}

// Make ExceptionDataBag struct public
public struct ExceptionDataBag: Encodable {
    /// The type of exception, e.g. `ValueError`.
    /// At least one of `type` or `value` is required, otherwise the exception is discarded.
    public let type: String?

    /// Human readable display value.
    /// At least one of `type` or `value` is required, otherwise the exception is discarded.
    public let value: String?

    /// Stack trace containing frames of this exception.
    public let stacktrace: Stacktrace?
}

// Make Stacktrace struct public
public struct Stacktrace: Encodable, Equatable {
    /// A non-empty list of stack frames. The list is ordered from caller to callee, or oldest to youngest. The last frame is the one creating the exception.
    public let frames: [Frame]
}

// Make Frame struct public
public struct Frame: Encodable, Equatable {
    /// The source file name (basename only).
    public let filename: String?

    /// Name of the frame's function. This might include the name of a class.
    /// This function name may be shortened or demangled. If not, Sentry will demangle and shorten it for some platforms. The original function name will be stored in `raw_function`.
    public let function: String?

    /// A raw (but potentially truncated) function value.
    public let raw_function: String?

    /// Line number within the source file, starting at 1.
    public let lineno: Int?

    /// Column number within the source file, starting at 1.
    public let colno: Int?

    /// Absolute path to the source file.
    public let abs_path: String?

    /// An optional instruction address for symbolication. This should be a string with a hexadecimal number that includes a `0x` prefix. If this is set and a known image is defined in the Debug Meta Interface, then symbolication can take place.
    public let instruction_addr: String?
}

// Make Breadcrumbs struct public
public struct Breadcrumbs: Encodable {
    public let values: [Breadcrumb]
}

// Make Breadcrumb struct public
public struct Breadcrumb: Encodable {
    public let message: String?
    public let level: Level?
    public let timestamp: Double?

    public init(message: String? = nil, level: Level? = nil, timestamp: Double? = nil) {
        self.message = message
        self.level = level
        self.timestamp = timestamp
    }
}

// Make User struct public
public struct User: Encodable {
    public let id: String
    public let ip_address: String

    public init(id: String, ip_address: String) {
        self.id = id
        self.ip_address = ip_address
    }
}
