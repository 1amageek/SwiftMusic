import Foundation

internal func _dynamicsDurationSeconds(_ duration: Duration) throws -> Double {
    guard duration >= .zero else {
        throw SoundParameterError.invalidValue("dynamics duration")
    }
    let components = duration.components
    let result = Double(components.seconds) + Double(components.attoseconds) / 1e18
    guard result.isFinite, result >= 0 else {
        throw SoundParameterError.invalidValue("dynamics duration")
    }
    return result
}

internal func _dynamicsBusNameIsValid(_ name: String) -> Bool {
    name.contains { !$0.isWhitespace }
}
