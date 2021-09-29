//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//
// LinuxMain.swift
//
import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

#if os(Linux) || os(FreeBSD)
    @testable import AsyncHTTPClientTests

    XCTMain([
        testCase(HTTP1ClientChannelHandlerTests.allTests),
        testCase(HTTP1ConnectionStateMachineTests.allTests),
        testCase(HTTP1ConnectionTests.allTests),
        testCase(HTTP1ProxyConnectHandlerTests.allTests),
        testCase(HTTP2ClientRequestHandlerTests.allTests),
        testCase(HTTP2ConnectionTests.allTests),
        testCase(HTTP2IdleHandlerTests.allTests),
        testCase(HTTPClientCookieTests.allTests),
        testCase(HTTPClientInternalTests.allTests),
        testCase(HTTPClientNIOTSTests.allTests),
        testCase(HTTPClientSOCKSTests.allTests),
        testCase(HTTPClientTests.allTests),
        testCase(HTTPConnectionPoolTests.allTests),
        testCase(HTTPConnectionPool_FactoryTests.allTests),
        testCase(HTTPConnectionPool_HTTP1ConnectionsTests.allTests),
        testCase(HTTPConnectionPool_HTTP1StateMachineTests.allTests),
        testCase(HTTPConnectionPool_HTTP2ConnectionsTests.allTests),
        testCase(HTTPConnectionPool_ManagerTests.allTests),
        testCase(HTTPConnectionPool_RequestQueueTests.allTests),
        testCase(HTTPRequestStateMachineTests.allTests),
        testCase(LRUCacheTests.allTests),
        testCase(RequestBagTests.allTests),
        testCase(RequestValidationTests.allTests),
        testCase(SOCKSEventsHandlerTests.allTests),
        testCase(SSLContextCacheTests.allTests),
        testCase(TLSEventsHandlerTests.allTests),
    ])
#endif
