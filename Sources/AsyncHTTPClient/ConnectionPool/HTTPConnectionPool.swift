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

import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOSSL

protocol HTTPConnectionPoolDelegate {
    func connectionPoolDidShutdown(_ pool: HTTPConnectionPool, unclean: Bool)
}

final class HTTPConnectionPool {
    struct Connection: Hashable {
        typealias ID = Int

        private enum Reference {
            case http1_1(HTTP1Connection)
            case http2(HTTP2Connection)
            case __testOnly_connection(ID, EventLoop)
        }

        private let _ref: Reference

        fileprivate static func http1_1(_ conn: HTTP1Connection) -> Self {
            Connection(_ref: .http1_1(conn))
        }

        fileprivate static func http2(_ conn: HTTP2Connection) -> Self {
            Connection(_ref: .http2(conn))
        }

        static func __testOnly_connection(id: ID, eventLoop: EventLoop) -> Self {
            Connection(_ref: .__testOnly_connection(id, eventLoop))
        }

        var id: ID {
            switch self._ref {
            case .http1_1(let connection):
                return connection.id
            case .http2(let connection):
                return connection.id
            case .__testOnly_connection(let id, _):
                return id
            }
        }

        var eventLoop: EventLoop {
            switch self._ref {
            case .http1_1(let connection):
                return connection.channel.eventLoop
            case .http2(let connection):
                return connection.channel.eventLoop
            case .__testOnly_connection(_, let eventLoop):
                return eventLoop
            }
        }

        fileprivate func executeRequest(_ request: HTTPExecutableRequest) {
            switch self._ref {
            case .http1_1(let connection):
                return connection.executeRequest(request)
            case .http2(let connection):
                return connection.executeRequest(request)
            case .__testOnly_connection:
                break
            }
        }

        /// Shutdown cancels any running requests on the connection and then closes the connection
        fileprivate func shutdown() {
            switch self._ref {
            case .http1_1(let connection):
                return connection.shutdown()
            case .http2(let connection):
                return connection.shutdown()
            case .__testOnly_connection:
                break
            }
        }

        /// Closes the connection without cancelling running requests. Use this when you are sure, that the
        /// connection is currently idle.
        fileprivate func close(promise: EventLoopPromise<Void>?) {
            switch self._ref {
            case .http1_1(let connection):
                return connection.close(promise: promise)
            case .http2(let connection):
                return connection.close(promise: promise)
            case .__testOnly_connection:
                promise?.succeed(())
            }
        }

        static func == (lhs: HTTPConnectionPool.Connection, rhs: HTTPConnectionPool.Connection) -> Bool {
            switch (lhs._ref, rhs._ref) {
            case (.http1_1(let lhsConn), .http1_1(let rhsConn)):
                return lhsConn.id == rhsConn.id
            case (.http2(let lhsConn), .http2(let rhsConn)):
                return lhsConn.id == rhsConn.id
            case (.__testOnly_connection(let lhsID, let lhsEventLoop), .__testOnly_connection(let rhsID, let rhsEventLoop)):
                return lhsID == rhsID && lhsEventLoop === rhsEventLoop
            default:
                return false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self._ref {
            case .http1_1(let conn):
                hasher.combine(conn.id)
            case .http2(let conn):
                hasher.combine(conn.id)
            case .__testOnly_connection(let id, let eventLoop):
                hasher.combine(id)
                hasher.combine(eventLoop.id)
            }
        }
    }

    private let stateLock = Lock()
    private var _state: StateMachine {
        didSet {
            self.logger.trace("Connection Pool State changed", metadata: [
                "key": "\(self.key)",
                "state": "\(self._state)",
            ])
        }
    }

    private static let fallbackConnectTimeout: TimeAmount = .seconds(30)

    let key: ConnectionPool.Key

    private let timerLock = Lock()
    private var _requestTimer = [Request.ID: Scheduled<Void>]()
    private var _idleTimer = [Connection.ID: Scheduled<Void>]()
    private var _backoffTimer = [Connection.ID: Scheduled<Void>]()

    private var logger: Logger

    private let eventLoopGroup: EventLoopGroup
    private let connectionFactory: ConnectionFactory
    private let clientConfiguration: HTTPClient.Configuration
    private let idleConnectionTimeout: TimeAmount

    let delegate: HTTPConnectionPoolDelegate

