import Foundation

/**
 Converts a generic async iterator into an `AsyncThrowingStream`.

 Port of `@ai-sdk/provider-utils/src/convert-async-iterator-to-readable-stream.ts`.
 */
@preconcurrency
public func convertAsyncIteratorToReadableStream<Iterator: AsyncIteratorProtocol>(
    _ iterator: Iterator
) -> AsyncThrowingStream<Iterator.Element, Error> where Iterator.Element: Sendable {
    let holder = AnyAsyncIteratorHolder(iterator)

    return AsyncThrowingStream { continuation in
        let task = Task {
            do {
                while !Task.isCancelled {
                    guard let value = try await holder.next() else {
                        continuation.finish()
                        return
                    }
                    continuation.yield(value)
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

private final class AnyAsyncIteratorHolder<Element: Sendable>: @unchecked Sendable {
    private let nextClosure: () async throws -> Element?

    init<Iterator: AsyncIteratorProtocol>(_ iterator: Iterator) where Iterator.Element == Element {
        let storage = UncheckedSendableBox(value: iterator)
        let actor = AsyncIteratorActor(storage: storage)
        self.nextClosure = {
            try await actor.next()
        }
    }

    func next() async throws -> Element? {
        try await nextClosure()
    }
}

private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    var value: Value
}

/// Swift 6.0 编译兼容补丁（Xcode 16.x / Intel Mac）：在 actor 内 await
/// nonisolated async 时，Swift 6.0 要求跨界值可 Sendable——非 Sendable 的
/// `Iterator.Element?` 过不了 actor 边界（Swift 6.2 因 nonisolated(nonsending)
/// 默认在调用方执行而无感，所以只在 Xcode 16.x 上报错）。公开入口本就
/// 约束 `Element: Sendable`，把它补到 actor 的泛型上即可，行为零变化。
private actor AsyncIteratorActor<Iterator: AsyncIteratorProtocol> where Iterator.Element: Sendable {
    private var storage: UncheckedSendableBox<Iterator>

    init(storage: UncheckedSendableBox<Iterator>) {
        self.storage = storage
    }

    func next() async throws -> Iterator.Element? {
        var iterator = storage.value
        let result = try await iterator.next()
        storage.value = iterator
        return result
    }
}
