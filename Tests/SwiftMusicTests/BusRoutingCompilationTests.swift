import Testing
import SwiftMusic

struct BusRoutingCompilationTests {
    @Test(.timeLimit(.minutes(3)))
    func legacySendAndOutputKeepDeclarationGraphWithoutReturn() throws {
        let compiled = try SoundCompiler().compile(
            Synthesizer(.sine)
                .send(to: "room", level: 0.5)
                .output("main")
        )

        #expect(compiled.renderNodes == [
            .source(sourceID: 0),
            .send(input: 0, bus: "room", level: 0.5),
            .output(input: 1, bus: "main")
        ])
        #expect(compiled.rootNodeIDs == [2])
    }

    @Test(.timeLimit(.minutes(3)))
    func forwardReturnIsResolvedAndDependencyOrdered() throws {
        struct Song: Music {
            var body: some Sound {
                BusReturn("verb")
                Synthesizer(.sine).send(to: "verb", level: 0.5)
            }
        }

        let compiled = try SoundCompiler().compile(Song())
        let sendID = try #require(compiled.renderNodes.firstIndex { node in
            if case .send = node { return true }
            return false
        })
        let returnID = try #require(compiled.renderNodes.firstIndex { node in
            if case .busReturn = node { return true }
            return false
        })
        #expect(sendID < returnID)
        guard case .busReturn(let bus, let inputs) = compiled.renderNodes[returnID] else {
            Issue.record("Expected a resolved bus return")
            return
        }
        #expect(bus == "verb")
        #expect(inputs == [sendID])
        guard let rootID = compiled.rootNodeIDs.first,
              case .mix(let rootInputs) = compiled.renderNodes[rootID] else {
            Issue.record("Expected the sender and return to be mixed at the root")
            return
        }
        #expect(rootInputs.contains(returnID))
    }

    @Test(.timeLimit(.minutes(3)))
    func trackSendsRetainPreAndPostFaderInputs() throws {
        struct Song: Music {
            var body: some Sound {
                BusReturn("pre")
                BusReturn("post")
                Track("lead") {
                    Synthesizer(.sine)
                }
                .trackLevel(0.5)
                .send(to: "pre", level: 0.25, placement: .preFader)
                .send(to: "post", level: 0.75, placement: .postFader)
            }
        }

        let compiled = try SoundCompiler().compile(Song())
        let track = try #require(compiled.tracks.first)
        let trackID = try #require(track.renderNodeID)
        guard case .track(let mainInput, let storedTrackID) = compiled.renderNodes[trackID] else {
            Issue.record("Expected the Track boundary node")
            return
        }
        #expect(storedTrackID == track.id)

        var placements: [TrackSendPlacement: (input: Int, level: Double)] = [:]
        for node in compiled.renderNodes {
            guard case .trackSend(let input, let bus, let level, let nodeTrackID, let placement) = node else {
                continue
            }
            #expect(nodeTrackID == track.id)
            placements[placement] = (input, level)
            #expect(bus == (placement == .preFader ? "pre" : "post"))
        }
        #expect(placements[.preFader]?.input == mainInput)
        #expect(placements[.preFader]?.level == 0.25)
        #expect(placements[.postFader]?.input == trackID)
        #expect(placements[.postFader]?.level == 0.75)
    }

    @Test(.timeLimit(.minutes(3)))
    func duplicateEmptyAndInvalidReturnsFailWithTypedRoutingErrors() throws {
        struct Duplicate: Music {
            var body: some Sound {
                BusReturn("room")
                BusReturn("room")
                Synthesizer(.sine).send(to: "room", level: 1)
            }
        }
        #expect(throws: SoundCompilationError.invalidBusRouting(.duplicateReturn("room"))) {
            try SoundCompiler().compile(Duplicate())
        }

        #expect(throws: SoundCompilationError.invalidBusRouting(.emptyReturn("room"))) {
            try SoundCompiler().compile(BusReturn("room"))
        }

        #expect(throws: SoundCompilationError.invalidBusRouting(.invalidName("   "))) {
            try SoundCompiler().compile(BusReturn("   "))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func selfAndCrossBusCyclesAreRejectedBeforeCompiledSound() throws {
        let selfCycle = BusReturn("a").send(to: "a", level: 1)
        #expect(throws: SoundCompilationError.invalidBusRouting(.cycle)) {
            try SoundCompiler().compile(selfCycle)
        }

        struct CrossCycle: Music {
            var body: some Sound {
                BusReturn("a").send(to: "b", level: 1)
                BusReturn("b").send(to: "a", level: 1)
            }
        }
        #expect(throws: SoundCompilationError.invalidBusRouting(.cycle)) {
            try SoundCompiler().compile(CrossCycle())
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func busAndDependencyBoundsAreChecked() throws {
        struct ManyBuses: Music {
            var body: some Sound {
                BusReturn("a")
                BusReturn("b")
                Synthesizer(.sine).send(to: "a", level: 1)
                Synthesizer(.sine).send(to: "b", level: 1)
            }
        }
        let oneBus = SoundCompiler(limits: try .init(maximumBuses: 1))
        #expect(throws: SoundCompilationError.invalidBusRouting(.maximumBusesExceeded(limit: 1))) {
            try oneBus.compile(ManyBuses())
        }

        let chained = Synthesizer(.sine)
            .send(to: "room", level: 1)
            .send(to: "room", level: 1)
            .send(to: "room", level: 1)
        struct EdgeBound: Music {
            let sound: ModifiedSound
            var body: some Sound {
                BusReturn("room")
                sound
            }
        }
        let sixNodes = SoundCompiler(limits: try .init(maximumRenderNodes: 6))
        #expect(throws: SoundCompilationError.invalidBusRouting(.maximumEdgesExceeded(limit: 6))) {
            try sixNodes.compile(EdgeBound(sound: chained))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func liveCompilationRetainsEventsAndResolvedBusGraph() throws {
        struct Song: Music {
            var body: some Sound {
                BusReturn("room")
                Synthesizer(.sine).send(to: "room", level: 0.5)
            }
        }
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        let compiled = try SoundCompiler().compile(Song(), liveLoop: policy)
        #expect(compiled.playbackMode == .seamlessLoop)
        #expect(compiled.events.count == 1)
        #expect(compiled.renderNodes.contains { node in
            if case .busReturn(let bus, let inputs) = node {
                return bus == "room" && inputs.count == 1
            }
            return false
        })
    }

    @Test(.timeLimit(.minutes(3)))
    func trackSendsCannotBeDroppedAfterTerminalOutput() throws {
        let routedOnly = Track("routed") {
            Synthesizer(.sine).output("main")
        }.send(to: "room", level: 1)
        #expect(throws: SoundCompilationError.invalidParameter("Audio processing must precede output routing")) {
            try SoundCompiler().compile(routedOnly)
        }

        let mixed = Track("mixed") {
            Synthesizer(.sine).output("main")
            Synthesizer(.sine)
        }.send(to: "room", level: 1)
        #expect(throws: SoundCompilationError.invalidParameter("Audio processing must precede output routing")) {
            try SoundCompiler().compile(mixed)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func trackSendsRequireAResolvedReturnInFiniteAndLiveCompilation() throws {
        let sound = Track("lead") {
            Synthesizer(.sine)
        }.send(to: "room", level: 0.5)

        #expect(throws: SoundCompilationError.invalidBusRouting(.missingReturn("room"))) {
            try SoundCompiler().compile(sound)
        }

        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        #expect(throws: SoundCompilationError.invalidBusRouting(.missingReturn("room"))) {
            try SoundCompiler().compile(sound, liveLoop: policy)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func forwardReturnRemapsTrackAutomationEffectAndRoots() throws {
        let automation = try GainAutomation(
            .steps(try StepAutomation(values: [0.25, 0.75], cycle: .whole)),
            from: 0.2,
            to: 0.8
        )
        struct Song: Music {
            let automation: GainAutomation

            var body: some Sound {
                BusReturn("room")
                Track("lead") {
                    Synthesizer(.sine)
                        .gain(automation)
                        .effect(.saturation(drive: 0.25))
                }
                .send(to: "room", level: 0.5)
            }
        }

        let compiled = try SoundCompiler().compile(Song(automation: automation))
        let track = try #require(compiled.tracks.first)
        let trackID = try #require(track.renderNodeID)
        let sendID = try #require(compiled.renderNodes.firstIndex { node in
            if case .trackSend = node { return true }
            return false
        })
        let returnID = try #require(compiled.renderNodes.firstIndex { node in
            if case .busReturn = node { return true }
            return false
        })
        #expect(sendID < returnID)
        guard case .trackSend(let sendInput, let bus, let level, let sendTrackID, .postFader) = compiled.renderNodes[sendID] else {
            Issue.record("Expected a post-fader Track send")
            return
        }
        #expect(sendInput == trackID)
        #expect(bus == "room")
        #expect(level == 0.5)
        #expect(sendTrackID == track.id)
        guard case .busReturn(let returnBus, let returnInputs) = compiled.renderNodes[returnID] else {
            Issue.record("Expected a resolved BusReturn")
            return
        }
        #expect(returnBus == "room")
        #expect(returnInputs == [sendID])

        let automationID = try #require(compiled.renderNodes.firstIndex { node in
            if case .gainAutomation(_, let value) = node { return value == automation }
            return false
        })
        let effectID = try #require(compiled.renderNodes.firstIndex { node in
            if case .effect(_, .saturation(drive: 0.25)) = node { return true }
            return false
        })
        #expect(automationID < effectID)
        #expect(effectID < trackID)
        #expect(compiled.renderNodes[trackID] == .track(input: effectID, trackID: track.id))
        #expect(compiled.renderNodes[effectID] == .effect(input: automationID, effect: .saturation(drive: 0.25)))
        #expect(compiled.rootNodeIDs.contains { rootID in
            guard case .mix(let inputs) = compiled.renderNodes[rootID] else { return false }
            return inputs.contains(trackID) && inputs.contains(returnID)
        })
        #expect(compiled.renderNodes.enumerated().allSatisfy { nodeID, node in
            switch node {
            case .source:
                return true
            case .mix(let inputs):
                return inputs.allSatisfy { $0 >= 0 && $0 < nodeID }
            case .effect(let input, _),
                 .gain(let input, _),
                 .gainAutomation(let input, _),
                 .pan(let input, _),
                 .panAutomation(let input, _),
                 .mute(let input),
                 .track(let input, _),
                 .send(let input, _, _),
                 .trackSend(let input, _, _, _, _),
                 .output(let input, _):
                return input >= 0 && input < nodeID
            case .busReturn(_, let inputs):
                return inputs.allSatisfy { $0 >= 0 && $0 < nodeID }
            }
        })
    }

}
