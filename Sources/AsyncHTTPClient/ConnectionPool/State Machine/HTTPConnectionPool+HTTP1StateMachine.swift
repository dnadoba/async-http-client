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

import NIO

extension HTTPConnectionPool {
    struct HTTP1StateMachine {
        enum State: Equatable {
            case running
            case shuttingDown(unclean: Bool)
            case shutDown
        }

        typealias Action = HTTPConnectionPool.StateMachine.Action

        private var connections: HTTP1Connections
        private var failedConsecutiveConnectionAttempts: Int = 0
        /// the error from the last connection creation
        private var lastConnectFailure: Error?

        private var requests: RequestQueue
        private var state: State = .running

        init(idGenerator: Connection.ID.Generator, maximumConcurrentConnections: Int) {
            self.connections = HTTP1Connections(
                maximumConcurrentConnections: maximumConcurrentConnections,
                generator: idGenerator
            )

            self.requests = RequestQueue()
        }

        // MARK: - Events -

        mutating func executeRequest(_ request: Request) -> Action {
            switch self.state {
            case .running:
                if let eventLoop = request.requiredEventLoop {
                    return self.executeRequestOnRequiredEventLoop(request, eventLoop: eventLoop)
                } else {
                    return self.executeRequestOnPreferredEventLoop(request, eventLoop: request.preferredEventLoop)
                }
            case .shuttingDown, .shutDown:
                // it is fairly unlikely that this condition is met, since the ConnectionPoolManager
                // also fails new requests immediately, if it is shutting down. However there might
                // be race conditions in which a request passes through a running connection pool
                // manager, but hits a connection pool that is already shutting down.
                //
                // (Order in one lock does not guarantee order in the next lock!)
                return .init(
                    request: .failRequest(request, HTTPClientError.alreadyShutdown, cancelTimeout: false),
                    connection: .none
                )
            }
        }

        private mutating func executeRequestOnPreferredEventLoop(_ request: Request, eventLoop: EventLoop) -> Action {
            if let connection = self.connections.leaseConnection(onPreferred: eventLoop) {
                return .init(
                    request: .executeRequest(request, connection, cancelTimeout: false),
                    connection: .cancelTimeoutTimer(connection.id)
                )
            }

            // No matter what we do now, the request will need to wait!
            self.requests.push(request)
            let requestAction: StateMachine.RequestAction = .scheduleRequestTimeout(
                for: request,
                on: eventLoop
            )

            if !self.connections.canGrow {
                // all connections are busy and there is no room for more connections, we need to wait!
                return .init(request: requestAction, connection: .none)
            }

            // if we are not at max connections, we may want to create a new connection
            if self.connections.startingGeneralPurposeConnections >= self.requests.generalPurposeCount {
                // If there are at least as many connections starting as we have request queued, we
                // don't need to create a new connection. we just need to wait.
                return .init(request: requestAction, connection: .none)
            }

            // There are not enough connections starting for the current waiting request count. We
            // should create a new one.
            let newConnectionID = self.connections.createNewConnection(on: eventLoop)

            return .init(
                request: requestAction,
                connection: .createConnection(newConnectionID, on: eventLoop)
            )
        }

        private mutating func executeRequestOnRequiredEventLoop(_ request: Request, eventLoop: EventLoop) -> Action {
            if let connection = self.connections.leaseConnection(onRequired: eventLoop) {
                return .init(
                    request: .executeRequest(request, connection, cancelTimeout: false),
                    connection: .cancelTimeoutTimer(connection.id)
                )
            }

            // No matter what we do now, the request will need to wait!
            self.requests.push(request)
            let requestAction: StateMachine.RequestAction = .scheduleRequestTimeout(
                for: request,
                on: eventLoop
            )

            let starting = self.connections.startingEventLoopConnections(on: eventLoop)
            let waiting = self.requests.count(for: eventLoop)

            if starting >= waiting {
                // There are already as many connections starting as we need for the waiting
                // requests. A new connection doesn't need to be created.
                return .init(request: requestAction, connection: .none)
            }

            // There are not enough connections starting for the number of requests in the queue.
            // We should create a new connection.
            let newConnectionID = self.connections.createNewOverflowConnection(on: eventLoop)

            return .init(
                request: requestAction,
                connection: .createConnection(newConnectionID, on: eventLoop)
            )
        }

