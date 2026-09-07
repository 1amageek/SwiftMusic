import Testing
import SwiftMusic

struct TrackCompilationTests {
    @Test(.timeLimit(.minutes(3)))
    func defaultTrackAddsOneBoundaryAfterMixingMainContent() throws {
        let compiled = try SoundCompiler().compile(Track("drums") {
            Sample("kick")
            Synthesizer(.sine)
        })

        #expect(compiled.tracks.count == 1)
        #expect(compiled.tracks[0].id == 0)
        #expect(compiled.tracks[0].name == "drums")
        #expect(compiled.tracks[0].parentID == nil)
        #expect(compiled.tracks[0].level == 1)
        #expect(compiled.tracks[0].pan == nil)
        #expect(!compiled.tracks[0].isMuted)
        #expect(!compiled.tracks[0].isSoloed)
        #expect(compiled.tracks[0].renderNodeID == 3)
        #expect(compiled.renderNodes == [
            .source(sourceID: 0),
            .source(sourceID: 1),
            .mix(inputs: [0, 1]),
            .track(input: 2, trackID: 0)
        ])
        #expect(compiled.rootNodeIDs == [3])
        #expect(compiled.events.map(\.trackID) == [0, 0])
    }

    @Test(.timeLimit(.minutes(3)))
    func nestedTracksRetainPreorderParentsAndInnerGraphBoundaries() throws {
        let compiled = try SoundCompiler().compile(Track("outer") {
            Track("inner") {
                Sample("inner")
            }
            Synthesizer(.sine)
        })

        #expect(compiled.tracks.map(\.id) == [0, 1])
        #expect(compiled.tracks.map(\.name) == ["outer", "inner"])
        #expect(compiled.tracks.map(\.parentID) == [nil, 0])
        #expect(compiled.tracks.map(\.renderNodeID) == [4, 1])
        #expect(compiled.events.map(\.trackID) == [1, 0])
        #expect(compiled.renderNodes == [
            .source(sourceID: 0),
            .track(input: 0, trackID: 1),
            .source(sourceID: 1),
            .mix(inputs: [1, 2]),
            .track(input: 3, trackID: 0)
        ])
        #expect(compiled.rootNodeIDs == [4])
    }

    @Test(.timeLimit(.minutes(3)))
    func copiedTrackSettingsValidateAndReplaceMetadata() throws {
        let configured = Track("mix") {
            Sample("main")
        }
        .trackLevel(0.5)
        .trackPan(0)
        .trackMuted()
        .trackMuted(false)
        .trackSolo()

        let compiled = try SoundCompiler().compile(configured)
        let track = compiled.tracks[0]
        #expect(track.level == 0.5)
        #expect(track.pan == 0)
        #expect(!track.isMuted)
        #expect(track.isSoloed)
        #expect(track.renderNodeID == 1)
        #expect(compiled.renderNodes == [
            .source(sourceID: 0),
            .track(input: 0, trackID: 0)
        ])

        for value in [-1.0, .nan, .infinity] {
            #expect {
                try SoundCompiler().compile(
                    Track("bad-level") { Sample("main") }.trackLevel(value)
                )
            } throws: { error in
                error as? SoundCompilationError
                    == .invalidParameter("Track level must be finite and nonnegative")
            }
        }
        for value in [-2.0, 2, .nan, .infinity] {
            #expect {
                try SoundCompiler().compile(
                    Track("bad-pan") { Sample("main") }.trackPan(value)
                )
            } throws: { error in
                error as? SoundCompilationError
                    == .invalidParameter("Track pan must be finite and in -1...1")
            }
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func defaultRoutedTrackKeepsSinkSeparateAndNondefaultRoutingFails() throws {
        let routed = try SoundCompiler().compile(Track("routed") {
            Sample("bus").output("aux")
            Sample("main")
        })
        #expect(routed.renderNodes == [
            .source(sourceID: 0),
            .output(input: 0, bus: "aux"),
            .source(sourceID: 1),
            .track(input: 2, trackID: 0)
        ])
        #expect(routed.rootNodeIDs == [1, 3])
        #expect(routed.tracks[0].renderNodeID == 3)

        let empty = try SoundCompiler().compile(Track("empty") {})
        #expect(empty.renderNodes.isEmpty)
        #expect(empty.rootNodeIDs.isEmpty)
        #expect(empty.tracks[0].renderNodeID == nil)

        let routedOnly = try SoundCompiler().compile(Track("sink") {
            Sample("bus").output("aux")
        })
        #expect(routedOnly.renderNodes == [
            .source(sourceID: 0),
            .output(input: 0, bus: "aux")
        ])
        #expect(routedOnly.rootNodeIDs == [1])
        #expect(routedOnly.tracks[0].renderNodeID == nil)

        #expect {
            try SoundCompiler().compile(
                Track("invalid") { Sample("bus").output("aux") }.trackLevel(0.5)
            )
        } throws: { error in
            error as? SoundCompilationError
                == .invalidParameter("Audio processing must precede output routing")
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func liveCompilationKeepsTrackGraphAndEventTrackIdentity() throws {
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        let compiled = try SoundCompiler().compile(
            Track("drums") {
                Sample("kick").rhythm("x ~")
            },
            liveLoop: policy
        )

        #expect(compiled.playbackMode == .seamlessLoop)
        #expect(compiled.events.allSatisfy { $0.trackID == 0 })
        #expect(compiled.tracks[0].renderNodeID == 1)
        #expect(compiled.renderNodes == [
            .source(sourceID: 0),
            .track(input: 0, trackID: 0)
        ])
        #expect(compiled.rootNodeIDs == [1])
    }
}
