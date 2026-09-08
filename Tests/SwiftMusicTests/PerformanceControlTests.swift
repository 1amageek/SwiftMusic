import Foundation
import Observation
import Testing
@testable import SwiftMusic

@MainActor
struct PerformanceControlTests {
    @Observable
    final class Model: PerformanceControllable {
        var performanceModelID = "control-test-model"
        var gain = 0.5
        var beatsPerMinute = 120.0
        var position = SpatialPosition(x: 0, depth: 0)

        let performanceControls: PerformanceControlSet<Model>

        init() throws {
            performanceControls = try PerformanceControlSet([
                .mappedDouble(id: "gain", range: 0...1, keyPath: \Model.gain, label: "Gain"),
                .mappedBPM(id: "tempo", range: 40...240, keyPath: \Model.beatsPerMinute, label: "Tempo"),
                .mappedPosition(id: "position", keyPath: \Model.position, label: "Position")
            ])
        }
    }

    @Observable
    final class ThrowingModel: PerformanceControllable {
        let performanceModelID = "throwing-control-model"

        var performanceControls: PerformanceControlSet<ThrowingModel> {
            get throws {
                throw PerformanceControlError.invalidMapping("test provider failure")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func metadataIsWireSafeAndExcludesKeyPaths() throws {
        let model = try Model()
        let metadata = try model.performanceControlMetadata()

        #expect(metadata.map(\.controlID) == ["gain", "tempo", "position"])
        #expect(metadata[0].modelID == model.performanceModelID)
        #expect(metadata[0].value == .double(0.5))
        #expect(metadata[1].domain == .double(range: 40...240, role: .beatsPerMinute))
        #expect(metadata[2].value == .position(.init(x: 0, depth: 0)))

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode([PerformanceControlMetadata].self, from: data)
        #expect(decoded == metadata)
    }

    @Test(.timeLimit(.minutes(1)))
    func decodedMetadataRejectsInvalidCatalogsAndPreservesNativeLabels() throws {
        let model = try Model()
        let valid = try model.performanceControlMetadata()
        try PerformanceControlMetadata.validate(valid)
        let unlabeled = try PerformanceControlSet<Model>([
            .mappedDouble(id: "gain", range: 0...1, keyPath: \Model.gain, label: "")
        ]).metadata(modelID: model.performanceModelID, for: model)
        try PerformanceControlMetadata.validate(unlabeled)
        try PerformanceControlMetadata.validate([])
        func entry(modelID: String = "model", id: String = "gain",
                   domain: PerformanceControlDomain = .double(range: 0...1, role: .scalar),
                   value: PerformanceControlValue = .double(0.5)) -> PerformanceControlMetadata {
            .init(modelID: modelID, controlID: id, label: "", domain: domain, value: value)
        }
        let malformed: [[PerformanceControlMetadata]] = [
            [entry(modelID: "")], [entry(id: "")],
            [entry(), entry()], [entry(), entry(modelID: "other", id: "other")],
            [entry(value: .double(.nan))], [entry(value: .double(2))],
            [entry(domain: .double(range: 0...Double.infinity, role: .scalar))],
            [entry(value: .position(.init(x: 0, depth: 0)))],
            [entry(domain: .position(xRange: -2...1, depthRange: 0...1),
                   value: .position(.init(x: 0, depth: 0)))],
            [entry(domain: .position(xRange: -1...1, depthRange: 0...1),
                   value: .position(.init(x: 0, depth: 2)))],
            [entry(domain: .double(range: 0...240, role: .beatsPerMinute))],
            [valid[1], entry(modelID: model.performanceModelID, id: "second-tempo", domain: valid[1].domain, value: .double(120))],
            Array(repeating: entry(), count: 1_025)
        ]
        for catalog in malformed {
            #expect(throws: PerformanceControlError.self) {
                try PerformanceControlMetadata.validate(catalog)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func completeCandidateValidatesBeforeMutation() throws {
        let model = try Model()
        let invalid: [String: PerformanceControlValue] = [
            "gain": .double(0.25),
            "tempo": .double(.nan),
            "position": .position(.init(x: 0.5, depth: 0.5))
        ]

        #expect(throws: PerformanceControlError.self) {
            try model.applyPerformanceControls(invalid)
        }
        #expect(model.gain == 0.5)
        #expect(model.beatsPerMinute == 120)
        #expect(model.position == .init(x: 0, depth: 0))

        try model.applyPerformanceControls([
            "gain": .double(0.25),
            "tempo": .double(140),
            "position": .position(.init(x: -0.5, depth: 0.75))
        ])
        #expect(model.gain == 0.25)
        #expect(model.beatsPerMinute == 140)
        #expect(model.position == .init(x: -0.5, depth: 0.75))
    }

    @Test(.timeLimit(.minutes(1)))
    func providerAndPositionAdmissionFailBeforeMutation() throws {
        let throwing = ThrowingModel()
        #expect(throws: PerformanceControlError.self) {
            try throwing.performanceControlMetadata()
        }

        let model = try Model()
        let validValues: [String: PerformanceControlValue] = [
            "gain": .double(0.25),
            "tempo": .double(140),
            "position": .position(.init(x: 0.5, depth: 0.5))
        ]
        model.performanceModelID = ""
        #expect(throws: PerformanceControlError.self) {
            try model.applyPerformanceControls(validValues)
        }
        #expect(model.gain == 0.5)
        #expect(model.beatsPerMinute == 120)
        #expect(model.position == .init(x: 0, depth: 0))

        model.performanceModelID = "control-test-model"
        let invalidPosition: [String: PerformanceControlValue] = [
            "gain": .double(0.25),
            "tempo": .double(140),
            "position": .position(.init(x: 0.5, depth: 1.5))
        ]
        #expect(throws: PerformanceControlError.self) {
            try model.applyPerformanceControls(invalidPosition)
        }
        #expect(model.gain == 0.5)
        #expect(model.beatsPerMinute == 120)
        #expect(model.position == .init(x: 0, depth: 0))
    }

