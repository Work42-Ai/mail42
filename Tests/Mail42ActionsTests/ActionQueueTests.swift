import Foundation
import Testing
@testable import Mail42Actions

/// Mail answers Apple Events one at a time, so mail42 sends them one at a time, in order, and folds repeats (WOR-828, AC8).
@Suite struct ActionQueueTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// `DispatchSemaphore.wait` can't be called from async code directly.
    private func blockUntil(_ semaphore: DispatchSemaphore) { semaphore.wait() }

    private func queue() -> ActionQueue<String> {
        let serial = DispatchQueue(label: "test.actions")
        return ActionQueue<String> { work in serial.async(execute: work) }
    }

    private func wait(_ seconds: TimeInterval = 3, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// How many requests are running at once, and the most there ever were.
    private final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var peak = 0
        func enter() { lock.lock(); active += 1; peak = max(peak, active); lock.unlock() }
        func leave() { lock.lock(); active -= 1; lock.unlock() }
    }

    @Test func requestsRunOneAtATimeInArrivalOrder() async {
        let queue = queue()
        let events = Recorder()
        let gauge = Gauge()
        for name in ["a", "b", "c", "d"] {
            queue.submit(work: {
                gauge.enter()
                events.add("start \(name)")
                Thread.sleep(forTimeInterval: 0.03)
                events.add("end \(name)")
                gauge.leave()
                return name
            }, completion: { _ in })
        }
        await wait { events.values.count == 8 }
        #expect(events.values == ["start a", "end a", "start b", "end b", "start c", "end c", "start d", "end d"])
        #expect(gauge.peak == 1)
    }

    @Test func aWaitingRequestIsReplacedByALaterOneWithTheSameKeyAndBothAreAnswered() async {
        let queue = queue()
        let ran = Recorder(), answers = Recorder()
        let gate = DispatchSemaphore(value: 0)

        queue.submit(work: { gate.wait(); ran.add("blocker"); return "blocker" }, completion: { _ in })
        queue.submit(key: "mark:7:read", work: { ran.add("first"); return "first" }, completion: { answers.add("A=\($0)") })
        queue.submit(key: "mark:7:read", work: { ran.add("second"); return "second" }, completion: { answers.add("B=\($0)") })
        gate.signal()

        await wait { answers.values.count == 2 }
        #expect(ran.values == ["blocker", "second"])      // the replaced request never ran
        #expect(Set(answers.values) == ["A=second", "B=second"])   // and it was answered with the replacement's result
    }

    @Test func aRequestThatHasAlreadyStartedIsNeverReplaced() async {
        let queue = queue()
        let ran = Recorder(), answers = Recorder()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)

        queue.submit(key: "k", work: { started.signal(); release.wait(); ran.add("first"); return "first" },
                     completion: { answers.add("A=\($0)") })
        blockUntil(started)                               // the first is running now
        queue.submit(key: "k", work: { ran.add("second"); return "second" }, completion: { answers.add("B=\($0)") })
        release.signal()

        await wait { answers.values.count == 2 }
        #expect(ran.values == ["first", "second"])
        #expect(Set(answers.values) == ["A=first", "B=second"])
    }

    @Test func differentKeysAndNoKeyAreNeverFolded() async {
        let queue = queue()
        let ran = Recorder()
        let gate = DispatchSemaphore(value: 0)
        queue.submit(work: { gate.wait(); return "blocker" }, completion: { _ in })
        queue.submit(key: "mark:7:read", work: { ran.add("read"); return "" }, completion: { _ in })
        queue.submit(key: "mark:7:flag", work: { ran.add("flag"); return "" }, completion: { _ in })
        queue.submit(key: "mark:8:read", work: { ran.add("other message"); return "" }, completion: { _ in })
        queue.submit(work: { ran.add("none 1"); return "" }, completion: { _ in })
        queue.submit(work: { ran.add("none 2"); return "" }, completion: { _ in })
        gate.signal()
        await wait { ran.values.count == 5 }
        #expect(ran.values == ["read", "flag", "other message", "none 1", "none 2"])
    }

    @Test func theReplacingRequestTakesTheLaterPlaceInLine() async {
        // The later request goes to the back, where it arrived: it does not jump ahead of work that came between the two.
        let queue = queue()
        let ran = Recorder()
        let gate = DispatchSemaphore(value: 0)
        queue.submit(work: { gate.wait(); return "" }, completion: { _ in })
        queue.submit(key: "k", work: { ran.add("k-old"); return "" }, completion: { _ in })
        queue.submit(work: { ran.add("between"); return "" }, completion: { _ in })
        queue.submit(key: "k", work: { ran.add("k-new"); return "" }, completion: { _ in })
        gate.signal()
        await wait { ran.values.count == 2 }
        #expect(ran.values == ["between", "k-new"])
    }

    @Test func theQueueIdlesAndStartsAgain() async {
        let queue = queue()
        let answers = Recorder()
        queue.submit(work: { "one" }, completion: { answers.add($0) })
        await wait { answers.values.count == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        queue.submit(work: { "two" }, completion: { answers.add($0) })
        await wait { answers.values.count == 2 }
        #expect(answers.values == ["one", "two"])
        #expect(queue.waitingCount == 0)
    }
}