    init(eventLoopGroup: EventLoopGroup,
         sslContextCache: SSLContextCache,
         tlsConfiguration: TLSConfiguration?,
         clientConfiguration: HTTPClient.Configuration,
         key: ConnectionPool.Key,
         delegate: HTTPConnectionPoolDelegate,
         idGenerator: Connection.ID.Generator,
         backgroundActivityLogger logger: Logger) {
        self.eventLoopGroup = eventLoopGroup
        self.connectionFactory = ConnectionFactory(
            key: key,
            tlsConfiguration: tlsConfiguration,
            clientConfiguration: clientConfiguration,
            sslContextCache: sslContextCache
        )
        self.clientConfiguration = clientConfiguration
        self.key = key
        self.delegate = delegate
        self.logger = logger

        self.idleConnectionTimeout = clientConfiguration.connectionPool.idleTimeout

        self._state = StateMachine(
            eventLoopGroup: eventLoopGroup,
            idGenerator: idGenerator,
            maximumConcurrentHTTP1Connections: 8
        )
    }

    func executeRequest(_ request: HTTPSchedulableRequest) {
        let action = self.stateLock.withLock { () -> StateMachine.Action in
            self._state.executeRequest(.init(request))
        }
        self.run(action: action)
    }

    func shutdown() {
        let action = self.stateLock.withLock { () -> StateMachine.Action in
            self._state.shutdown()
        }
        self.run(action: action)
    }

    // MARK: Run actions

    private func run(action: StateMachine.Action) {
        self.runConnectionAction(action.connection)
        self.runRequestAction(action.request)
    }

    private func runConnectionAction(_ action: StateMachine.ConnectionAction) {
        switch action {
        case .createConnection(let connectionID, let eventLoop):
            self.createConnection(connectionID, on: eventLoop)

        case .scheduleBackoffTimer(let connectionID, let backoff, on: let eventLoop):
            self.scheduleConnectionStartBackoffTimer(connectionID, backoff, on: eventLoop)

        case .scheduleTimeoutTimer(let connectionID, on: let eventLoop):
            self.scheduleIdleTimerForConnection(connectionID, on: eventLoop)

        case .cancelTimeoutTimer(let connectionID):
            self.cancelIdleTimerForConnection(connectionID)

        case .closeConnection(let connection, isShutdown: let isShutdown):
            // we are not interested in the close future...
            connection.close(promise: nil)

            if case .yes(let unclean) = isShutdown {
                self.delegate.connectionPoolDidShutdown(self, unclean: unclean)
            }

        case .cleanupConnections(let cleanupContext, isShutdown: let isShutdown):
            for connection in cleanupContext.close {
                connection.close(promise: nil)
            }

            for connection in cleanupContext.cancel {
                connection.shutdown()
            }

            for connectionID in cleanupContext.connectBackoff {
                self.cancelConnectionStartBackoffTimer(connectionID)
            }

            if case .yes(let unclean) = isShutdown {
                self.delegate.connectionPoolDidShutdown(self, unclean: unclean)
            }

        case .none:
            break
        }
    }

    private func runRequestAction(_ action: StateMachine.RequestAction) {
        // The order of execution fail/execute request vs cancelling the request timeout timer does
        // not matter in the actions here. The actions don't cause any side effects that will be
        // reported back to the state machine and are not dependent on each other.

        switch action {
        case .executeRequest(let request, let connection, cancelTimeout: let cancelTimeout):
            if cancelTimeout {
                self.cancelRequestTimeout(request.id)
            }
            connection.executeRequest(request.req)

        case .executeRequestsAndCancelTimeouts(let requests, let connection):
            self.cancelRequestTimeouts(requests)
            requests.forEach { connection.executeRequest($0.req) }

        case .failRequest(let request, let error, cancelTimeout: let cancelTimeout):
            if cancelTimeout {
                self.cancelRequestTimeout(request.id)
            }
            request.req.fail(error)

        case .failRequestsAndCancelTimeouts(let requests, let error):
            self.cancelRequestTimeouts(requests)
            requests.forEach { $0.req.fail(error) }

        case .scheduleRequestTimeout(let request, on: let eventLoop):
            self.scheduleRequestTimeout(request, on: eventLoop)

        case .cancelRequestTimeout(let requestID):
            self.cancelRequestTimeout(requestID)

        case .none:
            break
        }
    }

