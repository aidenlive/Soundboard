import XCTest
@testable import SoundboardUI

/// Saved data must survive app updates: missing or unknown keys fall back to defaults instead of
/// failing the whole file.
final class PersistenceTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try Storage.decoder.decode(T.self, from: Data(json.utf8))
    }

    func testPreferencesFromEmptyObjectAreDefaults() throws {
        XCTAssertEqual(try decode(Preferences.self, "{}"), Preferences())
    }

    func testPreferencesKeepKnownValuesAndDefaultTheRest() throws {
        let p = try decode(Preferences.self, #"{"mixing":{"phraseBeats":32,"unknown":1},"audio":{"bufferFrames":"bad"}}"#)
        XCTAssertEqual(p.mixing.phraseBeats, 32)
        XCTAssertEqual(p.mixing.transitionBeats, MixingPrefs().transitionBeats)
        XCTAssertEqual(p.audio.bufferFrames, AudioPrefs().bufferFrames)
    }

    func testPreferencesRoundTrip() throws {
        var p = Preferences()
        p.audio.masterOutputID = "usb-1"
        p.mixing.transition = .echoOut
        p.session.restoreLastSession = false
        let data = try Storage.encoder.encode(p)
        XCTAssertEqual(try Storage.decoder.decode(Preferences.self, from: data), p)
    }

    func testSessionDocumentToleratesMissingFieldsAndPadsDecks() throws {
        let id = UUID()
        let doc = try decode(SessionDocument.self, #"{"id":"\#(id.uuidString)","decks":[{"position":1234}]}"#)
        XCTAssertEqual(doc.id, id)
        XCTAssertEqual(doc.decks.count, 2)
        XCTAssertEqual(doc.decks[0].position, 1234)
        XCTAssertEqual(doc.decks[0].fader, 1)
        XCTAssertEqual(doc.mixer, MixerSnapshot())
        XCTAssertEqual(doc.workspace.librarySource, .all)
    }

    func testSessionDocumentRoundTrip() throws {
        var doc = SessionDocument(id: UUID())
        doc.decks[1].trackID = UUID()
        doc.decks[1].loop = SavedLoop(inFrame: 100, outFrame: 200)
        doc.decks[1].loopActive = true
        doc.queue = [UUID(), UUID()]
        doc.workspace.librarySource = .playlist(UUID())
        doc.workspace.librarySort = .bpm
        doc.mixer.crossfader = 0.25
        let data = try Storage.encoder.encode(doc)
        XCTAssertEqual(try Storage.decoder.decode(SessionDocument.self, from: data), doc)
    }

    func testNewSessionParksCrossfaderOnDeckA() {
        XCTAssertEqual(MixerSnapshot().crossfader, -1)
    }

    func testUniqueNames() {
        XCTAssertEqual(LibraryStore.uniqueName("Set", among: []), "Set")
        XCTAssertEqual(LibraryStore.uniqueName("Set", among: ["Set"]), "Set 2")
        XCTAssertEqual(LibraryStore.uniqueName("Set", among: ["Set", "Set 2"]), "Set 3")
        XCTAssertEqual(LibraryStore.uniqueName("  ", among: []), "Untitled")
    }

    func testTrackLocationRoundTrip() throws {
        let a = TrackLocation.library(fileName: "x.m4a")
        let b = TrackLocation.reference(bookmark: Data([1, 2, 3]), path: "/Music/y.flac")
        for loc in [a, b] {
            XCTAssertEqual(try Storage.decoder.decode(TrackLocation.self, from: Storage.encoder.encode(loc)), loc)
        }
    }

    func testDurationFormat() {
        XCTAssertEqual(Format.duration(0), "")
        XCTAssertEqual(Format.duration(61.4), "1:01")
        XCTAssertEqual(Format.duration(3725), "1:02:05")
    }

    func testCorruptFileIsMovedAsideNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("library.json")
        try Data("{not json".utf8).write(to: file)
        var quarantined = false
        XCTAssertNil(Storage.read(LibraryDocument.self, from: file, quarantined: &quarantined))
        XCTAssertTrue(quarantined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(aside.count, 1)
        XCTAssertTrue(aside[0].hasPrefix("library.json.corrupt-"))
    }
}
