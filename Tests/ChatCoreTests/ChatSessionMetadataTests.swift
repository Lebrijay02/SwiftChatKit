import Foundation
import Testing
@testable import ChatCore

/// Stands in for a host's own per-session record — the FRIDA app keeps a log of
/// build runs here, and a run still marked running at load time is how it knows
/// the app was killed mid-build.
@MainActor
private final class HostRecord {
    var runs: [String] = []
    var loaded: [String: ChatValue]?

    var metadata: [String: ChatValue] {
        ["runs": ChatValue.array(runs.map { ChatValue.string($0) })]
    }

    func take(_ metadata: [String: ChatValue]) {
        loaded = metadata
        runs = metadata["runs"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

@Suite("StoredSession — host metadata")
@MainActor
struct ChatSessionMetadataTests {

    private func makeDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    }

    @Test("Host metadata is written on save and handed back on load")
    func roundTrip() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let record = HostRecord()
        let session = ChatSession(configuration: ChatSessionConfiguration(
            backend: MockBackend(),
            permissionStore: EphemeralPermissionStore(),
            historyStore: ChatHistoryStore(directory: directory),
            sessionMetadata: { [record] in record.metadata },
            onSessionMetadataLoaded: { [record] metadata in record.take(metadata) }))

        session.load(StoredSession(title: "t", messages: [
            StoredMessage(from: ChatMessage(role: .user, content: "hello"))
        ]))
        // Set after loading, which clears the record as reopening a session should.
        record.runs = ["run-1", "run-2"]
        #expect(session.save())

        let stored = try #require(ChatHistoryStore(directory: directory).load(session.sessionID))
        #expect(stored.metadata?["runs"] == .array([.string("run-1"), .string("run-2")]))

        // Reopening restores the host's own record alongside the transcript.
        record.runs = []
        session.load(stored)
        #expect(record.runs == ["run-1", "run-2"])
    }

    @Test("A transcript saved before the host had metadata still loads")
    func absentMetadata() {
        let record = HostRecord()
        let session = ChatSession(configuration: ChatSessionConfiguration(
            backend: MockBackend(),
            permissionStore: EphemeralPermissionStore(),
            onSessionMetadataLoaded: { [record] metadata in record.take(metadata) }))

        session.load(StoredSession(title: "old", messages: []))
        // Called with an empty bag rather than skipped: the host has to clear
        // the last session's state either way.
        #expect(record.loaded == [:])
    }

    @Test("A session with no metadata hook writes none")
    func noHook() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = ChatSession(configuration: ChatSessionConfiguration(
            backend: MockBackend(),
            permissionStore: EphemeralPermissionStore(),
            historyStore: ChatHistoryStore(directory: directory)))
        session.load(StoredSession(title: "t", messages: [
            StoredMessage(from: ChatMessage(role: .user, content: "hello"))
        ]))
        #expect(session.save())

        let stored = try #require(ChatHistoryStore(directory: directory).load(session.sessionID))
        #expect(stored.metadata == nil)
    }

    @Test("A file written without the field decodes as no metadata")
    func decodesLegacyFile() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","title":"old","createdAt":"2024-01-01T00:00:00Z",
         "updatedAt":"2024-01-01T00:00:00Z","messages":[]}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(StoredSession.self, from: json).metadata == nil)
    }

    @Test("snapshot() exposes what save would write, for a host with its own store")
    func snapshotCarriesMetadata() {
        let record = HostRecord()
        let session = ChatSession(configuration: ChatSessionConfiguration(
            backend: MockBackend(),
            permissionStore: EphemeralPermissionStore(),
            sessionMetadata: { [record] in record.metadata }))

        session.load(StoredSession(title: "t", messages: [
            StoredMessage(from: ChatMessage(role: .user, content: "hello"))
        ]))
        record.runs = ["run-1"]
        let snapshot = session.snapshot()
        #expect(snapshot.id == session.sessionID)
        #expect(snapshot.metadata?["runs"] == .array([.string("run-1")]))
    }
}
