/// Failures raised while validating or compiling deterministic rhythm transforms.
public enum RhythmTransformError: Error, Equatable, Sendable {
    case invalidSwing
    case invalidEuclidean
    case invalidRatchet
    case invalidProbability
    case invalidHumanization
    case invalidPeriodicTransform
    case negativeEventTime
    case crossingCycle
    case timingOverflow
    case deterministicRandomness
}
