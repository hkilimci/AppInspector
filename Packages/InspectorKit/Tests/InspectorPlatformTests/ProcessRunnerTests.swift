import Testing
import Foundation
@testable import InspectorPlatform

@Suite struct ProcessRunnerTests {
    /// Output must be complete: the last chunk may not be lost or reordered by the drain logic.
    @Test func largeOutputIsCompleteAndInOrder() async throws {
        let r = try await ProcessRunner.run("/usr/bin/seq", ["1", "400000"], timeout: .seconds(20))
        #expect(r.status == 0 && !r.truncated)
        let lines = r.stdoutString.split(separator: "\n")
        #expect(lines.count == 400_000)
        #expect(lines.first == "1" && lines.last == "400000")
        // Spot-check order across the whole stream.
        #expect(zip(lines.prefix(5000), 1...5000).allSatisfy { Int($0.0) == $0.1 })
    }

    @Test func manyShortRunsNeverLoseOutput() async throws {
        for i in 0..<60 {
            let r = try await ProcessRunner.run("/bin/echo", ["run-\(i)"])
            #expect(r.stdoutString == "run-\(i)\n")
        }
    }

    @Test func stdoutAndStderrAreSeparate() async throws {
        let r = try await ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"])
        #expect(r.stdoutString == "out\n" && String(decoding: r.stderr, as: UTF8.self) == "err\n" && r.status == 3)
    }

    /// A child that ignores SIGTERM is killed after the grace period instead of hanging the caller.
    @Test func sigtermIgnoringChildIsKilled() async throws {
        let start = Date()
        let r = try await ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; sleep 30"],
                                            timeout: .milliseconds(200), terminateGrace: .milliseconds(300))
        #expect(r.timedOut)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    /// A descendant keeping the pipe open must not block forever; the result is marked incomplete.
    @Test func descendantHoldingPipeIsBoundedAndMarkedTruncated() async throws {
        let start = Date()
        let r = try await ProcessRunner.run("/bin/sh", ["-c", "sleep 8 & echo hi"], timeout: .seconds(20),
                                            drainGrace: .milliseconds(300))
        #expect(r.truncated)
        #expect(r.stdoutString == "hi\n")
        #expect(Date().timeIntervalSince(start) < 6)
    }

    @Test func taskCancellationTerminatesTheProcess() async throws {
        let start = Date()
        let task = Task { try await ProcessRunner.run("/bin/sleep", ["30"], timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 6)
    }

    @Test func outputCapMarksTruncated() async throws {
        let r = try await ProcessRunner.run("/usr/bin/seq", ["1", "200000"], timeout: .seconds(20), maxBytes: 1000)
        #expect(r.truncated && r.stdout.count == 1000)
    }
}
