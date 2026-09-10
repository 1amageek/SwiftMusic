/// Failures raised while validating typed harmony and articulation descriptors.
public enum HarmonyError: Error, Equatable, Sendable {
    case invalidScale
    case invalidVoicing
    case invalidArpeggio
    case invalidPortamento
    case invalidDegree
    case missingHarmony
}
