import Foundation
import MusicPlaygourndCore
import Testing

struct RenderWorkerFramingTests {
    @Test
    func binaryPropertyListRoundTripsWithBigEndianLength() throws {
        let command = RenderWorkerCommand.render(revision: 7, generation: 3, overrides: [])
        let frame = try RenderWorkerFraming.encode(command)
        #expect(frame.count > RenderWorkerFraming.headerByteCount)
        let declared = frame.prefix(4).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        #expect(Int(declared) == frame.count - RenderWorkerFraming.headerByteCount)
        #expect(frame[4] == 0x62) // binary property-list marker

        var parser = RenderWorkerFrameParser()
        var payloads = [Data]()
        for byte in frame {
            payloads += try parser.append(Data([byte]))
        }
        try parser.finish()
        #expect(payloads.count == 1)
        let decoded = try RenderWorkerFraming.decode(RenderWorkerCommand.self, payload: payloads[0])
        #expect(decoded == command)
    }

    @Test
    func parserAcceptsCoalescedFrames() throws {
        let first = try RenderWorkerFraming.encode(RenderWorkerCommand.shutdown)
        let second = try RenderWorkerFraming.encode(RenderWorkerCommand.render(revision: 2, generation: 9, overrides: []))
        var bytes = Data(first)
        bytes.append(second)
        var parser = RenderWorkerFrameParser()
        let payloads = try parser.append(bytes)
        try parser.finish()
        #expect(payloads.count == 2)
        #expect(try RenderWorkerFraming.decode(RenderWorkerCommand.self, payload: payloads[0]) == .shutdown)
        #expect(try RenderWorkerFraming.decode(RenderWorkerCommand.self, payload: payloads[1]) == .render(revision: 2, generation: 9, overrides: []))
    }

    @Test
    func parserRejectsZeroOverflowAndTruncatedFrames() throws {
        for header in [Data([0, 0, 0, 0]), Data([0xff, 0xff, 0xff, 0xff])] {
            var parser = RenderWorkerFrameParser()
            #expect(throws: EvaluationError.self) { try parser.append(header) }
        }

        var truncated = RenderWorkerFrameParser()
        _ = try truncated.append(Data([0, 0, 0, 3, 0x62]))
        #expect(throws: EvaluationError.self) { try truncated.finish() }
    }

    @Test
    func malformedPayloadDoesNotBecomeACommand() throws {
        var parser = RenderWorkerFrameParser()
        let frame = Data([0, 0, 0, 2, 0x62, 0x70])
        let payload = try #require(parser.append(frame).first)
        #expect(throws: Error.self) {
            _ = try RenderWorkerFraming.decode(RenderWorkerCommand.self, payload: payload)
        }
    }
}
