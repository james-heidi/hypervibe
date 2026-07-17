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
    private static let maximumMessageSize = 4_096
    private static let webSourcePrefix = "web:"

    private weak var inputHandler: RemoteInputHandler?
    private let actionResolver: (String) -> ButtonAction?
    private let queue = DispatchQueue(label: "com.hypervibe.remote-web-server")
    private let token: String

    private var desiredEnabled: Bool
    private var httpListener: NWListener?
    private var webSocketListener: NWListener?
    private var httpReady = false
    private var webSocketReady = false
    private var localAddress: String?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var watchdog: DispatchSourceTimer?
    private var sleepObserver: NSObjectProtocol?

    var onStatusChange: ((Status) -> Void)?

    init(inputHandler: RemoteInputHandler, actionResolver: @escaping (String) -> ButtonAction?) {
        self.inputHandler = inputHandler
        self.actionResolver = actionResolver

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
    }

    deinit {
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
            guard let actionID = message["actionID"] as? String,
                  let action = resolveAction(actionID),
                  !action.requiresHold else {
                sendError("Unknown tap action", to: client.connection)
                return
            }
            let sourceID = "\(client.sourcePrefix)tap:\(UUID().uuidString)"
            performInput { input in
                input.handleExternalAction(action, sourceID: sourceID, pressed: true)
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
        :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif; }
        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        html, body { margin: 0; min-height: 100%; background: #090b10; color: #f3f5fa; overscroll-behavior: none; }
        body { min-height: 100dvh; padding: max(18px, env(safe-area-inset-top)) 18px max(20px, env(safe-area-inset-bottom)); display: flex; }
        main { width: min(100%, 520px); margin: auto; }
        header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 18px; }
        h1 { margin: 0; font-size: 22px; letter-spacing: -0.02em; }
        #status { font-size: 13px; color: #ffb35c; }
        #status.ready { color: #64d68a; }
        .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }
        button { appearance: none; border: 1px solid #2d3340; background: linear-gradient(180deg, #20242d, #15181f); color: #f5f7fb; min-height: 78px; border-radius: 18px; font: 650 18px/1 -apple-system, BlinkMacSystemFont, sans-serif; box-shadow: 0 8px 22px #0007, inset 0 1px #ffffff0d; touch-action: none; user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; }
        button:active, button.active { transform: scale(.97); background: #292f3b; border-color: #515c70; }
        .danger { color: #ff938d; }
        #talk { grid-column: 1 / -1; min-height: 132px; margin-top: 4px; border-color: #35604a; background: linear-gradient(180deg, #183b2a, #10271d); color: #8ff0b4; font-size: 22px; }
        #talk.active { background: #8b2534; border-color: #f06f7d; color: white; box-shadow: 0 0 0 5px #e24b6426, 0 10px 28px #0008; }
        .hint { margin: 15px 4px 0; text-align: center; color: #7f8796; font-size: 12px; }
      </style>
    </head>
    <body>
      <main>
        <header><h1>HyperVibe</h1><span id="status">Connecting…</span></header>
        <section class="grid" aria-label="Mac keyboard remote">
          <button data-action="esc">Esc</button>
          <button data-action="up" aria-label="Up arrow">↑</button>
          <button data-action="enter">Enter</button>
          <button data-action="left" aria-label="Left arrow">←</button>
          <button data-action="down" aria-label="Down arrow">↓</button>
          <button data-action="right" aria-label="Right arrow">→</button>
          <button class="danger" data-action="ctrlC">Ctrl C</button>
          <button id="talk">Hold to Talk</button>
        </section>
        <p class="hint">Keep this page open while using push-to-talk.</p>
      </main>
      <script>
        (() => {
          const token = new URLSearchParams(location.search).get('token') || '';
          const status = document.getElementById('status');
          const talk = document.getElementById('talk');
          let socket = null;
          let reconnectTimer = null;
          let activePressID = null;
          let heartbeatTimer = null;

          const send = payload => {
            if (!socket || socket.readyState !== WebSocket.OPEN) return false;
            socket.send(JSON.stringify(payload));
            return true;
          };

          const setStatus = (text, ready = false) => {
            status.textContent = text;
            status.classList.toggle('ready', ready);
          };

          const releaseTalk = (notifyServer = true) => {
            if (!activePressID) return;
            const pressID = activePressID;
            activePressID = null;
            clearInterval(heartbeatTimer);
            heartbeatTimer = null;
            talk.classList.remove('active');
            talk.textContent = 'Hold to Talk';
            if (notifyServer) send({ type: 'up', pressID });
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
              releaseTalk(false);
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

          talk.addEventListener('pointerdown', event => {
            event.preventDefault();
            if (activePressID || !socket || socket.readyState !== WebSocket.OPEN) return;
            talk.setPointerCapture?.(event.pointerId);
            activePressID = crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
            talk.classList.add('active');
            talk.textContent = 'Talking…';
            send({ type: 'down', actionID: 'talk', pressID: activePressID });
            heartbeatTimer = setInterval(() => {
              if (activePressID) send({ type: 'heartbeat', pressID: activePressID });
            }, 400);
            navigator.vibrate?.(20);
          });
          talk.addEventListener('pointerup', () => releaseTalk());
          talk.addEventListener('pointercancel', () => releaseTalk());
          talk.addEventListener('lostpointercapture', () => releaseTalk());
          talk.addEventListener('touchcancel', event => { event.preventDefault(); releaseTalk(); }, { passive: false });

          document.addEventListener('visibilitychange', () => {
            if (document.hidden) releaseTalk();
          });
          window.addEventListener('pagehide', () => {
            releaseTalk();
            socket?.close();
          });
          connect();
        })();
      </script>
    </body>
    </html>
    """#
}
