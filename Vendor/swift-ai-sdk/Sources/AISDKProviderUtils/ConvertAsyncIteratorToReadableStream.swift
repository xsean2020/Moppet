import Foundation

#if compiler(<6.2)
/// Back-deployment shim: `SendableMetatype` is a Swift 6.2 marker protocol.
/// Older toolchains treat every metatype as sendable, so `Any` is equivalent.
public typealias SendableMetatype = Any
#endif

/**
 Converts a generic async iterator into an `AsyncThrowingStream`.

 Port of `@ai-sdk/provider-utils/src/convert-async-iterator-to-readable-stream.ts`.
 */
@preconcurrency
public func convertAsyncIteratorToReadableStream<Iterator: AsyncIteratorProtocol & SendableMetatype>(
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
    private let nextClosure: @Sendable () async throws -> Element?

    init<Iterator: AsyncIteratorProtocol & SendableMetatype>(_ iterator: Iterator) where Iterator.Element == Element {
        let storage = UncheckedSendableBox(value: iterator)
        let actor = AsyncIteratorActor<Element> {
            try await storage.next()
        }
        self.nextClosure = {
            try await actor.next()
        }
    }

    func next() async throws -> Element? {
        try await nextClosure()
    }
}

private final class UncheckedSendableBox<Iterator: AsyncIteratorProtocol & SendableMetatype>: @unchecked Sendable
where Iterator.Element: Sendable {
    private var value: Iterator

    init(value: Iterator) {
        self.value = value
    }

    func next() async throws -> Iterator.Element? {
        try await value.next()
    }
}

/// Swift 6.0 编译兼容补丁（Xcode 16.x / Intel Mac）：在 actor 内 await
/// nonisolated async 时，Swift 6.0 要求跨界值可 Sendable——非 Sendable 的
/// `Iterator.Element?` 过不了 actor 边界（Swift 6.2 因 nonisolated(nonsending)
/// 默认在调用方执行而无感，所以只在 Xcode 16.x 上报错）。公开入口本就
/// 约束 `Element: Sendable`，把它补到 actor 的泛型上即可，行为零变化。
///
/// 这里把 iterator 的类型擦除成 `@Sendable` 闭包再交给 actor：直接以
/// `Iterator: AsyncIteratorProtocol` 作为 actor 泛型会让 Swift 6.2 把该
/// conformance 视为可能 isolated，从而在跨 actor 时报警。
private actor AsyncIteratorActor<Element: Sendable> {
    private let nextValue: @Sendable () async throws -> Element?

    init(_ nextValue: @escaping @Sendable () async throws -> Element?) {
        self.nextValue = nextValue
    }

    func next() async throws -> Element? {
        try await nextValue()
    }
}
