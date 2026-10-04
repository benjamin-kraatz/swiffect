import Testing
@testable import Swiffect

private struct Greeter: ServiceKey {
    typealias Value = Greeter
    var greeting: String
}

private enum AppLocale: ReferenceKey {
    static var defaultValue: String { "en" }
}

@Suite struct ContextTests {
    @Test func contextIsTypeKeyedAndImmutable() {
        let base = Context().adding(Greeter.self, Greeter(greeting: "hi"))
        let extended = base.adding(AppLocale.self, "de")
        #expect(base.getOptional(Greeter.self)?.greeting == "hi")
        #expect(base.get(AppLocale.self) == "en")
        #expect(extended.get(AppLocale.self) == "de")
        #expect(!base.contains(AppLocale.self))
        #expect(extended.removing(Greeter.self).getOptional(Greeter.self) == nil)
        #expect(base.merging(Context().adding(Greeter.self, Greeter(greeting: "yo"))).getOptional(Greeter.self)?.greeting == "yo")
    }

    @Test func provideServiceMakesServiceAvailable() async throws {
        let program = Effect.service(Greeter.self).map { "\($0.greeting), world" }
        let result = try await program.provideService(Greeter.self, Greeter(greeting: "Hello")).run()
        #expect(result == "Hello, world")
        let viaContext = try await program.run(context: Context().adding(Greeter.self, Greeter(greeting: "Hey")))
        #expect(viaContext == "Hey, world")
    }

    @Test func missingServiceIsADefect() async {
        let exit = await Effect.service(Greeter.self).runExit()
        let defect = exit.cause?.defects.first as? MissingServiceError
        #expect(defect?.key.contains("Greeter") == true)
        #expect(await Effect.serviceOption(Greeter.self).runExit().value! == nil)
    }

    @Test func referencesAreScopedToTheRegion() async throws {
        let read = Effect.service(AppLocale.self)
        let program: Effect<(String, String, String), Never> = .gen { bind in
            (try await bind(read), try await bind(read.provideService(AppLocale.self, "fr")), try await bind(read))
        }
        let (before, inside, after) = try await program.run()
        #expect([before, inside, after] == ["en", "fr", "en"])
        let updated = try await read.updateService(AppLocale.self) { $0 + "-US" }.run()
        #expect(updated == "en-US")
    }

    @Test func provideContextMergesOverCurrent() async throws {
        let both: Effect<(Greeter, String), Never> = .gen { bind in
            (try await bind(Effect.service(Greeter.self)), try await bind(Effect.service(AppLocale.self)))
        }
        let program = both
            .provideContext(Context().adding(AppLocale.self, "it"))
            .provideService(Greeter.self, Greeter(greeting: "ciao"))
        let (greeter, locale) = try await program.run()
        #expect(greeter.greeting == "ciao")
        #expect(locale == "it")
    }
}