    private func createConnection(_ connectionID: Connection.ID, on eventLoop: EventLoop) {
        // Even though this function is called make it actually creates/establishes a connection.
        // TBD: Should we rename it? To what?
        self.connectionFactory.makeConnection(
            for: self,
            connectionID: connectionID,
            http1ConnectionDelegate: self,
            http2ConnectionDelegate: self,
            deadline: .now() + (self.clientConfiguration.timeout.connect ?? Self.fallbackConnectTimeout),
            eventLoop: eventLoop,
            logger: self.logger
        )
    }

    private func scheduleRequestTimeout(_ request: Request, on eventLoop: EventLoop) {
        let requestID = request.id
        let scheduled = eventLoop.scheduleTask(deadline: request.connectionDeadline) {
            // The timer has fired. Now we need to do a couple of things:
            //
            // 1. Remove ourselves from the timer dictionary to not leak any data. If our
            //    waiter entry still exists, we need to tell the state machine, that we want
            //    to fail the request.
            let timeoutFired = self.timerLock.withLock {
                self._requestTimer.removeValue(forKey: requestID) != nil
            }

            // 2. If the entry did not exists anymore, we can assume that the request was
            //    scheduled on another connection. The timer still fired anyhow because of a
            //    race. In such a situation we don't need to do anything.
            guard timeoutFired else { return }

            // 3. Tell the state machine about the timeout
            let action = self.stateLock.withLock {
                self._state.timeoutRequest(requestID)
            }

            self.run(action: action)
        }

        self.timerLock.withLockVoid {
            assert(self._requestTimer[requestID] == nil)
            self._requestTimer[requestID] = scheduled
        }

        request.req.requestWasQueued(self)
    }

    private func cancelRequestTimeout(_ id: Request.ID) {
        let scheduled = self.timerLock.withLock {
            self._requestTimer.removeValue(forKey: id)
        }

        scheduled?.cancel()
    }

    private func cancelRequestTimeouts(_ requests: [Request]) {
        let scheduled = self.timerLock.withLock {
            requests.compactMap {
                self._requestTimer.removeValue(forKey: $0.id)
            }
        }
        scheduled.forEach { $0.cancel() }
    }

    private func scheduleIdleTimerForConnection(_ connectionID: Connection.ID, on eventLoop: EventLoop) {
        let scheduled = eventLoop.scheduleTask(in: self.idleConnectionTimeout) {
            // there might be a race between a cancelTimer call and the triggering
            // of this scheduled task. both want to acquire the lock
            let timerExisted = self.timerLock.withLock {
                self._idleTimer.removeValue(forKey: connectionID) != nil
            }

            guard timerExisted else { return }

            let action = self.stateLock.withLock {
                self._state.connectionIdleTimeout(connectionID)
            }
            self.run(action: action)
        }

        self.timerLock.withLock {
            assert(self._idleTimer[connectionID] == nil)
            self._idleTimer[connectionID] = scheduled
        }
    }

    private func cancelIdleTimerForConnection(_ connectionID: Connection.ID) {
        let cancelTimer = self.timerLock.withLock {
            self._idleTimer.removeValue(forKey: connectionID)
        }

        cancelTimer?.cancel()
    }

    private func scheduleConnectionStartBackoffTimer(
        _ connectionID: Connection.ID,
        _ timeAmount: TimeAmount,
        on eventLoop: EventLoop
    ) {
        let scheduled = eventLoop.scheduleTask(in: timeAmount) {
            // there might be a race between a backoffTimer and the pool shutting down.
            let timerExisted = self.timerLock.withLock {
                self._backoffTimer.removeValue(forKey: connectionID) != nil
            }

            guard timerExisted else { return }

            let action = self.stateLock.withLock {
                self._state.connectionCreationBackoffDone(connectionID)
            }
            self.run(action: action)
        }

        self.timerLock.withLock {
            assert(self._backoffTimer[connectionID] == nil)
            self._backoffTimer[connectionID] = scheduled
        }
    }

    private func cancelConnectionStartBackoffTimer(_ connectionID: Connection.ID) {
        let backoffTimer = self.timerLock.withLock {
            self._backoffTimer[connectionID]
        }

        backoffTimer?.cancel()
    }
}

// MARK: - Protocol methods -

extension HTTPConnectionPool: HTTPConnectionRequester {
    func http1ConnectionCreated(_ connection: HTTP1Connection) {
        let action = self.stateLock.withLock {
            self._state.newHTTP1ConnectionCreated(.http1_1(connection))
        }
        self.run(action: action)
    }

