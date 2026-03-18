import os.lock

/// `CancellingContinuation` is built on top of `CheckedContinuation` and
/// provides some additional features. It can be used as a drop-in replacement,
/// providing a similar API.
///
/// ## Automatic cancellation
/// When the suspended task is cancelled the continuation is automatically
/// resumed with a `CancellationError`. After that, normally resuming the
/// continuation from client is silently ignored.
///
/// Due to automatic cancellation only a throwing continuation is provided.
///
/// ## Conformance to `Equatable` and `Hashable`
/// `CancellingContinuation` values can be tested for equality. This makes
/// them suitable to manage waiting tasks. The values can be stored and
/// identified in containers. The values have reference semantics, yet can be
/// passed around between isolation domains.

public struct CancellingContinuation<T: Sendable>: Sendable, Hashable {
    private let state = OSAllocatedUnfairLock(initialState: State.initial)

    /// This id is process-unique.
    public let id = uniqueIdentifier

    /// Initial state: The underlying continuation itself is not yet created.
    public init() {}

    /// Await the result. If the optional closure is provided, it is called
    /// synchronously before the task is suspended.
    public func callAsFunction(
        isolation: isolated (any Actor)? = #isolation,
        function: String = #function,
        _ body: ((CancellingContinuation<T>) -> Void)? = nil
    ) async throws -> sending T {

        return try await withTaskCancellationHandler {

            // The underlying CheckedContinuation is created:
            return try await withCheckedThrowingContinuation(function: function) { continuation in
                state.withLock { $0.set(continuation) }
                body?(self)
            }
        } onCancel: {
            state.withLock { $0.cancel() }
        }
    }

    /// Behavior of `resume` is similar to CheckedContinuation/resume, with one
    /// main difference: If the continuation has already been resumed, then
    /// subsequent calls to resume will be silently ignored.
    public func resume(with result: Result<T, any Error>) {
        state.withLock { $0.resume(with: result) }
    }

    public func resume(returning value: sending T) { resume(with: .success(value)) }
    public func resume(throwing error: any Error) { resume(with: .failure(error)) }
    public func resume() where T == Void { resume(with: .success(())) }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// The continuation's internal mutable state. Also defines three possible
    /// events that trigger state transitions.
    private enum State: Sendable {
        /// This is the initial state before any cancel, await, or resume event.
        case initial
        /// Task has been cancelled before awaiting the continuation's result.
        case scheduledCancel
        /// The continuation has been resumed before it's result was awaited.
        case scheduledResume(Result<T, any Error>)
        /// Awaiting the continuation. No cancel or resume, yet.
        case awaitingContinuation(CheckedContinuation<T, any Error>)
        /// The continuation has been awaited and resumed.
        case resumed
        /// The continuation has been cancelled from the waiting task.
        case resumedWithCancellation

        /// Event: Client code began awaiting the continuation.
        mutating func set(_ continuation: CheckedContinuation<T, any Error>) {
            switch self {
            case .initial:
                self = .awaitingContinuation(continuation)
            case .scheduledResume(let result):
                continuation.resume(with: result)
                self = .resumed
            case .scheduledCancel:
                continuation.resume(throwing: CancellationError())
                self = .resumedWithCancellation
            case .awaitingContinuation, .resumed, .resumedWithCancellation:
                fatalError("SWIFT TASK CONTINUATION MISUSE: cancellingContinuation() tried to await the continuation more than once")
            }
        }

        /// Event: Automatic cancellation by waiting task.
        mutating func cancel() {
            switch self {
            case .initial, .scheduledCancel, .scheduledResume:
                self = .scheduledCancel
            case .awaitingContinuation(let continuation):
                continuation.resume(throwing: CancellationError())
                self = .resumedWithCancellation
            case .resumed, .resumedWithCancellation:
                break // ignored
            }
        }

        /// Event: Client code did resume the continuation normally.
        mutating func resume(with result: Result<T, any Error>) {
            switch self {
            case .initial:
                self = .scheduledResume(result)
            case .awaitingContinuation(let continuation):
                continuation.resume(with: result)
                self = .resumed
            case .scheduledCancel, .resumedWithCancellation:
                // resume ignored
                break
            case .scheduledResume, .resumed:
                fatalError("SWIFT TASK CONTINUATION MISUSE: cancellingContinuation() tried to resume its continuation more than once")
            }
        }
    }
}

/// See `CancellingContinuation`

public func withCancellingContinuation<T>(
    isolation: isolated (any Actor)? = #isolation,
    function: String = #function,
    _ body: (CancellingContinuation<T>) -> Void
) async throws -> sending T {

    try await withoutActuallyEscaping(body) { escapingClosure in
        let continuation = CancellingContinuation<T>()
        return try await continuation(function: function, escapingClosure)
    }
}


private let identifierSource = OSAllocatedUnfairLock(initialState: 0)
private var uniqueIdentifier: Int { identifierSource.withLock { state in state += 1; return state }}