        mutating func newHTTP1ConnectionEstablished(_ connection: Connection) -> Action {
            self.failedConsecutiveConnectionAttempts = 0
            self.lastConnectFailure = nil
            let (index, context) = self.connections.newHTTP1ConnectionEstablished(connection)
            return self.nextActionForIdleConnection(at: index, context: context)
        }

        mutating func failedToCreateNewConnection(_ error: Error, connectionID: Connection.ID) -> Action {
            self.failedConsecutiveConnectionAttempts += 1
            self.lastConnectFailure = error

            switch self.state {
            case .running:
                // We don't care how many waiting requests we have at this point, we will schedule a
                // retry. More tasks, may appear until the backoff has completed. The final
                // decision about the retry will be made in `connectionCreationBackoffDone(_:)`
                let eventLoop = self.connections.backoffNextConnectionAttempt(connectionID)

                let backoff = self.calculateBackoff(failedAttempt: self.failedConsecutiveConnectionAttempts)
                return .init(
                    request: .none,
                    connection: .scheduleBackoffTimer(connectionID, backoff: backoff, on: eventLoop)
                )

            case .shuttingDown:
                guard let (index, context) = self.connections.failConnection(connectionID) else {
                    preconditionFailure("Failed to create a connection that is unknown to us?")
                }
                return self.nextActionForFailedConnection(at: index, context: context)

            case .shutDown:
                preconditionFailure("The pool is already shutdown all connections must already been torn down")
            }
        }

        mutating func connectionCreationBackoffDone(_ connectionID: Connection.ID) -> Action {
            switch self.state {
            case .running:
                // The naming of `failConnection` is a little confusing here. All it does is moving the
                // connection state from `.backingOff` to `.closed` here. It also returns the
                // connection's index.
                guard let (index, context) = self.connections.failConnection(connectionID) else {
                    preconditionFailure("Backing off a connection that is unknown to us?")
                }
                // In `nextActionForFailedConnection` a decision will be made whether the failed
                // connection should be replaced or removed.
                return self.nextActionForFailedConnection(at: index, context: context)

            case .shuttingDown, .shutDown:
                // There might be a race between shutdown and a backoff timer firing. On thread A
                // we might call shutdown which removes the backoff timer. On thread B the backoff
                // timer might fire at the same time and be blocked by the state lock. In this case
                // we would look for the backoff timer that was removed just before by the shutdown.
                return .none
            }
        }

        mutating func connectionIdleTimeout(_ connectionID: Connection.ID) -> Action {
            guard let connection = self.connections.closeConnectionIfIdle(connectionID) else {
                // because of a race this connection (connection close runs against trigger of timeout)
                // was already removed from the state machine.
                return .none
            }

            precondition(self.state == .running, "If we are shutting down, we must not have any idle connections")

            return .init(
                request: .none,
                connection: .closeConnection(connection, isShutdown: .no)
            )
        }

        mutating func http1ConnectionReleased(_ connectionID: Connection.ID) -> Action {
            let (index, context) = self.connections.releaseConnection(connectionID)
            return self.nextActionForIdleConnection(at: index, context: context)
        }

        /// A connection has been unexpectedly closed
        mutating func connectionClosed(_ connectionID: Connection.ID) -> Action {
            guard let (index, context) = self.connections.failConnection(connectionID) else {
                // When a connection close is initiated by the connection pool, the connection will
                // still report its close to the state machine. In those cases we must ignore the
                // event.
                return .none
            }
            return self.nextActionForFailedConnection(at: index, context: context)
        }

        mutating func timeoutRequest(_ requestID: Request.ID) -> Action {
            // 1. check requests in queue
            if let request = self.requests.remove(requestID) {
                var error: Error = HTTPClientError.getConnectionFromPoolTimeout
                if let lastError = self.lastConnectFailure {
                    error = lastError
                } else if !self.connections.hasActiveConnections {
                    error = HTTPClientError.connectTimeout
                }
                return .init(
                    request: .failRequest(request, error, cancelTimeout: false),
                    connection: .none
                )
            }

            // 2. This point is reached, because the request may have already been scheduled. A
            //    connection might have become available shortly before the request timeout timer
            //    fired.
            return .none
        }

