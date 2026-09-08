/// Carries a value the compiler cannot prove is safe to send, because the framework that
/// hands it over predates strict concurrency.
///
/// The File Provider API passes completion handlers and observers that are not marked
/// `@Sendable`, while every operation here is asynchronous and therefore runs on a task
/// of its own. The system calls each of these exactly once, from one place, and the work
/// that uses them never runs twice — so the guarantee holds; it just cannot be written
/// down in the type system. This box is where that reasoning lives, rather than scattered
/// `@unchecked` annotations that say nothing about why.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
