import Testing
@testable import SwiftMusic

struct PatternParseCacheTests {
    private static func score() -> some Sound {
        Synthesizer(.sine).rhythm("x [x ~] x").gain("<0.2 0.8>")
    }

    @Test(.timeLimit(.minutes(1)))
    func liveCompilationReusesSyntaxWithoutSharingDomainValidationOrState() async throws {
        var context = _SoundCompilationContext(limits: .standard, capturesLiveProgram: true)
        let fragment = try context.visit(Self.score(), depth: 0)
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .beats(32))
        let compiled = try context.finishLive(fragment, policy: policy)
        #expect(context.patternCache.parseCount == 2)
        #expect(compiled.events.count > 0)
        try await withThrowingTaskGroup(of: CompiledSound.self) { group in
            for _ in 0..<8 {
                group.addTask { try SoundCompiler().compile(Self.score(), liveLoop: policy) }
            }
            for try await result in group { #expect(result == compiled) }
        }

        var cache = _PatternParseCache()
        let rhythm: RhythmPattern = "x"
        _ = try rhythm.resolvedTransform(cycle: .whole, cache: &cache)
        let gain: GainPattern = "x"
        #expect(throws: GainPatternError.invalidToken(token: "x", index: 0, offset: 0)) {
            try gain.resolvedTransform(cycle: .whole, cache: &cache)
        }
        #expect(cache.parseCount == 1)
        let full = Array(repeating: "x", count: _MiniPatternParser.maximumLeaves).joined(separator: " ")
        _ = try cache.parse(full)
        _ = try cache.parse(full + " ")
        _ = try cache.parse(full)
        #expect(cache.parseCount == 4)
        #expect(throws: _PatternParserError.self) { try cache.parse("[") }
        #expect(throws: _PatternParserError.self) { try cache.parse("[") }
        #expect(cache.parseCount == 6)
        let composed = try cache.parse("é x")
        let decomposed = try cache.parse("e\u{301} x")
        #expect(composed.leaves[1].offset == 3)
        #expect(decomposed.leaves[1].offset == 4)
        #expect(cache.parseCount == 8)
    }
}
