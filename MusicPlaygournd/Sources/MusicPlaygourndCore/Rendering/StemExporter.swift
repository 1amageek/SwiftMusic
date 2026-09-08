import AVFoundation
import Foundation

/// Writes a complete set of prepared stems through one adjacent staging directory.
public enum StemExporter {
    public static let maximumStemCount = 32

    @discardableResult
    public static func export(_ stems: [PreparedStem], to destination: URL) throws -> [StemExportManifest] {
        guard destination.isFileURL, destination.path.hasPrefix("/"), destination.path != "/" else {
            throw StemExportError.invalidDestination
        }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else {
            throw StemExportError.destinationExists
        }
        guard stems.count <= maximumStemCount else {
            throw StemExportError.tooManyStems
        }
        var trackIDs = Set<Int>()
        for stem in stems {
            guard trackIDs.insert(stem.trackID).inserted else {
                throw StemExportError.duplicateTrack
            }
        }
        if let first = stems.first {
            let synchronized = stems.dropFirst().allSatisfy {
                $0.sampleRate == first.sampleRate &&
                $0.bpm == first.bpm &&
                $0.beatsPerBar == first.beatsPerBar &&
                $0.beatCount == first.beatCount &&
                $0.frameCount == first.frameCount
            }
            guard synchronized else {
                throw StemExportError.invalidStem("Stem metadata is not synchronized.")
            }
        }

        let parent = destination.deletingLastPathComponent()
        let staging = parent.appending(path: ".\(destination.lastPathComponent).staging-\(UUID().uuidString)")
        var published = false
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            var manifests: [StemExportManifest] = []
            manifests.reserveCapacity(stems.count)
            for stem in stems {
                try Task.checkCancellation()
                let fileName = "\(stem.trackID)-\(sanitizedLabel(stem.label)).wav"
                let fileURL = staging.appending(path: fileName)
                try write(stem, to: fileURL)
                manifests.append(StemExportManifest(stem: stem, fileName: fileName))
            }
            try Task.checkCancellation()
            guard !manager.fileExists(atPath: destination.path) else {
                throw StemExportError.destinationExists
            }
            try manager.moveItem(at: staging, to: destination)
            published = true
            return manifests
        } catch {
            let original: Error = error is StemExportError
                ? error
                : StemExportError.stagingFailed(error.localizedDescription)
            if !published {
                try removeStaging(staging, manager: manager, preserving: original)
            }
            if error is CancellationError {
                throw CancellationError()
            }
            throw original
        }
    }

    private static func removeStaging(
        _ staging: URL,
        manager: FileManager,
        preserving original: Error
    ) throws {
        guard manager.fileExists(atPath: staging.path) else { return }
        do {
            try manager.removeItem(at: staging)
        } catch {
            throw StemExportError.cleanupFailed(
                original: String(describing: original),
                cleanup: error.localizedDescription
            )
        }
    }

    private static func write(_ stem: PreparedStem, to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: stem.sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw StemExportError.writeFailed("Unable to create Float32 stereo format.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(stem.frameCount)),
              let channels = buffer.floatChannelData
        else {
            throw StemExportError.writeFailed("Unable to allocate a Float32 stereo buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(stem.frameCount)
        for frame in 0..<stem.frameCount {
            channels[0][frame] = stem.samples[frame * 2]
            channels[1][frame] = stem.samples[frame * 2 + 1]
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            file.close()
        } catch {
            throw StemExportError.writeFailed(error.localizedDescription)
        }
    }

    private static func sanitizedLabel(_ label: String) -> String {
        let scalars = label.unicodeScalars.map { scalar -> Character in
            if scalar.value >= 48 && scalar.value <= 57
                || scalar.value >= 65 && scalar.value <= 90
                || scalar.value >= 97 && scalar.value <= 122
                || scalar.value == 45 || scalar.value == 95 {
                return Character(String(scalar))
            }
            return "_"
        }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return value.isEmpty ? "track" : String(value.prefix(96))
    }
}
