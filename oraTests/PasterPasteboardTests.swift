//
//  PasterPasteboardTests.swift
//  oraTests
//
//  Exercises the pasteboard snapshot/restore pair against a uniquely
//  named test pasteboard (never the general one). The changeCount
//  guard is the regression under test: restore must be skipped when
//  another writer (user copy, clipboard manager) touched the
//  pasteboard after our transcript write.
//

import AppKit
import Testing
@testable import ora

@MainActor
struct PasterPasteboardTests {

    /// Runs `body` with a throwaway named pasteboard and releases it
    /// afterwards so test pasteboards don't accumulate in the pboard
    /// server.
    private func withTestPasteboard(_ body: (NSPasteboard) -> Void) {
        let pb = NSPasteboard(name: NSPasteboard.Name("ora.tests.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        body(pb)
    }

    @Test("restore puts the snapshot back when nobody else wrote")
    func restoreRoundTrip() {
        withTestPasteboard { pb in
            pb.clearContents()
            pb.setString("user clipboard", forType: .string)
            let snapshot = Paster.snapshotPasteboard(pb)

            // The dictation flow: replace with the transcript.
            pb.clearContents()
            pb.setString("transcript", forType: .string)
            let ourChangeCount = pb.changeCount

            Paster.restorePasteboard(pb, from: snapshot, ifChangeCountIs: ourChangeCount)
            #expect(pb.string(forType: .string) == "user clipboard")
        }
    }

    @Test("restore is skipped when a third party wrote after us (regression: clobbered fresh copies)")
    func restoreSkippedAfterForeignWrite() {
        withTestPasteboard { pb in
            pb.clearContents()
            pb.setString("user clipboard", forType: .string)
            let snapshot = Paster.snapshotPasteboard(pb)

            pb.clearContents()
            pb.setString("transcript", forType: .string)
            let ourChangeCount = pb.changeCount

            // A clipboard manager (or the user) copies something new
            // during the 150 ms settle window.
            pb.clearContents()
            pb.setString("fresh copy", forType: .string)

            Paster.restorePasteboard(pb, from: snapshot, ifChangeCountIs: ourChangeCount)
            #expect(pb.string(forType: .string) == "fresh copy")
        }
    }

    @Test("snapshot preserves multiple flavors and restore puts them all back")
    func multiFlavorRoundTrip() {
        withTestPasteboard { pb in
            let flavorA = NSPasteboard.PasteboardType("ora.tests.flavor-a")
            let flavorB = NSPasteboard.PasteboardType("ora.tests.flavor-b")
            pb.clearContents()
            pb.declareTypes([flavorA, flavorB], owner: nil)
            pb.setData(Data([1, 2, 3]), forType: flavorA)
            pb.setData(Data([4, 5]), forType: flavorB)

            let snapshot = Paster.snapshotPasteboard(pb)
            #expect(snapshot.count == 2)

            pb.clearContents()
            pb.setString("transcript", forType: .string)
            Paster.restorePasteboard(pb, from: snapshot, ifChangeCountIs: pb.changeCount)

            #expect(pb.data(forType: flavorA) == Data([1, 2, 3]))
            #expect(pb.data(forType: flavorB) == Data([4, 5]))
        }
    }

    @Test("restoring an empty snapshot leaves the pasteboard cleared")
    func emptySnapshotClears() {
        withTestPasteboard { pb in
            pb.clearContents()
            let snapshot = Paster.snapshotPasteboard(pb)

            pb.clearContents()
            pb.setString("transcript", forType: .string)
            Paster.restorePasteboard(pb, from: snapshot, ifChangeCountIs: pb.changeCount)

            #expect(pb.string(forType: .string) == nil)
        }
    }
}
