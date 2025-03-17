import ServiceLifecycle

extension Sentry: Service {
    public func run() async throws {
        print("FooService starting")
        try await Task.sleep(for: .seconds(10))
        print("FooService done")
    }
}