        mutating func cancelRequest(_ requestID: Request.ID) -> Action {
            // 1. check requests in queue
            if self.requests.remove(requestID) != nil {
                return .init(
                    request: .cancelRequestTimeout(requestID),
                    connection: .none
                )
            }

            // 2. This is point is reached, because the request may already have been forwarded to
            //    an idle connection. In this case the connection will need to handle the
            //    cancellation.
            return .none
        }

        mutating func shutdown() -> Action {
            precondition(self.state == .running, "Shutdown must only be called once")

            // If we have remaining request queued, we should fail all of them with a cancelled
            // error.
            let waitingRequests = self.requests.removeAll()

            var requestAction: StateMachine.RequestAction = .none
            if !waitingRequests.isEmpty {
                requestAction = .failRequestsAndCancelTimeouts(waitingRequests, HTTPClientError.cancelled)
            }

            // clean up the connections, we can cleanup now!
            let cleanupContext = self.connections.shutdown()

            // If there aren't any more connections, everything is shutdown
            let isShutdown: StateMachine.ConnectionAction.IsShutdown
            let unclean = !(cleanupContext.cancel.isEmpty && waitingRequests.isEmpty)
            if self.connections.isEmpty {
                self.state = .shutDown
                isShutdown = .yes(unclean: unclean)
            } else {
                self.state = .shuttingDown(unclean: unclean)
                isShutdown = .no
            }

            return .init(
                request: requestAction,
                connection: .cleanupConnections(cleanupContext, isShutdown: isShutdown)
            )
        }

        // MARK: - Private Methods -

        // MARK: Idle connection management

        private mutating func nextActionForIdleConnection(
            at index: Int,
            context: HTTP1Connections.IdleConnectionContext
        ) -> Action {
            switch self.state {
            case .running:
                switch context.use {
                case .generalPurpose:
                    return self.nextActionForIdleGeneralPurposeConnection(at: index, context: context)
                case .eventLoop:
                    return self.nextActionForIdleEventLoopConnection(at: index, context: context)
                }
            case .shuttingDown(let unclean):
                assert(self.requests.isEmpty)
                let connection = self.connections.closeConnection(at: index)
                if self.connections.isEmpty {
                    return .init(
                        request: .none,
                        connection: .closeConnection(connection, isShutdown: .yes(unclean: unclean))
                    )
                }
                return .init(
                    request: .none,
                    connection: .closeConnection(connection, isShutdown: .no)
                )

            case .shutDown:
                preconditionFailure("It the pool is already shutdown, all connections must have been torn down.")
            }
        }

        private mutating func nextActionForIdleGeneralPurposeConnection(
            at index: Int,
            context: HTTP1Connections.IdleConnectionContext
        ) -> Action {
            // 1. Check if there are waiting requests in the general purpose queue
            if let request = self.requests.popFirst(for: nil) {
                return .init(
                    request: .executeRequest(request, self.connections.leaseConnection(at: index), cancelTimeout: true),
                    connection: .none
                )
            }

            // 2. Check if there are waiting requests in the matching eventLoop queue
            if let request = self.requests.popFirst(for: context.eventLoop) {
                return .init(
                    request: .executeRequest(request, self.connections.leaseConnection(at: index), cancelTimeout: true),
                    connection: .none
                )
            }

            // 3. Create a timeout timer to ensure the connection is closed if it is idle for too
            //    long.
            let (connectionID, eventLoop) = self.connections.parkConnection(at: index)
            return .init(
                request: .none,
                connection: .scheduleTimeoutTimer(connectionID, on: eventLoop)
            )
        }

