//
//  RemoteWebServer.swift
//  HyperVibe
//
//  Local-only HTTP + WebSocket server for the iPhone remote PWA.
//

import AppKit
import Darwin
import Foundation
import Network

final class RemoteWebServer {
    struct Status {
        let enabled: Bool
        let connectURL: String?
        let error: String?
    }

    private struct ActiveHold {
        let action: ButtonAction
        var lastHeartbeat: TimeInterval
    }

    private struct Client {
        let connection: NWConnection
        let sourcePrefix: String
        let connectedAt: TimeInterval
        var authenticated = false
        var holds: [String: ActiveHold] = [:]
    }

    static let enabledDefaultsKey = "remoteWebServerEnabled"
    static let tokenDefaultsKey = "remoteWebServerToken"

    private static let httpPortValue: UInt16 = 8765
    private static let webSocketPortValue: UInt16 = 8766
    private static let heartbeatTimeout: TimeInterval = 1.5
    private static let authenticationTimeout: TimeInterval = 5.0
    private static let networkChangeDebounce: TimeInterval = 2.0
    private static let maximumMessageSize = 4_096
    private static let webSourcePrefix = "web:"

    private weak var inputHandler: RemoteInputHandler?
    private let actionResolver: (String) -> ButtonAction?
    private let commandHandler: (SwipeAction) -> Void
    private let queue = DispatchQueue(label: "com.hypervibe.remote-web-server")
    private let pathMonitor = NWPathMonitor()
    private let token: String

    private var desiredEnabled: Bool
    private var httpListener: NWListener?
    private var webSocketListener: NWListener?
    private var httpReady = false
    private var webSocketReady = false
    private var localAddress: String?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var watchdog: DispatchSourceTimer?
    private var networkRestartWorkItem: DispatchWorkItem?
    private var sleepObserver: NSObjectProtocol?

    var onStatusChange: ((Status) -> Void)?

