internal struct _ScoreCompilationContext {
    let limits: ScoreCompiler.Limits
    var events: [CompiledNoteEvent] = []
    var tracks: [CompiledTrack] = []
    var currentTrackID: Int?

    mutating func visit(score: any Score, depth: Int) throws -> MusicalTime {
        guard depth <= limits.maximumDepth else {
            throw ScoreCompilationError.maximumDepthExceeded(limit: limits.maximumDepth)
        }

        if let primitive = score as? any _ScorePrimitive {
            return try primitive._visit(in: &self, depth: depth)
        }

        let childDepth = try descendingDepth(from: depth)
        let body = score.body
        return try visit(score: body, depth: childDepth)
    }

    mutating func visit(group: ScoreGroup, depth: Int) throws -> MusicalTime {
        var extent = MusicalTime.zero
        for element in group.elements {
            let childDepth = try descendingDepth(from: depth)
            let childExtent = try visit(score: element, depth: childDepth)
            if childExtent > extent {
                extent = childExtent
            }
        }
        return extent
    }

    mutating func visit(track: Track, depth: Int) throws -> MusicalTime {
        guard tracks.count < limits.maximumTracks else {
            throw ScoreCompilationError.maximumTracksExceeded(limit: limits.maximumTracks)
        }

        let trackID = tracks.count
        tracks.append(
            CompiledTrack(
                id: trackID,
                name: track.name,
                parentID: currentTrackID
            )
        )

        let previousTrackID = currentTrackID
        currentTrackID = trackID
        do {
            let childDepth = try descendingDepth(from: depth)
            let extent = try visit(score: track.content, depth: childDepth)
            currentTrackID = previousTrackID
            return extent
        } catch {
            currentTrackID = previousTrackID
            throw error
        }
    }

    mutating func append(note: Note) throws -> MusicalTime {
        let end = try checkedEnd(start: note.start, duration: note.duration, requirePositive: true)
        guard events.count < limits.maximumEvents else {
            throw ScoreCompilationError.maximumEventsExceeded(limit: limits.maximumEvents)
        }

        events.append(
            CompiledNoteEvent(
                pitch: note.pitch,
                start: note.start,
                duration: note.duration,
                trackID: currentTrackID,
                traversalIndex: events.count
            )
        )
        return end
    }

    mutating func account(rest: Rest) throws -> MusicalTime {
        try checkedEnd(start: rest.start, duration: rest.duration, requirePositive: false)
    }

    func finish(extent: MusicalTime) -> CompiledScore {
        var orderedEvents = events
        orderedEvents.sort {
            if $0.start != $1.start {
                return $0.start < $1.start
            }
            return $0.traversalIndex < $1.traversalIndex
        }
        return CompiledScore(
            events: orderedEvents,
            tracks: tracks,
            extent: extent
        )
    }

    private func descendingDepth(from depth: Int) throws -> Int {
        guard depth < limits.maximumDepth else {
            throw ScoreCompilationError.maximumDepthExceeded(limit: limits.maximumDepth)
        }
        return depth + 1
    }

    private func checkedEnd(
        start: MusicalTime,
        duration: MusicalTime,
        requirePositive: Bool
    ) throws -> MusicalTime {
        if requirePositive {
            guard duration > MusicalTime.zero else {
                throw ScoreCompilationError.zeroDuration
            }
        }
        do {
            return try start.adding(duration)
        } catch MusicalTimeError.overflow {
            throw ScoreCompilationError.timeOverflow
        }
    }
}