        private mutating func nextActionForIdleEventLoopConnection(
            at index: Int,
            context: HTTP1Connections.IdleConnectionContext
        ) -> Action {
            // Check if there are waiting requests in the matching eventLoop queue
            if let request = self.requests.popFirst(for: context.eventLoop) {
                return .init(
                    request: .executeRequest(request, self.connections.leaseConnection(at: index), cancelTimeout: true),
                    connection: .none
                )
            }

            // TBD: What do we want to do, if there are more requests in the general purpose queue?
            //      For now, we don't care. The general purpose connections will pick those up
            //      eventually.
            //
            // If there is no more eventLoop bound work, we close the eventLoop bound connections.
            // We don't park them.
            return .init(
                request: .none,
                connection: .closeConnection(self.connections.closeConnection(at: index), isShutdown: .no)
            )
        }

        // MARK: Failed/Closed connection management

        private mutating func nextActionForFailedConnection(
            at index: Int,
            context: HTTP1Connections.FailedConnectionContext
        ) -> Action {
            switch self.state {
            case .running:
                switch context.use {
                case .generalPurpose:
                    return self.nextActionForFailedGeneralPurposeConnection(at: index, context: context)
                case .eventLoop:
                    return self.nextActionForFailedEventLoopConnection(at: index, context: context)
                }

            case .shuttingDown(let unclean):
                assert(self.requests.isEmpty)
                self.connections.removeConnection(at: index)
                if self.connections.isEmpty {
                    return .init(
                        request: .none,
                        connection: .cleanupConnections(.init(), isShutdown: .yes(unclean: unclean))
                    )
                }
                return .none

            case .shutDown:
                preconditionFailure("If the pool is already shutdown, all connections must have been torn down.")
            }
        }

        private mutating func nextActionForFailedGeneralPurposeConnection(
            at index: Int,
            context: HTTP1Connections.FailedConnectionContext
        ) -> Action {
            if context.connectionsStartingForUseCase < self.requests.generalPurposeCount {
                // if we have more requests queued up, than we have starting connections, we should
                // create a new connection
                let (newConnectionID, newEventLoop) = self.connections.replaceConnection(at: index)
                return .init(
                    request: .none,
                    connection: .createConnection(newConnectionID, on: newEventLoop)
                )
            }
            self.connections.removeConnection(at: index)
            return .none
        }

        private mutating func nextActionForFailedEventLoopConnection(
            at index: Int,
            context: HTTP1Connections.FailedConnectionContext
        ) -> Action {
            if context.connectionsStartingForUseCase < self.requests.count(for: context.eventLoop) {
                // if we have more requests queued up, than we have starting connections, we should
                // create a new connection
                let (newConnectionID, newEventLoop) = self.connections.replaceConnection(at: index)
                return .init(
                    request: .none,
                    connection: .createConnection(newConnectionID, on: newEventLoop)
                )
            }
            self.connections.removeConnection(at: index)
            return .none
        }

        private func calculateBackoff(failedAttempt attempts: Int) -> TimeAmount {
            // Our backoff formula is: 100ms * 1.25^(attempts - 1) that is capped of at 1minute
            // This means for:
            //   -  1 failed attempt :  100ms
            //   -  5 failed attempts: ~300ms
            //   - 10 failed attempts: ~930ms
            //   - 15 failed attempts: ~2.84s
            //   - 20 failed attempts: ~8.67s
            //   - 25 failed attempts: ~26s
            //   - 29 failed attempts: ~60s (max out)

            let start = Double(TimeAmount.milliseconds(100).nanoseconds)
            let backoffNanoseconds = Int64(start * pow(1.25, Double(attempts - 1)))

            let backoff: TimeAmount = min(.nanoseconds(backoffNanoseconds), .seconds(60))

            // Calculate a 3% jitter range
            let jitterRange = (backoff.nanoseconds / 100) * 3
            // Pick a random element from the range +/- jitter range.
            let jitter: TimeAmount = .nanoseconds((-jitterRange...jitterRange).randomElement()!)
            let jitteredBackoff = backoff + jitter
            return jitteredBackoff
        }
    }
}

extension HTTPConnectionPool.HTTP1StateMachine: CustomStringConvertible {
    var description: String {
        let stats = self.connections.stats
        let queued = self.requests.count

        return "connections: [connecting: \(stats.connecting) | backoff: \(stats.backingOff) | leased: \(stats.leased) | idle: \(stats.idle)], queued: \(queued)"
    }
}
