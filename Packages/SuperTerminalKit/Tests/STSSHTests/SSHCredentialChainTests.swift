import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
import STCore
import Testing
@testable import STSSH

/// The credential chain as NIOSSH drives it, call by call (D-024): with nothing stored
/// the chain offers `none` so the server says what it takes, then asks the person for a
/// password only if the server takes one — once.
@Suite("SSH credential chain")
struct SSHCredentialChainTests {
    private let loop = MultiThreadedEventLoopGroup.singleton.next()

    /// One `nextAuthenticationType` round trip, as the handler makes it.
    private func offer(
        from chain: SSHCredentialChain,
        methods: NIOSSHAvailableUserAuthenticationMethods
    ) async throws -> NIOSSHUserAuthenticationOffer? {
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        chain.nextAuthenticationType(availableMethods: methods, nextChallengePromise: promise)
        return try await promise.futureResult.get()
    }

    @Test("Nothing stored: none first, then the password the person types, offered once")
    func asksForAPasswordWhenTheServerTakesOne() async throws {
        let asked = NIOLockedValueBox(0)
        let chain = SSHCredentialChain(username: "deploy", credentials: [.none], passwordProvider: { username in
            asked.withLockedValue { $0 += 1 }
            #expect(username == "deploy")
            return "s3cret"
        })
        let first = try await offer(from: chain, methods: .all)
        guard case .none? = first?.offer else { Issue.record("none should be offered first"); return }
        #expect(asked.withLockedValue { $0 } == 0, "nobody is asked before the server has said what it takes")

        let second = try await offer(from: chain, methods: [.password, .publicKey])
        guard case let .password(password)? = second?.offer else { Issue.record("the typed password should be offered"); return }
        #expect(password.password == "s3cret")
        #expect(second?.username == "deploy")
        #expect(asked.withLockedValue { $0 } == 1)
        #expect(chain.mostRecentlyOffered?.displayKind == "password")

        // A wrong password does not become a loop of prompts: the chain asks once.
        await #expect(throws: SSHAuthenticationError.self) {
            _ = try await offer(from: chain, methods: [.password])
        }
        #expect(asked.withLockedValue { $0 } == 1)
    }

    @Test("A server that takes only keys is never asked for a password")
    func keyOnlyServerIsNotAsked() async throws {
        let asked = NIOLockedValueBox(0)
        let chain = SSHCredentialChain(username: "deploy", credentials: [.none], passwordProvider: { _ in
            asked.withLockedValue { $0 += 1 }
            return "s3cret"
        })
        _ = try await offer(from: chain, methods: .all)
        await #expect(throws: SSHAuthenticationError.self) {
            _ = try await offer(from: chain, methods: [.publicKey])
        }
        #expect(asked.withLockedValue { $0 } == 0)
    }

    @Test("Cancelling the prompt ends the attempt cleanly, and says so")
    func cancelledPromptFails() async throws {
        let chain = SSHCredentialChain(username: "deploy", credentials: [], passwordProvider: { _ in nil })
        do {
            _ = try await offer(from: chain, methods: [.password])
            Issue.record("a cancelled prompt must not leave the handshake waiting")
        } catch let error as SSHAuthenticationError {
            #expect(error.attempted.contains("password (cancelled)"))
        }
    }

    @Test("Without a provider the chain behaves as before: stored credentials, then failure")
    func storedCredentialsOnly() async throws {
        let chain = SSHCredentialChain(username: "deploy", credentials: [.password(Redacted("stored", label: "ssh-password"))])
        let first = try await offer(from: chain, methods: .all)
        guard case let .password(password)? = first?.offer else { Issue.record("the stored password should be offered"); return }
        #expect(password.password == "stored")
        await #expect(throws: SSHAuthenticationError.self) {
            _ = try await offer(from: chain, methods: [.password])
        }
    }
}
