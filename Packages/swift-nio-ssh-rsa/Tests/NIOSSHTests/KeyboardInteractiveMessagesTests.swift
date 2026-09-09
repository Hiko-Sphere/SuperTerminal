//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import XCTest

@testable import NIOSSH

/// RFC 4256 message coding, added for ApexTerminal's keyboard-interactive support.
///
/// The interesting part is message number 60, which the protocol gives to both
/// `SSH_MSG_USERAUTH_PK_OK` and `SSH_MSG_USERAUTH_INFO_REQUEST`. Which one it means is a
/// matter of context, and these tests pin that down in both directions: the same bytes
/// must read as one message or the other depending on what was asked for, and never be
/// guessed at from the payload.
final class KeyboardInteractiveMessagesTests: XCTestCase {
    func testUserAuthRequestRoundTrips() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 100)
        let message = SSHMessage.userAuthRequest(
            .init(
                username: "test",
                service: "ssh-connection",
                method: .keyboardInteractive(languageTag: "", submethods: "")
            )
        )
        buffer.writeSSHMessage(message)
        XCTAssertEqual(try buffer.readSSHMessage(), message)
    }

    func testInfoRequestRoundTripsWhenExpected() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 200)
        let message = SSHMessage.userAuthInfoRequest(
            .init(
                name: "PAM",
                instruction: "Answer these",
                languageTag: "",
                prompts: [
                    .init(prompt: "Password: ", echo: false),
                    .init(prompt: "Your name: ", echo: true),
                ]
            )
        )
        buffer.writeSSHMessage(message)
        XCTAssertEqual(try buffer.readSSHMessage(expectsKeyboardInteractiveInfoRequest: true), message)
    }

    /// RFC 4256 § 3.3: a round may carry no prompts at all, and is used that way to show
    /// a message. An implementation that assumed at least one would mis-read it.
    func testInfoRequestWithNoPromptsRoundTrips() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 100)
        let message = SSHMessage.userAuthInfoRequest(
            .init(name: "", instruction: "Nearly there", languageTag: "", prompts: [])
        )
        buffer.writeSSHMessage(message)
        XCTAssertEqual(try buffer.readSSHMessage(expectsKeyboardInteractiveInfoRequest: true), message)
    }

    func testInfoResponseRoundTrips() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 100)
        let message = SSHMessage.userAuthInfoResponse(.init(responses: ["one", "two"]))
        buffer.writeSSHMessage(message)
        XCTAssertEqual(try buffer.readSSHMessage(), message)
    }

    func testEmptyInfoResponseRoundTrips() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 100)
        let message = SSHMessage.userAuthInfoResponse(.init(responses: []))
        buffer.writeSSHMessage(message)
        XCTAssertEqual(try buffer.readSSHMessage(), message)
    }

    /// The whole reason the parser takes a flag: the same byte means two things, and the
    /// answer comes from what this side sent rather than from the payload.
    func testMessageSixtyIsReadAccordingToContext() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 200)
        let infoRequest = SSHMessage.UserAuthInfoRequestMessage(
            name: "",
            instruction: "",
            languageTag: "",
            prompts: [.init(prompt: "Password: ", echo: false)]
        )
        buffer.writeSSHMessage(.userAuthInfoRequest(infoRequest))
        let bytes = buffer

        var asInfoRequest = bytes
        XCTAssertEqual(
            try asInfoRequest.readSSHMessage(expectsKeyboardInteractiveInfoRequest: true),
            .userAuthInfoRequest(infoRequest)
        )

        // The same bytes, read as a PK_OK because nothing asked for an info request. It
        // must not be silently accepted as one.
        var asPKOK = bytes
        XCTAssertThrowsError(try asPKOK.readSSHMessage()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .invalidSSHMessage, "got \(error)")
        }
    }

    /// A hostile server should not be able to make the client allocate for a million
    /// prompts. The bound is OpenSSH's own.
    func testAbsurdPromptCountIsRefused() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 100)
        buffer.writeInteger(SSHMessage.UserAuthInfoRequestMessage.id)
        buffer.writeSSHString("".utf8)
        buffer.writeSSHString("".utf8)
        buffer.writeSSHString("".utf8)
        buffer.writeInteger(UInt32(1_000_000))

        XCTAssertThrowsError(try buffer.readSSHMessage(expectsKeyboardInteractiveInfoRequest: true)) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .invalidSSHMessage, "got \(error)")
        }
    }

    func testAbsurdResponseCountIsRefused() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 100)
        buffer.writeInteger(SSHMessage.UserAuthInfoResponseMessage.id)
        buffer.writeInteger(UInt32(1_000_000))

        XCTAssertThrowsError(try buffer.readSSHMessage()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .invalidSSHMessage, "got \(error)")
        }
    }

    /// A truncated message must return nil and leave the reader where it was, so the
    /// parser can wait for the rest rather than losing bytes.
    func testPartialInfoRequestIsNotConsumed() throws {
        var complete = ByteBufferAllocator().buffer(capacity: 200)
        complete.writeSSHMessage(
            .userAuthInfoRequest(
                .init(
                    name: "PAM",
                    instruction: "",
                    languageTag: "",
                    prompts: [.init(prompt: "Verification code: ", echo: false)]
                )
            )
        )

        for length in 1 ..< complete.readableBytes {
            var partial = complete.getSlice(at: complete.readerIndex, length: length)!
            let before = partial.readerIndex
            XCTAssertNil(
                try partial.readSSHMessage(expectsKeyboardInteractiveInfoRequest: true),
                "a \(length)-byte prefix should not parse"
            )
            XCTAssertEqual(partial.readerIndex, before, "a failed read must not consume bytes")
        }
    }

    /// The client advertises the method by name, and reads the server's advertisement of
    /// it back. A mismatch here means the method is offered but never selected.
    func testAvailableMethodsCarryKeyboardInteractive() {
        let methods = NIOSSHAvailableUserAuthenticationMethods(
            SSHMessage.UserAuthFailureMessage(
                authentications: ["publickey", "keyboard-interactive"],
                partialSuccess: false
            )
        )
        XCTAssertTrue(methods.contains(.keyboardInteractive))
        XCTAssertTrue(methods.contains(.publicKey))
        XCTAssertFalse(methods.contains(.password))
        XCTAssertTrue(methods.strings.contains("keyboard-interactive"))
    }

    /// `.all` is what a *server* advertises, and this library implements only the client
    /// half of RFC 4256. Advertising it would spend a client's attempt on a method that
    /// is always refused.
    func testServerDoesNotAdvertiseAMethodItCannotServe() {
        XCTAssertFalse(NIOSSHAvailableUserAuthenticationMethods.all.contains(.keyboardInteractive))
        XCTAssertTrue(NIOSSHAvailableUserAuthenticationMethods.allClientMethods.contains(.keyboardInteractive))
    }
}
