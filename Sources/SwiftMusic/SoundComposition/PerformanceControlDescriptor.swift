import Observation

/// A MainActor-owned mapping from a stable control identity to a model key path.
@MainActor
public enum PerformanceControlDescriptor<Model: AnyObject & Observable & Sendable> {
    case double(
        id: String,
        label: String?,
        range: ClosedRange<Double>,
        role: PerformanceControlRole,
        keyPath: ReferenceWritableKeyPath<Model, Double>
    )
    case position(
        id: String,
        label: String?,
        xRange: ClosedRange<Double>,
        depthRange: ClosedRange<Double>,
        keyPath: ReferenceWritableKeyPath<Model, SpatialPosition>
    )

    public static func mappedDouble(
        id: String,
        range: ClosedRange<Double>,
        keyPath: ReferenceWritableKeyPath<Model, Double>,
        role: PerformanceControlRole = .scalar,
        label: String? = nil
    ) -> Self {
        .double(id: id, label: label, range: range, role: role, keyPath: keyPath)
    }

    public static func mappedBPM(
        id: String,
        range: ClosedRange<Double>,
        keyPath: ReferenceWritableKeyPath<Model, Double>,
        label: String? = nil
    ) -> Self {
        mappedDouble(id: id, range: range, keyPath: keyPath, role: .beatsPerMinute, label: label)
    }

    public static func mappedPosition(
        id: String,
        xRange: ClosedRange<Double> = -1...1,
        depthRange: ClosedRange<Double> = 0...1,
        keyPath: ReferenceWritableKeyPath<Model, SpatialPosition>,
        label: String? = nil
    ) -> Self {
        .position(id: id, label: label, xRange: xRange, depthRange: depthRange, keyPath: keyPath)
    }
}
