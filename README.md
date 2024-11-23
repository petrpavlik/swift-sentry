# SwiftSentry

Log messages from Swift to Sentry following [SwiftLog](https://github.com/apple/swift-log).

## Usage
1. Add `SwiftSentry` as a dependency to your `Package.swift`

```swift
  dependencies: [
    .package(name: "SwiftSentry", url: "https://github.com/petrpavlik/swift-sentry.git", from: "1.0.0")
  ],
  targets: [
    .target(name: "MyApp", dependencies: ["SwiftSentry"])
  ]
```

2. Configure Logging system

```swift
import Logging
import SwiftSentry

let sentry = Sentry(dsn: "<Your Sentry DSN String>")

// Add sentry to logger and set the minimum log level to `.error`
LoggingSystem.bootstrap { label in
    MultiplexLogHandler([
        SentryLogHandler(label: label, sentry: sentry, level: .error),
        StreamLogHandler.standardOutput(label: label)
    ])
}
```

If your application already uses a `EventLoopGroup` it is recommended to share it with SwiftSentry:

```swift
let sentry = try Sentry(
  dsn: "<Your Sentry DSN String>",
  httpClient: HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup))
)
```

3. Send logs

```swift
var logger = Logger(label: "com.example.MyApp.main")
logger.critical("Something went wrong!")
```

The metadata of the logger will be sent as tags to sentry.

```swift
logger[metadataKey: "note"] = Logger.MetadataValue(stringLiteral: "some usefull information")
```

## Upload crash reports
SwiftSentry can also upload stack traces generated on Linux with [Swift Backtrace](https://github.com/swift-server/swift-backtrace).

The following configuration assumes that you run an "API service" based on Swift with `supervisord` following a typical [vapor deployment](https://docs.vapor.codes/4.0/deploy/supervisor/).

Stack traces are uploaded at each start of your "API service". If your application crashes, a stack trace will be printed on `stderr` and written to a log file specified in `supervisord`. Once your application is restarted, SwiftSentry will read this log file and upload it to Sentry.

```swift
import SwiftSentry

let sentry = Sentry(dsn: "<Your Sentry DSN String>")

// Upload stack trace from a log file
// WARNING: the error file will be truncated afterwards
_ = try? sentry.uploadStackTrace(path: "/var/log/supervisor/hello-stderr.log")
```


Supervisor configuration at `/etc/supervisor/conf.d/hello.conf`:

```
[program:hello]
command=/home/vapor/hello/.build/release/Run serve --env production
directory=/home/vapor/hello/
user=vapor
stdout_logfile=/var/log/supervisor/%(program_name)-stdout.log
stderr_logfile=/var/log/supervisor/%(program_name)-stderr.log
```
