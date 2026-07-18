import Citadel

/// Citadel's own types aren't Sendable-audited for Swift 6 strict
/// concurrency: `TTYStdinWriter` just wraps a NIO `Channel`, which conforms
/// only to NIO's transitional `_NIOPreconcurrencySendable` marker rather
/// than real `Sendable`, and `SSHClient` isn't marked at all despite
/// internally marshaling its work onto the correct NIO event loop the same
/// way. `TTYOutput` just wraps an `AsyncThrowingStream` of NIO `ByteBuffer`s
/// (themselves genuinely Sendable) but, being a plain public struct with no
/// declared conformance, isn't inferred Sendable across the module boundary
/// either. These are trusted, deliberate `@unchecked` assertions (not
/// oversights) -- see `SSHConnection`'s doc comments for how values of
/// these types are actually used across isolation domains.
extension Citadel.SSHClient: @unchecked @retroactive Sendable {}
extension TTYStdinWriter: @unchecked @retroactive Sendable {}
extension TTYOutput: @unchecked @retroactive Sendable {}
