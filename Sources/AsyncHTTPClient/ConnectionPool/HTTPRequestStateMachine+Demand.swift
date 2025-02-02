//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2021 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

extension HTTPRequestStateMachine {
    /// A sub state for receiving a response events. Stores whether the consumer has either signaled demand and whether the
    /// channel has issued `read` events.
    struct ResponseStreamState {
        private enum State {
            /// The state machines expects further writes to `channelRead`. The writes are appended to the buffer.
            case waitingForBytes(CircularBuffer<ByteBuffer>)
            /// The state machines expects a call to `demandMoreResponseBodyParts` or `read`. The buffer is
            /// empty. It is preserved for performance reasons.
            case waitingForReadOrDemand(CircularBuffer<ByteBuffer>)
            /// The state machines expects a call to `read`. The buffer is empty. It is preserved for performance reasons.
            case waitingForRead(CircularBuffer<ByteBuffer>)
            /// The state machines expects a call to `demandMoreResponseBodyParts`. The buffer is empty. It is
            /// preserved for performance reasons.
            case waitingForDemand(CircularBuffer<ByteBuffer>)

            case modifying
        }

        enum Action {
            case read
            case wait
        }

        private var state: State

        init() {
            self.state = .waitingForBytes(CircularBuffer(initialCapacity: 16))
        }

        mutating func receivedBodyPart(_ body: ByteBuffer) {
            switch self.state {
            case .waitingForBytes(var buffer):
                self.state = .modifying
                buffer.append(body)
                self.state = .waitingForBytes(buffer)

            case .waitingForRead,
                 .waitingForDemand,
                 .waitingForReadOrDemand:
                preconditionFailure("How can we receive a body part, after a channelReadComplete, but no read has been forwarded yet. Invalid state: \(self.state)")

            case .modifying:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        mutating func channelReadComplete() -> CircularBuffer<ByteBuffer>? {
            switch self.state {
            case .waitingForBytes(let buffer):
                if buffer.isEmpty {
                    self.state = .waitingForRead(buffer)
                    return nil
                } else {
                    var newBuffer = buffer
                    newBuffer.removeAll(keepingCapacity: true)
                    self.state = .waitingForReadOrDemand(newBuffer)
                    return buffer
                }

            case .waitingForRead,
                 .waitingForDemand,
                 .waitingForReadOrDemand:
                preconditionFailure("How can we receive a body part, after a channelReadComplete, but no read has been forwarded yet. Invalid state: \(self.state)")

            case .modifying:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        mutating func demandMoreResponseBodyParts() -> Action {
            switch self.state {
            case .waitingForDemand(let buffer):
                self.state = .waitingForBytes(buffer)
                return .read

            case .waitingForReadOrDemand(let buffer):
                self.state = .waitingForRead(buffer)
                return .wait

            case .waitingForRead:
                // if we are `waitingForRead`, no action needs to be taken. Demand was already signalled
                // once we receive the next `read`, we will forward it, right away
                return .wait

            case .waitingForBytes:
                // if we are `.waitingForBytes`, no action needs to be taken. As soon as we receive
                // the next channelReadComplete we will forward all buffered data
                return .wait

            case .modifying:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        mutating func read() -> Action {
            switch self.state {
            case .waitingForBytes:
                // This should never happen. But we don't want to precondition this behavior. Let's just
                // pass the read event on
                return .read

            case .waitingForReadOrDemand(let buffer):
                self.state = .waitingForDemand(buffer)
                return .wait

            case .waitingForRead(let buffer):
                self.state = .waitingForBytes(buffer)
                return .read

            case .waitingForDemand:
                // we have already received a read event. We will issue it as soon as we received demand
                // from the consumer
                return .wait

            case .modifying:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        mutating func end() -> CircularBuffer<ByteBuffer> {
            switch self.state {
            case .waitingForBytes(let buffer):
                return buffer

            case .waitingForReadOrDemand,
                 .waitingForRead,
                 .waitingForDemand:
                preconditionFailure("How can we receive a body end, after a channelReadComplete, but no read has been forwarded yet. Invalid state: \(self.state)")

            case .modifying:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }
    }
}
