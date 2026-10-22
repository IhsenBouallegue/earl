import Foundation
import Testing
@testable import Earl

/// U-0: the demo meetings load through the real code and show what the
/// snapshots promise.
struct DemoDataTests {
    private func library() throws -> (store: MeetingStore, ids: DemoData.IDs, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earl-demo-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MeetingStore(root: root)
        let ids = try DemoData(store: store, now: Date()).writeLibrary()
        return (store, ids, root)
    }

    @Test func libraryLoadsWithEveryState() throws {
        let (store, ids, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let meetings = store.loadAll()
        #expect(meetings.count >= 9) // S-1, S-2: series meetings
        #expect(Set(meetings.map { Calendar.current.startOfDay(for: $0.info.startedAt) }).count >= 4) // several days
        #expect(meetings.first { $0.id == ids.failed }?.info.status == .failed)
        #expect(meetings.contains { $0.info.language == "de" })
    }

    @Test func productSyncHasEveryKindOfSpeaker() throws {
        let (store, ids, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try #require(store.load(root.appendingPathComponent(ids.productSync)))
        #expect(meeting.speakers.count == 4)
        #expect(Set(meeting.speakers.compactMap(\.nameSource)) == [.confirmed, .guessed, .voice])
        #expect(meeting.speakers.contains { $0.name == nil })
        let guess = try #require(meeting.turns.first { $0.speakerID == "S2" })
        #expect(Speaker.badge(for: guess, in: meeting.speakers).name == "Sarah?")
        #expect(meeting.info.attendees?.count == 5)
        #expect(!meeting.summary.isEmpty)
    }

    @Test func todosHaveMineAndOthers() throws {
        let (store, _, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let items = store.loadAll().flatMap { ActionItems.parse($0.summary, meetingID: $0.id) }
        let mine = items.filter { ActionItems.isMine(owner: $0.owner, userName: DemoData.me.name) }
        #expect(mine.count >= 3)
        #expect(items.count > mine.count)
        #expect(items.contains { $0.done })
    }

    @Test func demoModeIsOffInTests() {
        #expect(!DemoMode.isActive)
        #expect(DemoMode.home == nil)
    }
}