    @Test(.timeLimit(.minutes(1)))
    func duplicateAndMalformedMappingsFailTyped() throws {
        #expect(throws: PerformanceControlError.self) {
            try PerformanceControlSet([
                .mappedDouble(id: "same", range: 0...1, keyPath: \Model.gain),
                .mappedDouble(id: "same", range: 0...1, keyPath: \Model.beatsPerMinute)
            ])
        }
        #expect(throws: PerformanceControlError.self) {
            try PerformanceControlSet([
                .mappedBPM(id: "first", range: 40...240, keyPath: \Model.beatsPerMinute),
                .mappedBPM(id: "second", range: 40...240, keyPath: \Model.beatsPerMinute)
            ])
        }
        #expect(throws: PerformanceControlError.self) {
            try PerformanceControlSet([
                .mappedDouble(id: "bad", range: 0...Double.infinity, keyPath: \Model.gain)
            ])
        }
        #expect(throws: PerformanceControlError.self) {
            try PerformanceControlSet([
                .mappedDouble(id: "gain-a", range: 0...1, keyPath: \Model.gain),
                .mappedDouble(id: "gain-b", range: 0...1, keyPath: \Model.gain)
            ])
        }
        #expect(throws: PerformanceControlError.self) {
            try PerformanceControlSet([
                .mappedPosition(id: "outside", xRange: -2...1, keyPath: \Model.position)
            ])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func completeSetRejectsMissingUnknownAndWrongDomainValues() throws {
        let model = try Model()
        #expect(throws: PerformanceControlError.self) {
            try model.applyPerformanceControls([
                "gain": .double(0.1),
                "tempo": .double(100)
            ])
        }
        #expect(throws: PerformanceControlError.self) {
            try model.applyPerformanceControls([
                "gain": .double(0.1),
                "tempo": .double(100),
                "position": .position(.init(x: 0, depth: 0)),
                "unknown": .double(1)
            ])
        }
        #expect(throws: PerformanceControlError.self) {
            try model.applyPerformanceControls([
                "gain": .position(.init(x: 0, depth: 0)),
                "tempo": .double(100),
                "position": .position(.init(x: 0, depth: 0))
            ])
        }
        #expect(model.gain == 0.5)
        #expect(model.beatsPerMinute == 120)
    }
}