    func http2ConnectionCreated(_ connection: HTTP2Connection, maximumStreams: Int) {
        preconditionFailure("Did not expect http/2 connections right now.")
//        let action = self.stateLock.withLock { () -> StateMachine.Action in
//            if let settings = connection.settings {
//                return self._state.newHTTP2ConnectionCreated(.http2(connection), settings: settings)
//            } else {
//                // immidiate connection closure before we can register with state machine
//                // is the only reason we don't have settings
//                struct ImmidiateConnectionClose: Error {}
//                return self._state.failedToCreateNewConnection(ImmidiateConnectionClose(), connectionID: connection.id)
//            }
//        }
//        self.run(action: action)
    }

    func failedToCreateHTTPConnection(_ connectionID: HTTPConnectionPool.Connection.ID, error: Error) {
        let action = self.stateLock.withLock {
            self._state.failedToCreateNewConnection(error, connectionID: connectionID)
        }
        self.run(action: action)
    }
}

extension HTTPConnectionPool: HTTP1ConnectionDelegate {
    func http1ConnectionClosed(_ connection: HTTP1Connection) {
        let action = self.stateLock.withLock {
            self._state.connectionClosed(connection.id)
        }
        self.run(action: action)
    }

    func http1ConnectionReleased(_ connection: HTTP1Connection) {
        let action = self.stateLock.withLock {
            self._state.http1ConnectionReleased(connection.id)
        }
        self.run(action: action)
    }
}

extension HTTPConnectionPool: HTTP2ConnectionDelegate {
    func http2Connection(_ connection: HTTP2Connection, newMaxStreamSetting: Int) {
        // ignore for now
    }

    func http2ConnectionGoAwayReceived(_: HTTP2Connection) {
        // ignore for now
    }

    func http2ConnectionClosed(_: HTTP2Connection) {
        // ignore for now
//        let action = self.stateLock.withLock {
//            self._state.connectionClosed(connection.id)
//        }
//        self.run(action: action)
    }

    func http2ConnectionStreamClosed(_ connection: HTTP2Connection, availableStreams: Int) {
        // ignore for now
//        let action = self.stateLock.withLock {
//            self._state.http2ConnectionStreamClosed(connection.id, availableStreams: availableStreams)
//        }
//        self.run(action: action)
    }
}

extension HTTPConnectionPool: HTTPRequestScheduler {
    func cancelRequest(_ request: HTTPSchedulableRequest) {
        let requestID = Request(request).id
        let action = self.stateLock.withLock {
            self._state.cancelRequest(requestID)
        }
        self.run(action: action)
    }
}

extension HTTPConnectionPool {
    /// This is a wrapper that we use inside the connection pool state machine to ensure that
    /// the actual request can not be accessed at any time. Further it exposes all that is needed within
    /// the state machine. A request ID and the `EventLoop` requirement.
    struct Request {
        struct ID: Hashable {
            let objectIdentifier: ObjectIdentifier
            let eventLoopID: EventLoopID?

            fileprivate init(_ request: HTTPSchedulableRequest, eventLoopRequirement eventLoopID: EventLoopID?) {
                self.objectIdentifier = ObjectIdentifier(request)
                self.eventLoopID = eventLoopID
            }
        }

        fileprivate let req: HTTPSchedulableRequest

        init(_ request: HTTPSchedulableRequest) {
            self.req = request
        }

        var id: HTTPConnectionPool.Request.ID {
            HTTPConnectionPool.Request.ID(self.req, eventLoopRequirement: self.requiredEventLoop?.id)
        }

        var requiredEventLoop: EventLoop? {
            self.req.requiredEventLoop
        }

        var preferredEventLoop: EventLoop {
            self.req.preferredEventLoop
        }

        var connectionDeadline: NIODeadline {
            self.req.connectionDeadline
        }

        func __testOnly_wrapped_request() -> HTTPSchedulableRequest {
            self.req
        }
    }
}

struct EventLoopID: Hashable {
    private var id: Identifier

    private enum Identifier: Hashable {
        case objectIdentifier(ObjectIdentifier)
        case __testOnly_fakeID(Int)
    }

    init(_ eventLoop: EventLoop) {
        self.init(.objectIdentifier(ObjectIdentifier(eventLoop)))
    }

    private init(_ id: Identifier) {
        self.id = id
    }

    static func __testOnly_fakeID(_ id: Int) -> EventLoopID {
        return EventLoopID(.__testOnly_fakeID(id))
    }
}

extension EventLoop {
    var id: EventLoopID { EventLoopID(self) }
}
