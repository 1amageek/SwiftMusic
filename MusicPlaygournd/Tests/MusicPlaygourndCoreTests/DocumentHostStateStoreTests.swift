import AVFoundation
import Foundation
import MusicPlaygourndCore
import Testing
@testable import MusicPlaygourndApp

struct DocumentHostStateStoreTests {
    @Test(.timeLimit(.minutes(1)))
    func atomicSidecarRetainsHostStateAndCanonicalDocumentIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let document = root.appending(path: "Session.swift")
        let source = "// 🎵 private score"
        try source.write(to: document, atomically: true, encoding: .utf8)
        let alias = root.appending(path: "Alias.swift")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: document)
        let store = DocumentHostStateStore(directory: root.appending(path: "Host"))
        let input = try MIDIEndpointID(11)
        let output = try MIDIEndpointID(12)
        let binding = DocumentHostStateStore.LearnBinding(endpoint: input, channel: 1, controller: 74,
            address: .init(revision: 5, target: .source(0), parameter: .cutoffHz), range: 20...20_000)
        let effectID = try HostedAudioUnitID(componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_HighPassFilter, componentManufacturer: kAudioUnitManufacturer_Apple)
        let effect = try HostedAudioUnitState(id: effectID,
            data: PropertyListSerialization.data(fromPropertyList: ["value": 123], format: .binary, options: 0))
        var state = DocumentHostStateStore.State(adoptedSourceDigest: DocumentHostStateStore.sourceDigest(source),
            route: .init(input: input, output: output, sendsLoopNotes: true, channel: 1, clockMode: .send(output: output)),
            effect: effect, effectBypassed: true, bindings: [binding])
        #expect(try store.load(for: document) == nil)
        try store.save(state, for: document)
        #expect(try store.fileURL(for: alias) == store.fileURL(for: document))
        let loaded = try #require(try store.load(for: alias))
        #expect(loaded.route == state.route)
        #expect(loaded.effect == effect && loaded.effectBypassed)
        #expect(loaded.bindings == [binding])
        #expect(loaded.adoptedSourceDigest == DocumentHostStateStore.sourceDigest(source))
        #expect(loaded.adoptedSourceDigest != DocumentHostStateStore.sourceDigest(source + " "))
        let file = try store.fileURL(for: document)
        let previous = try Data(contentsOf: file)
        #expect(previous.starts(with: Data("bplist00".utf8)))
        #expect(previous.count <= DocumentHostStateStore.maximumBytes)
        #expect(previous.range(of: Data(source.utf8)) == nil)
        state.bindings.append(binding)
        #expect(throws: DocumentHostStateStore.Failure.self) { try store.save(state, for: document) }
        #expect(try Data(contentsOf: file) == previous)
        state.bindings = Array(repeating: binding, count: DocumentHostStateStore.maximumBindingCount + 1)
        #expect(throws: DocumentHostStateStore.Failure.tooLarge) { try store.save(state, for: document) }
        #expect(try Data(contentsOf: file) == previous)
        state.bindings = [binding]
        state.effect = try HostedAudioUnitState(id: effectID,
            data: PropertyListSerialization.data(fromPropertyList: ["payload": Data(repeating: 0, count: DocumentHostStateStore.maximumBytes - 128)],
                format: .binary, options: 0))
        #expect(throws: DocumentHostStateStore.Failure.tooLarge) { try store.save(state, for: document) }
        #expect(try Data(contentsOf: file) == previous)
        #expect(try String(contentsOf: document, encoding: .utf8) == source)
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsForeignOversizedAndInvalidDecodedSettings() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let store = DocumentHostStateStore(directory: root)
        let first = root.appending(path: "First.swift")
        let second = root.appending(path: "Second.swift")
        let state = DocumentHostStateStore.State(adoptedSourceDigest: nil, route: .disabled,
            effect: nil, effectBypassed: false, bindings: [])
        #expect(throws: DocumentHostStateStore.Failure.invalidDocument) { try store.save(state, for: root) }
        let directoryWithoutSlash = URL(fileURLWithPath: root.path, isDirectory: false)
        #expect(throws: DocumentHostStateStore.Failure.invalidDocument) { try store.save(state, for: directoryWithoutSlash) }
        let plainText = root.appending(path: "Score.txt")
        try store.save(state, for: plainText)
        #expect(try store.load(for: plainText)?.route == .disabled)
        try store.save(state, for: first)
        let original = try Data(contentsOf: store.fileURL(for: first))
        try original.write(to: store.fileURL(for: second))
        #expect(throws: DocumentHostStateStore.Failure.identityMismatch) { _ = try store.load(for: second) }
        var envelope = try #require(try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any])
        var storedState = try #require(envelope["state"] as? [String: Any])
        var route = try #require(storedState["route"] as? [String: Any])
        route["channel"] = 0
        storedState["route"] = route
        envelope["state"] = storedState
        try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
            .write(to: store.fileURL(for: first))
        #expect(throws: MIDIError.self) { _ = try store.load(for: first) }
        try Data(repeating: 0, count: DocumentHostStateStore.maximumBytes + 1).write(to: store.fileURL(for: first))
        #expect(throws: DocumentHostStateStore.Failure.tooLarge) { _ = try store.load(for: first) }
    }
}