    init(
        inputHandler: RemoteInputHandler,
        actionResolver: @escaping (String) -> ButtonAction?,
        commandHandler: @escaping (SwipeAction) -> Void
    ) {
        self.inputHandler = inputHandler
        self.actionResolver = actionResolver
        self.commandHandler = commandHandler

        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: Self.tokenDefaultsKey), !existing.isEmpty {
            token = existing
        } else {
            let generated = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            token = generated
            defaults.set(generated, forKey: Self.tokenDefaultsKey)
        }
        desiredEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.releaseForSystemSleep()
        }

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            self?.scheduleNetworkRestartLocked()
        }
        pathMonitor.start(queue: queue)
    }

    deinit {
        pathMonitor.cancel()
        networkRestartWorkItem?.cancel()
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func startFromSavedPreference() {
        if desiredEnabled {
            queue.async { [weak self] in
                self?.startLocked()
            }
        } else {
            publishStatus(Status(enabled: false, connectURL: nil, error: nil))
        }
    }

    func setEnabled(_ enabled: Bool) {
        desiredEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)

        // The menu action runs on the main thread, so release immediately instead of
        // waiting behind network callbacks if the server is disabled during a hold.
        if !enabled {
            inputHandler?.releaseHeldKeys(sourcePrefix: Self.webSourcePrefix)
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            if enabled {
                self.startLocked()
            } else {
                self.stopLocked()
                self.publishStatus(Status(enabled: false, connectURL: nil, error: nil))
            }
        }
    }

    /// Stop listeners without changing the persisted enable preference.
    func shutdown() {
        inputHandler?.releaseHeldKeys(sourcePrefix: Self.webSourcePrefix)
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func startLocked() {
        guard desiredEnabled, httpListener == nil, webSocketListener == nil else { return }
        guard let address = Self.privateIPv4Address() else {
            publishStatus(Status(
                enabled: true,
                connectURL: nil,
                error: "No private LAN address"
            ))
            return
        }
        guard let httpPort = NWEndpoint.Port(rawValue: Self.httpPortValue),
              let webSocketPort = NWEndpoint.Port(rawValue: Self.webSocketPortValue) else {
            publishStatus(Status(enabled: true, connectURL: nil, error: "Invalid port"))
            return
        }

        do {
            localAddress = address
            httpReady = false
            webSocketReady = false

            let httpParameters = Self.parameters(boundTo: address)
            let httpListener = try NWListener(using: httpParameters, on: httpPort)
            httpListener.newConnectionLimit = 16
            httpListener.newConnectionHandler = { [weak self] connection in
                self?.acceptHTTPConnection(connection)
            }
            httpListener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, isWebSocket: false)
            }

            let webSocketOptions = NWProtocolWebSocket.Options(.version13)
            webSocketOptions.autoReplyPing = true
            webSocketOptions.maximumMessageSize = Self.maximumMessageSize
            webSocketOptions.setClientRequestHandler(queue) { _, _ in
                NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }

            let webSocketParameters = Self.parameters(boundTo: address)
            webSocketParameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
            let webSocketListener = try NWListener(using: webSocketParameters, on: webSocketPort)
            webSocketListener.newConnectionLimit = 8
            webSocketListener.newConnectionHandler = { [weak self] connection in
                self?.acceptWebSocketConnection(connection)
            }
            webSocketListener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, isWebSocket: true)
            }

            self.httpListener = httpListener
            self.webSocketListener = webSocketListener
            startWatchdogLocked()
            publishStatus(Status(enabled: true, connectURL: nil, error: nil))
            httpListener.start(queue: queue)
            webSocketListener.start(queue: queue)
        } catch {
            stopLocked()
            publishStatus(Status(enabled: true, connectURL: nil, error: error.localizedDescription))
        }
    }

    private func stopLocked() {
        networkRestartWorkItem?.cancel()
        networkRestartWorkItem = nil
        watchdog?.cancel()
        watchdog = nil
        httpListener?.cancel()
        webSocketListener?.cancel()
        httpListener = nil
        webSocketListener = nil
        httpReady = false
        webSocketReady = false
        localAddress = nil

        let activeClients = Array(clients.values)
        clients.removeAll()
        for client in activeClients {
            client.connection.cancel()
            releaseInputHolds(sourcePrefix: client.sourcePrefix)
        }
    }

    private func scheduleNetworkRestartLocked() {
        guard desiredEnabled else { return }
        networkRestartWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.networkRestartWorkItem = nil

            let currentAddress = Self.privateIPv4Address()
            guard currentAddress != self.localAddress else { return }

            let oldAddress = self.localAddress ?? "none"
            let newAddress = currentAddress ?? "none"
            rmDebug("📱 iPhone remote network changed: \(oldAddress) → \(newAddress)")
            self.stopLocked()
            self.startLocked()
        }
        networkRestartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.networkChangeDebounce, execute: workItem)
    }

    private func handleListenerState(_ state: NWListener.State, isWebSocket: Bool) {
        switch state {
        case .ready:
            if isWebSocket {
                webSocketReady = true
            } else {
                httpReady = true
            }
            guard httpReady, webSocketReady, let address = localAddress else { return }
            let connectURL = "http://\(address):\(Self.httpPortValue)/?token=\(token)"
            publishStatus(Status(enabled: true, connectURL: connectURL, error: nil))
            rmDebug("📱 iPhone remote ready at \(connectURL)")
        case .failed(let error):
            guard desiredEnabled else { return }
            let message = error.localizedDescription
            stopLocked()
            publishStatus(Status(enabled: true, connectURL: nil, error: message))
            rmDebug("⚠️ iPhone remote server failed: \(message)")
        case .waiting(let error):
            publishStatus(Status(enabled: true, connectURL: nil, error: error.localizedDescription))
        case .setup, .cancelled:
            break
        @unknown default:
            break
        }
    }

    // MARK: - HTTP

    private func acceptHTTPConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: queue)
        receiveHTTPRequest(connection, buffer: Data())
    }

    private func receiveHTTPRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }

            var requestData = buffer
            if let data = data {
                requestData.append(data)
            }
            if requestData.count > 16_384 {
                self.sendHTTPResponse(connection, status: "413 Payload Too Large", contentType: "text/plain", body: Data("Request too large".utf8))
                return
            }

            let headerTerminator = Data([13, 10, 13, 10])
            if requestData.range(of: headerTerminator) != nil {
                self.handleHTTPRequest(connection, data: requestData)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receiveHTTPRequest(connection, buffer: requestData)
            }
        }
    }

    private func handleHTTPRequest(_ connection: NWConnection, data: Data) {
        guard let request = String(data: data, encoding: .utf8),
              let firstLine = request.components(separatedBy: "\r\n").first else {
            sendHTTPResponse(connection, status: "400 Bad Request", contentType: "text/plain", body: Data("Bad request".utf8))
            return
        }
        let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "GET",
              let components = URLComponents(string: "http://localhost\(parts[1])") else {
            sendHTTPResponse(connection, status: "405 Method Not Allowed", contentType: "text/plain", body: Data("GET required".utf8))
            return
        }

        let suppliedToken = components.queryItems?.first(where: { $0.name == "token" })?.value
        guard suppliedToken == token else {
            sendHTTPResponse(connection, status: "403 Forbidden", contentType: "text/plain", body: Data("Invalid HyperVibe token".utf8))
            return
        }

        switch components.path {
        case "", "/", "/index.html":
            let html = Self.htmlTemplate.replacingOccurrences(of: "__TOKEN__", with: token)
            sendHTTPResponse(connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8))
        case "/manifest.webmanifest":
            sendHTTPResponse(connection, status: "200 OK", contentType: "application/manifest+json", body: manifestData())
        case "/icon.svg":
            sendHTTPResponse(connection, status: "200 OK", contentType: "image/svg+xml", body: Data(Self.iconSVG.utf8))
        default:
            sendHTTPResponse(connection, status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8))
        }
    }

    private func sendHTTPResponse(_ connection: NWConnection, status: String, contentType: String, body: Data) {
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "X-Content-Type-Options: nosniff",
            "",
            ""
        ].joined(separator: "\r\n")
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func manifestData() -> Data {
        let manifest: [String: Any] = [
            "name": "HyperVibe Remote",
            "short_name": "HyperVibe",
            "start_url": "/?token=\(token)",
            "scope": "/",
            "display": "standalone",
            "background_color": "#090b10",
            "theme_color": "#090b10",
            "icons": [[
                "src": "/icon.svg?token=\(token)",
                "sizes": "any",
                "type": "image/svg+xml",
                "purpose": "any maskable"
            ]]
        ]
        return (try? JSONSerialization.data(withJSONObject: manifest)) ?? Data("{}".utf8)
    }

    // MARK: - WebSocket

    private func acceptWebSocketConnection(_ connection: NWConnection) {
        guard clients.count < 8 else {
            connection.cancel()
            return
        }
        let clientID = ObjectIdentifier(connection)
        clients[clientID] = Client(
            connection: connection,
            sourcePrefix: "\(Self.webSourcePrefix)\(UUID().uuidString):",
            connectedAt: Self.now
        )

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection else { return }
            switch state {
            case .ready:
                self.receiveWebSocketMessage(connection)
            case .failed, .cancelled:
                self.removeClientLocked(ObjectIdentifier(connection), cancel: false)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveWebSocketMessage(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, context, _, error in
            guard let self = self, let connection = connection else { return }
            let clientID = ObjectIdentifier(connection)
            if error != nil {
                self.removeClientLocked(clientID, cancel: true)
                return
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                self.removeClientLocked(clientID, cancel: true)
                return
            }
            if let content = content, !content.isEmpty {
                self.handleWebSocketMessage(content, clientID: clientID)
            }
            if self.clients[clientID] != nil {
                self.receiveWebSocketMessage(connection)
            }
        }
    }

    private func handleWebSocketMessage(_ data: Data, clientID: ObjectIdentifier) {
        guard data.count <= Self.maximumMessageSize,
              let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any],
              let type = message["type"] as? String,
              var client = clients[clientID] else {
            removeClientLocked(clientID, cancel: true)
            return
        }

        if !client.authenticated {
            guard type == "auth", message["token"] as? String == token else {
                removeClientLocked(clientID, cancel: true)
                return
            }
            client.authenticated = true
            clients[clientID] = client
            sendJSON(["type": "ready", "heartbeatTimeoutMs": Int(Self.heartbeatTimeout * 1_000)], to: client.connection)
            return
        }

        switch type {
        case "tap":
            guard let actionID = message["actionID"] as? String else {
                sendError("Unknown tap action", to: client.connection)
                return
            }

            if let action = resolveAction(actionID) {
                guard !action.requiresHold else {
                    sendError("Unknown tap action", to: client.connection)
                    return
                }
                let sourceID = "\(client.sourcePrefix)tap:\(UUID().uuidString)"
                performInput { input in
                    input.handleExternalAction(action, sourceID: sourceID, pressed: true)
                }
            } else if let command = SwipeAction.remoteAction(for: actionID) {
                performCommand(command)
            } else {
                sendError("Unknown tap action", to: client.connection)
            }

        case "down":
            guard let actionID = message["actionID"] as? String,
                  let pressID = validPressID(message["pressID"]),
                  let action = resolveAction(actionID),
                  action.requiresHold else {
                sendError("Unknown hold action", to: client.connection)
                return
            }
            if client.holds[pressID] == nil {
                client.holds[pressID] = ActiveHold(action: action, lastHeartbeat: Self.now)
                clients[clientID] = client
                let sourceID = client.sourcePrefix + pressID
                performInput { input in
                    input.handleExternalAction(action, sourceID: sourceID, pressed: true)
                }
            } else {
                client.holds[pressID]?.lastHeartbeat = Self.now
                clients[clientID] = client
            }

        case "heartbeat":
            guard let pressID = validPressID(message["pressID"]), client.holds[pressID] != nil else { return }
            client.holds[pressID]?.lastHeartbeat = Self.now
            clients[clientID] = client

        case "up":
            guard let pressID = validPressID(message["pressID"]),
                  let hold = client.holds.removeValue(forKey: pressID) else { return }
            clients[clientID] = client
            let sourceID = client.sourcePrefix + pressID
            performInput { input in
                input.handleExternalAction(hold.action, sourceID: sourceID, pressed: false)
            }

        default:
            sendError("Unknown message type", to: client.connection)
        }
    }

    private func resolveAction(_ actionID: String) -> ButtonAction? {
        // Existing mappings are owned by the main-thread menu manager.
        DispatchQueue.main.sync {
            actionResolver(actionID)
        }
    }

    private func performCommand(_ action: SwipeAction) {
        DispatchQueue.main.async { [weak self] in
            self?.commandHandler(action)
        }
    }

    private func validPressID(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.isEmpty,
              value.count <= 64,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              }) else { return nil }
        return value
    }

    private func sendError(_ message: String, to connection: NWConnection) {
        sendJSON(["type": "error", "message": message], to: connection)
    }

    private func sendJSON(_ object: [String: Any], to connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "hypervibe-message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func removeClientLocked(_ clientID: ObjectIdentifier, cancel: Bool) {
        guard let client = clients.removeValue(forKey: clientID) else { return }
        if cancel {
            client.connection.cancel()
        }
        releaseInputHolds(sourcePrefix: client.sourcePrefix)
    }

    private func startWatchdogLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.runWatchdogLocked()
        }
        timer.resume()
        watchdog = timer
    }

    private func runWatchdogLocked() {
        let now = Self.now
        for clientID in Array(clients.keys) {
            guard var client = clients[clientID] else { continue }
            if !client.authenticated && now - client.connectedAt > Self.authenticationTimeout {
                removeClientLocked(clientID, cancel: true)
                continue
            }

            let expiredPresses = client.holds.compactMap { pressID, hold in
                now - hold.lastHeartbeat > Self.heartbeatTimeout ? pressID : nil
            }
            for pressID in expiredPresses {
                guard let hold = client.holds.removeValue(forKey: pressID) else { continue }
                let sourceID = client.sourcePrefix + pressID
                performInput { input in
                    input.handleExternalAction(hold.action, sourceID: sourceID, pressed: false)
                }
            }
            clients[clientID] = client
        }
    }

    private func releaseForSystemSleep() {
        inputHandler?.releaseHeldKeys(sourcePrefix: Self.webSourcePrefix)
        queue.async { [weak self] in
            guard let self = self else { return }
            for clientID in Array(self.clients.keys) {
                self.clients[clientID]?.holds.removeAll()
            }
        }
    }

    private func releaseInputHolds(sourcePrefix: String) {
        performInput { input in
            input.releaseHeldKeys(sourcePrefix: sourcePrefix)
        }
    }

    private func performInput(_ operation: @escaping (RemoteInputHandler) -> Void) {
        DispatchQueue.main.async { [weak inputHandler] in
            guard let inputHandler = inputHandler else { return }
            operation(inputHandler)
        }
    }

    private func publishStatus(_ status: Status) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(status)
        }
    }

    // MARK: - Local binding

    private static func parameters(boundTo address: String) -> NWParameters {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        return parameters
    }

    private static func privateIPv4Address() -> String? {
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let first = interfaceList else { return nil }
        defer { freeifaddrs(interfaceList) }

        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = interface.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let address = String(cString: host)
            guard isPrivateIPv4(address) else { continue }
            candidates.append((name, address))
        }

        return candidates.sorted { lhs, rhs in lhs.name < rhs.name }.first?.address
    }

    private static func isPrivateIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        if octets[0] == 10 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        return false
    }

    private static var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Embedded PWA

    private static let iconSVG = #"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
      <rect width="512" height="512" rx="112" fill="#090b10"/>
      <rect x="146" y="150" width="220" height="264" rx="52" fill="#e8ecf5"/>
      <rect x="274" y="70" width="44" height="104" rx="22" fill="#e8ecf5"/>
      <circle cx="256" cy="264" r="64" fill="#090b10"/>
      <rect x="196" y="348" width="120" height="28" rx="14" fill="#090b10"/>
    </svg>
    """#

    private static let htmlTemplate = #"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover,user-scalable=no">
      <meta name="theme-color" content="#090b10">
      <meta name="apple-mobile-web-app-capable" content="yes">
      <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
      <meta name="apple-mobile-web-app-title" content="HyperVibe">
      <link rel="manifest" href="/manifest.webmanifest?token=__TOKEN__">
      <link rel="apple-touch-icon" href="/icon.svg?token=__TOKEN__">
      <title>HyperVibe Remote</title>
      <style>
        :root {
          color-scheme: dark;
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
          --ink: #202225;
          --plate: #d8d4ca;
          --plate-light: #efede6;
          --plate-shadow: #8c887f;
          --accent: #ff654f;
        }
        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        html, body { margin: 0; min-height: 100%; background: #090a0c; color: #f5f4ef; overscroll-behavior: none; }
        body {
          min-height: 100dvh;
          padding: 0;
          display: flex;
          background:
            radial-gradient(circle at 50% -15%, #292c31 0, #111317 40%, #08090b 76%),
            #090a0c;
        }
        main { width: calc(50vw - 10px); height: calc(50dvh - 10px); margin: auto 10px max(10px, env(safe-area-inset-bottom)) auto; display: flex; }
        #status { position: absolute; top: 12.5px; right: 12.5px; z-index: 2; width: 7px; height: 7px; border-radius: 50%; color: #f3b664; background: currentColor; box-shadow: 0 0 8px currentColor; }
        #status.ready { color: #73dc91; }
        .faceplate {
          position: relative;
          flex: 1;
          display: flex;
          flex-direction: column;
          padding-bottom: clamp(10px, 3vw, 14px);
          padding: clamp(10px, 3vw, 14px);
          overflow: hidden;
          border: 1px solid #f8f5ed;
          border-radius: 32px;
          background:
            radial-gradient(circle at 16px 16px, #77746d 0 1.5px, #faf7ef 2px, transparent 3.5px),
            radial-gradient(circle at calc(100% - 16px) 16px, #77746d 0 1.5px, #faf7ef 2px, transparent 3.5px),
            radial-gradient(circle at 16px calc(100% - 16px), #77746d 0 1.5px, #faf7ef 2px, transparent 3.5px),
            radial-gradient(circle at calc(100% - 16px) calc(100% - 16px), #77746d 0 1.5px, #faf7ef 2px, transparent 3.5px),
            linear-gradient(145deg, #ece9e1, var(--plate) 48%, #c5c0b5);
          box-shadow: 0 26px 58px #000b, inset 0 1px #fff, inset 0 -2px 4px #77746d55;
        }
        .deck { flex: 1; display: grid; grid-template-rows: 1fr 1fr 1fr 1.35fr; gap: clamp(8px, 2.5vw, 12px); }
        button {
          appearance: none;
          min-width: 0;
          border: 0;
          font-family: inherit;
          touch-action: none;
          user-select: none;
          -webkit-user-select: none;
          -webkit-touch-callout: none;
          transition: transform 55ms ease, box-shadow 55ms ease, background 80ms ease;
        }
        .key {
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: center;
          gap: 4px;
          min-height: 46px;
          padding: 6px 4px 5px;
          border-radius: 15px;
          color: var(--ink);
        }
        .glyph { font: 720 clamp(15px, 4vw, 19px)/1 ui-monospace, SFMono-Regular, monospace; letter-spacing: -.06em; }
        .key-label { max-width: 100%; overflow: hidden; color: #55575a; font: 700 clamp(7px, 2.2vw, 9px)/1.05 ui-monospace, SFMono-Regular, monospace; letter-spacing: .01em; text-overflow: ellipsis; white-space: nowrap; }
        .white-key {
          background: linear-gradient(145deg, #fff, #e8e6e0);
          box-shadow: 6px 7px 12px #77736c99, -4px -4px 9px #fff, inset 1px 1px 1px #fff, inset -1px -2px 2px #aca8a0;
        }
        .white-key .glyph { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: clamp(19px, 5.5vw, 24px); font-weight: 540; }
        .key:active, .key.active {
          transform: translateY(4px) scale(.985);
          box-shadow: 1px 2px 4px #77736c88, inset 3px 3px 7px #8e8a825c, inset -1px -1px 3px #fff8;
        }
        #talk {
          min-height: 58px;
          color: #f7f5ef;
          border: 1px solid #35373b;
          background: linear-gradient(145deg, #2a2c30, #111215);
          box-shadow: 7px 8px 13px #77736c99, -4px -4px 9px #fff, inset 1px 1px 2px #ffffff30, inset -2px -2px 3px #000c;
        }
        #talk .key-label { color: #b9bcc2; }
        #talk.active { transform: translateY(4px) scale(.99); color: #fff; background: linear-gradient(145deg, #e34d42, #9f251f); box-shadow: 1px 2px 4px #77736c88, inset 3px 4px 8px #6e1614aa, inset -1px -1px 3px #ffb0a6; }
        #talk.active .key-label { color: #fff; }
        .mic-icon { width: 28px; height: 28px; }
        .backspace, .enter { min-height: 58px; }
        @media (max-width: 350px) {
          .faceplate { border-radius: 27px; }
          .deck { gap: 7px; }
          .key { min-height: 42px; border-radius: 13px; gap: 3px; }
          #talk, .backspace, .enter { min-height: 52px; }
        }
      </style>
    </head>
    <body>
      <main>
        <section class="faceplate" aria-label="Mac keyboard remote">
          <span id="status" role="status" title="Connecting…"></span>
          <div class="deck">
            <button class="key white-key backspace" data-hold-action="backspace" data-active-label="Deleting…" aria-label="Hold to delete"><span class="glyph">⌫</span><span class="key-label">Delete</span></button>
            <button class="key white-key" data-action="ctrlC" aria-label="Control C"><span class="glyph">ϟ</span><span class="key-label">Ctrl+C</span></button>
            <button class="key white-key enter" data-action="enter" aria-label="Enter"><span class="glyph">✓</span><span class="key-label">Enter</span></button>
            <button class="key" id="talk" data-hold-action="talk" data-active-label="Listening…" aria-label="Hold to talk"><svg class="mic-icon" aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0"/><line x1="12" y1="18" x2="12" y2="21"/><line x1="8" y1="21" x2="16" y2="21"/></svg><span class="key-label">Hold to Talk</span></button>
          </div>
        </section>
      </main>
      <script>
        (() => {
          const token = new URLSearchParams(location.search).get('token') || '';
          const status = document.getElementById('status');
          let socket = null;
          let reconnectTimer = null;
          const activeHolds = new Map();

          const send = payload => {
            if (!socket || socket.readyState !== WebSocket.OPEN) return false;
            socket.send(JSON.stringify(payload));
            return true;
          };

          const setStatus = (text, ready = false) => {
            status.title = text;
            status.classList.toggle('ready', ready);
          };

          const releaseHold = (button, notifyServer = true, pointerID = null) => {
            const hold = activeHolds.get(button);
            if (!hold || (pointerID !== null && hold.pointerID !== pointerID)) return;
            activeHolds.delete(button);
            clearInterval(hold.heartbeatTimer);
            button.classList.remove('active');
            hold.label.textContent = hold.idleLabel;
            if (notifyServer) send({ type: 'up', pressID: hold.pressID });
          };

          const releaseAllHolds = (notifyServer = true) => {
            Array.from(activeHolds.keys()).forEach(button => releaseHold(button, notifyServer));
          };

          const connect = () => {
            clearTimeout(reconnectTimer);
            setStatus('Connecting…');
            socket = new WebSocket(`ws://${location.hostname}:8766/`);
            socket.addEventListener('open', () => send({ type: 'auth', token }));
            socket.addEventListener('message', event => {
              let message;
              try { message = JSON.parse(event.data); } catch { return; }
              if (message.type === 'ready') setStatus('Connected', true);
              if (message.type === 'error') setStatus(message.message || 'Action rejected');
            });
            socket.addEventListener('close', () => {
              releaseAllHolds(false);
              setStatus('Reconnecting…');
              reconnectTimer = setTimeout(connect, 1000);
            });
            socket.addEventListener('error', () => socket.close());
          };

          document.querySelectorAll('button[data-action]').forEach(button => {
            button.addEventListener('pointerdown', event => {
              event.preventDefault();
              button.setPointerCapture?.(event.pointerId);
              send({ type: 'tap', actionID: button.dataset.action });
              navigator.vibrate?.(12);
            });
          });

          document.querySelectorAll('button[data-hold-action]').forEach(button => {
            const label = button.querySelector('.key-label');
            const idleLabel = label.textContent;

            button.addEventListener('pointerdown', event => {
              event.preventDefault();
              if (activeHolds.has(button) || !socket || socket.readyState !== WebSocket.OPEN) return;
              button.setPointerCapture?.(event.pointerId);
              const pressID = crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
              const heartbeatTimer = setInterval(() => {
                const hold = activeHolds.get(button);
                if (hold) send({ type: 'heartbeat', pressID: hold.pressID });
              }, 400);
              activeHolds.set(button, { pressID, heartbeatTimer, pointerID: event.pointerId, label, idleLabel });
              button.classList.add('active');
              label.textContent = button.dataset.activeLabel;
              send({ type: 'down', actionID: button.dataset.holdAction, pressID });
              navigator.vibrate?.(20);
            });
            button.addEventListener('pointerup', event => releaseHold(button, true, event.pointerId));
            button.addEventListener('pointercancel', event => releaseHold(button, true, event.pointerId));
            button.addEventListener('lostpointercapture', event => releaseHold(button, true, event.pointerId));
            button.addEventListener('touchcancel', event => { event.preventDefault(); releaseHold(button); }, { passive: false });
          });

          document.addEventListener('visibilitychange', () => {
            if (document.hidden) releaseAllHolds();
          });
          window.addEventListener('pagehide', () => {
            releaseAllHolds();
            socket?.close();
          });
          connect();
        })();
      </script>
    </body>
    </html>
    """#
}
