//
//  SampleSinkTests.swift
//  oraTests
//
//  Locks down the append/drain contract of the per-session sample
//  accumulator introduced by the cancel/re-press race fix. The
//  property that matters: a sink belongs to ONE recording session, so
//  draining it must return exactly what that session appended and
//  leave it empty — a racing old session can never see a new
//  session's audio because they hold different sinks.
//

import Testing
@testable import ora

struct SampleSinkTests {

    private func append(_ samples: [Float], to sink: SampleSink) {
        samples.withUnsafeBufferPointer { sink.append($0) }
    }

    @Test("drain returns everything appended, in order")
    func drainReturnsAllSamples() {
        let sink = SampleSink()
        append([1, 2, 3], to: sink)
        append([4, 5], to: sink)
        #expect(sink.drain() == [1, 2, 3, 4, 5])
    }

    @Test("drain empties the sink")
    func drainEmptiesSink() {
        let sink = SampleSink()
        append([1, 2, 3], to: sink)
        _ = sink.drain()
        #expect(sink.drain() == [])
    }

    @Test("a fresh sink drains empty")
    func freshSinkIsEmpty() {
        #expect(SampleSink().drain() == [])
    }

    @Test("appending an empty buffer is a no-op")
    func emptyAppendIsNoop() {
        let sink = SampleSink()
        append([], to: sink)
        append([7], to: sink)
        #expect(sink.drain() == [7])
    }

    @Test("appends after a drain accumulate separately (late tap flush after stop)")
    func appendAfterDrain() {
        let sink = SampleSink()
        append([1], to: sink)
        #expect(sink.drain() == [1])
        append([2], to: sink)
        #expect(sink.drain() == [2])
    }
}
