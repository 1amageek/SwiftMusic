import Testing
import SwiftMusic

struct OrderedMixEffectPerformanceTests {
    @Test(.timeLimit(.minutes(3)))
    func saturationIsAnOrderedDescriptorAndZeroDriveRemainsNeutral() throws {
        let saturation = AudioEffect.saturation(drive: 0)
        let reverb = AudioEffect.reverb(roomSize: 0.5, wet: 0.25)
        let compiled = try SoundCompiler().compile(
            Synthesizer(.sine)
                .effect(saturation)
                .effect(reverb)
        )

        #expect(compiled.renderNodes == [
            .source(sourceID: 0),
            .effect(input: 0, effect: saturation),
            .effect(input: 1, effect: reverb)
        ])
        #expect(compiled.rootNodeIDs == [2])
    }

    @Test(.timeLimit(.minutes(3)))
    func saturationAcceptsFiniteNonnegativeDrive() throws {
        for drive in [0.0, 0.5, Double.greatestFiniteMagnitude] {
            let effect = AudioEffect.saturation(drive: drive)
            let compiled = try SoundCompiler().compile(
                Synthesizer(.square).effect(effect)
            )
            #expect(compiled.renderNodes.last == .effect(input: 0, effect: effect))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func saturationRejectsNegativeAndNonfiniteDrive() throws {
        for drive in [-0.001, -Double.greatestFiniteMagnitude, .infinity, -.infinity, .nan] {
            #expect(throws: SoundCompilationError.invalidParameter("Saturation drive must be finite and nonnegative")) {
                try SoundCompiler().compile(
                    Synthesizer(.triangle).effect(.saturation(drive: drive))
                )
            }
        }
    }
}
