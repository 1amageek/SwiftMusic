/// Visits structural children synchronously, without materializing an existential array.
internal protocol _SoundChildren {
    func _forEachChild(_ visit: (any Sound) throws -> Void) throws
}
