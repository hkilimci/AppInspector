import Foundation
import Synchronization
import Darwin

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    /// Output hit the byte cap, or a pipe never reached EOF after the process exited. Never trust it as complete.
    public let truncated: Bool
    public let timedOut: Bool
    public init(status: Int32, stdout: Data, stderr: Data, truncated: Bool = false, timedOut: Bool = false) {
        self.status = status; self.stdout = stdout; self.stderr = stderr
        self.truncated = truncated; self.timedOut = timedOut
    }
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, Sendable { case notAbsolute(String), launchFailed(String) }

/// Runs a CLI by absolute path: argument array (no shell), `LC_ALL=C`, output cap, timeout.
///
/// Each pipe is read only by its `readabilityHandler`, until EOF, so no second reader can race it.
/// The call completes when the process has exited AND both pipes reached EOF. A descendant that keeps a
/// pipe open is bounded by `drainGrace`; the result is then marked `truncated`.
/// Timeout sends SIGTERM, then SIGKILL after `terminateGrace`. Task cancellation does the same.
public enum ProcessRunner {
    private typealias Cont = CheckedContinuation<ProcessResult, Error>

    private final class Run: Sendable {
        struct State {
            var out = Data(), err = Data()
            var truncated = false
            var outEOF = false, errEOF = false
            var terminated = false
            var status: Int32 = -1
            var timedOut = false, cancelled = false, done = false
            var cont: Cont?
            var timer: Task<Void, Never>?
        }
        let cap: Int
        let state = Mutex(State())
        init(cap: Int) { self.cap = cap }

        func append(err isErr: Bool, _ d: Data) {
            state.withLock { s in
                let room = cap - (isErr ? s.err.count : s.out.count)
                if room <= 0 { s.truncated = true; return }
                if d.count > room { s.truncated = true }
                let piece = d.count > room ? d.prefix(room) : d
                if isErr { s.err.append(piece) } else { s.out.append(piece) }
            }
        }

        func setContinuation(_ c: Cont) { state.withLock { $0.cont = c } }
        func setTimer(_ t: Task<Void, Never>) { state.withLock { $0.timer = t } }
        func setTimedOut() { state.withLock { $0.timedOut = true } }
        func setCancelled() { state.withLock { $0.cancelled = true } }
        var isTerminated: Bool { state.withLock { $0.terminated } }
        var wasCancelled: Bool { state.withLock { $0.cancelled } }

        /// Each returns the continuation and result exactly once, when the run is complete.
        func eof(err isErr: Bool) -> (Cont, ProcessResult)? {
            state.withLock { s in
                if isErr { s.errEOF = true } else { s.outEOF = true }
                return finish(&s, forced: false)
            }
        }
        func exited(status: Int32) -> (Cont, ProcessResult)? {
            state.withLock { s in s.terminated = true; s.status = status; return finish(&s, forced: false) }
        }
        /// Completes now even if pipes are open or the process did not exit.
        func force() -> (Cont, ProcessResult)? { state.withLock { s in finish(&s, forced: true) } }

        /// Fails the launch: returns the continuation to throw into, once.
        func takeForLaunchFailure() -> Cont? {
            state.withLock { s in
                guard !s.done else { return nil }
                s.done = true; s.timer?.cancel(); defer { s.cont = nil }
                return s.cont
            }
        }

        private func finish(_ s: inout State, forced: Bool) -> (Cont, ProcessResult)? {
            guard !s.done, let c = s.cont, forced || (s.terminated && s.outEOF && s.errEOF) else { return nil }
            s.done = true
            s.timer?.cancel(); s.timer = nil; s.cont = nil
            let incomplete = forced && !(s.outEOF && s.errEOF)
            return (c, ProcessResult(status: s.status, stdout: s.out, stderr: s.err,
                                     truncated: s.truncated || incomplete, timedOut: s.timedOut))
        }
    }

    public static func run(_ executable: String, _ args: [String] = [], timeout: Duration = .seconds(10),
                           maxBytes: Int = 4_000_000, terminateGrace: Duration = .seconds(2),
                           drainGrace: Duration = .seconds(2)) async throws -> ProcessResult {
        guard executable.hasPrefix("/") else { throw ProcessRunnerError.notAbsolute(executable) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let run = Run(cap: maxBytes)
        nonisolated(unsafe) let proc = p
        nonisolated(unsafe) let outH = out.fileHandleForReading
        nonisolated(unsafe) let errH = err.fileHandleForReading

        @Sendable func release() {
            outH.readabilityHandler = nil; errH.readabilityHandler = nil
            try? outH.close(); try? errH.close()
        }
        @Sendable func complete(_ r: (Cont, ProcessResult)?) {
            guard let (c, result) = r else { return }
            release()
            c.resume(returning: result)
        }

        outH.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; complete(run.eof(err: false)) } else { run.append(err: false, d) }
        }
        errH.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; complete(run.eof(err: true)) } else { run.append(err: true, d) }
        }

        let result: ProcessResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: Cont) in
                run.setContinuation(cont)
                p.terminationHandler = { proc in
                    complete(run.exited(status: proc.terminationStatus))
                    // A descendant may keep a pipe open after the process exits: bound the wait.
                    Task.detached {
                        try? await Task.sleep(for: drainGrace)
                        complete(run.force())
                    }
                }
                do { try p.run() } catch {
                    p.terminationHandler = nil
                    release()
                    run.takeForLaunchFailure()?.resume(throwing: ProcessRunnerError.launchFailed("\(error)"))
                    return
                }
                if Task.isCancelled { run.setCancelled(); proc.terminate() }
                run.setTimer(Task.detached {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled, !run.isTerminated else { return }
                    run.setTimedOut(); proc.terminate()
                    try? await Task.sleep(for: terminateGrace)
                    guard !Task.isCancelled, !run.isTerminated else { return }
                    kill(proc.processIdentifier, SIGKILL)
                    try? await Task.sleep(for: terminateGrace)
                    guard !Task.isCancelled else { return }
                    complete(run.force())            // never hang the caller on an unkillable child
                })
            }
        } onCancel: {
            run.setCancelled()
            if proc.isRunning {
                proc.terminate()
                Task.detached {
                    try? await Task.sleep(for: terminateGrace)
                    if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                }
            }
        }
        if run.wasCancelled { throw CancellationError() }
        return result
    }
}
