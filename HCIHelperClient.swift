//
//  HCIHelperClient.swift
//  HyperVibe
//
//  User-space client for the installed HyperVibeHCIHelper LaunchDaemon.
//

import Foundation

enum HCIHelperClient {
    enum ClientError: LocalizedError {
        case notInstalled
        case connectFailed(String)
        case badResponse(String)
        case helper(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "麦克风组件未安装"
            case .connectFailed(let message):
                return "无法连接麦克风组件: \(message)"
            case .badResponse(let message):
                return "麦克风组件响应异常: \(message)"
            case .helper(let message):
                return message
            }
        }
    }

    private static let cacheLock = NSLock()
    private static var cachedReady: Bool?

    static func ping(timeout: TimeInterval = 1.0) -> Bool {
        (try? send(.ping, timeout: timeout)) == .pong
    }

    static func isReady() -> Bool {
        #if DEBUG
        assert(!Thread.isMainThread, "HCIHelperClient.isReady must not block main")
        #endif
        let ready: Bool
        if case .ready = HelperInstallCoordinator.computeReadiness() {
            ready = true
        } else {
            ready = HCIHelperPaths.isInstalled && ping()
        }
        setCachedReady(ready)
        return ready
    }

    /// Pure snapshot for menu rebuilds — never performs socket I/O.
    /// Call `HelperInstallCoordinator.shared.refresh()` to update asynchronously.
    static func isReadyCached() -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let ready = cachedReady {
            return ready
        }
        // Cold start before first probe: treat missing helper binary as not ready
        // without blocking, and optimistic-false otherwise until refresh lands.
        return false
    }

    static func setCachedReady(_ ready: Bool) {
        cacheLock.lock()
        cachedReady = ready
        cacheLock.unlock()
    }

    static func invalidateReadyCache() {
        cacheLock.lock()
        cachedReady = nil
        cacheLock.unlock()
    }

    @discardableResult
    static func send(
        _ request: HCIHelperRequest,
        socketPath: String = HCIHelperPaths.socketPath,
        timeout: TimeInterval = 8.0,
        connectTimeout: TimeInterval = 0.5
    ) throws -> HCIHelperResponse {
        #if DEBUG
        assert(!Thread.isMainThread, "HCIHelperClient.send must not block main")
        #endif
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.connectFailed("socket()") }

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw ClientError.connectFailed("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in pathBytes.enumerated() {
                buf[i] = b
            }
            buf[pathBytes.count] = 0
        }

        let connected: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            let err = errno
            if err != EINPROGRESS && err != EALREADY {
                close(fd)
                if !HCIHelperPaths.isInstalled {
                    throw ClientError.notInstalled
                }
                throw ClientError.connectFailed(String(cString: strerror(err)))
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ms = Int32(max(1, connectTimeout * 1000))
            let pr = poll(&pfd, 1, ms)
            if pr <= 0 {
                close(fd)
                throw ClientError.connectFailed(pr == 0 ? "connect timeout" : "poll failed")
            }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
            if soError != 0 {
                close(fd)
                throw ClientError.connectFailed(String(cString: strerror(soError)))
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        defer { close(fd) }

        var tv = timeval(
            tv_sec: __darwin_time_t(timeout),
            tv_usec: 0
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let payload = HCIHelperCodec.encode(request)
        guard let data = payload.data(using: .utf8) else {
            throw ClientError.badResponse("encode failed")
        }
        let wrote = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return write(fd, base, data.count)
        }
        guard wrote == data.count else {
            throw ClientError.connectFailed("write failed")
        }

        var responseData = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            responseData.append(byte)
            if byte == 0x0A { break }
            if responseData.count > 16_384 { break }
        }
        guard let line = String(data: responseData, encoding: .utf8),
              let response = HCIHelperCodec.decodeResponse(line) else {
            throw ClientError.badResponse(String(data: responseData, encoding: .utf8) ?? "<empty>")
        }
        if case .error(let message) = response {
            throw ClientError.helper(message)
        }
        return response
    }
}
