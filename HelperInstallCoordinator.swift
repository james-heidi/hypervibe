//
//  HelperInstallCoordinator.swift
//  HyperVibe
//
//  Non-blocking state machine for the one-shot privileged HCI helper install.
//  All osascript / socket / launchctl work runs off the main thread so the menu
//  bar and onboarding window stay responsive while the admin dialog is up.
//

import Foundation

enum HelperReadiness: Equatable {
    case unknown
    case notInstalled
    case ready
    case outdated(installed: Int, expected: Int)
    /// Binary is on disk but the daemon answers nothing — happens while launchd
    /// restarts it right after an install, and if the daemon later dies.
    case unresponsive

    /// An outdated daemon still answers PING/START, so capture keeps working while
    /// the 安装 menu offers the upgrade. Only `.ready` means "nothing to do".
    var isUsableForCapture: Bool {
        switch self {
        case .ready, .outdated:
            return true
        case .unknown, .notInstalled, .unresponsive:
            return false
        }
    }

    /// True once the daemon has answered — the only proof an install worked.
    var isResponding: Bool {
        switch self {
        case .ready, .outdated:
            return true
        case .unknown, .notInstalled, .unresponsive:
            return false
        }
    }
}

enum HelperInstallFailure: Error, Equatable {
    case userCancelled
    case authorizationFailed(String)
    case bundledHelperMissing
    case scriptFailed(exitCode: Int32, stderrSnippet: String)
    case verificationTimedOut
    case timedOut

    var userMessage: String {
        switch self {
        case .userCancelled:
            return "已取消"
        case .authorizationFailed(let detail):
            return detail.isEmpty ? "管理员授权失败" : detail
        case .bundledHelperMissing:
            return "当前 HyperVibe.app 未包含麦克风组件"
        case .scriptFailed(_, let stderr):
            return stderr.isEmpty ? "安装脚本失败" : String(stderr.prefix(240))
        case .verificationTimedOut:
            return "已安装但服务尚未就绪"
        case .timedOut:
            return "等待管理员授权超时"
        }
    }
}

enum HelperInstallState: Equatable {
    case idle(HelperReadiness)
    case probing
    case awaitingAuthorization
    case installing
    case verifying(attempt: Int, total: Int)
    case failed(HelperInstallFailure)

    var isBusy: Bool {
        switch self {
        case .probing, .awaitingAuthorization, .installing, .verifying:
            return true
        case .idle, .failed:
            return false
        }
    }
}

final class HelperInstallCoordinator {
    static let shared = HelperInstallCoordinator()

    private let workQueue = DispatchQueue(label: "com.hypervibe.helper-install", qos: .userInitiated)
    private let stateLock = NSLock()
    private var _state: HelperInstallState = .idle(.unknown)
    private var _readiness: HelperReadiness = .unknown
    private var installGeneration = UUID()

    /// Fired on the main queue whenever `state` changes.
    private var changeHandlers: [String: () -> Void] = [:]

    func addOnChange(id: String, _ handler: @escaping () -> Void) {
        changeHandlers[id] = handler
    }

    var state: HelperInstallState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    /// Snapshot for menu/onboarding — never performs socket I/O.
    var readiness: HelperReadiness {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _readiness
    }

    var isReady: Bool {
        if case .ready = readiness { return true }
        return false
    }

    private init() {}

    /// Fire-and-forget readiness refresh. Safe to call from main.
    func refresh(reason: String = "manual") {
        workQueue.async { [weak self] in
            self?.probeLocked(reason: reason)
        }
    }

    /// Begin install. Re-entrant calls while busy are ignored.
    func install() {
        workQueue.async { [weak self] in
            guard let self else { return }
            if self.state.isBusy { return }
            self.installGeneration = UUID()
            let opID = self.installGeneration
            self.publish(.awaitingAuthorization)

            guard let helper = HCIHelperPaths.bundledHelperURL() else {
                self.publish(.failed(.bundledHelperMissing))
                return
            }

            let result = self.runAdminInstall(helperURL: helper, opID: opID)
            guard self.installGeneration == opID else { return }

            switch result {
            case .success:
                self.publish(.installing)
                self.verifyAfterInstall(opID: opID)
            case .failure(let failure):
                if case .userCancelled = failure {
                    self.probeLocked(reason: "cancelled")
                } else {
                    self.publish(.failed(failure))
                }
            }
        }
    }

    func uninstall() {
        workQueue.async { [weak self] in
            guard let self else { return }
            if self.state.isBusy { return }
            self.installGeneration = UUID()
            let opID = self.installGeneration
            self.publish(.awaitingAuthorization)
            let result = self.runAdminUninstall(opID: opID)
            guard self.installGeneration == opID else { return }
            switch result {
            case .success:
                HCIHelperClient.invalidateReadyCache()
                self.probeLocked(reason: "uninstall")
            case .failure(let failure):
                if case .userCancelled = failure {
                    self.probeLocked(reason: "uninstall-cancelled")
                } else {
                    self.publish(.failed(failure))
                }
            }
        }
    }

    // MARK: - Probe

    private func probeLocked(reason: String) {
        let previous = readiness
        let busy = state.isBusy
        let next = Self.computeReadiness()
        HCIHelperClient.setCachedReady(next.isUsableForCapture)
        // Skip no-op probes so menu/onboarding refreshes cannot fan out forever.
        if !busy, previous == next, previous != .unknown {
            return
        }
        publish(.idle(next), readiness: next)
        rmDebug("🎤 helper readiness=\(String(describing: next)) reason=\(reason)")
    }

    static func computeReadiness(probeTimeout: TimeInterval = 1.0) -> HelperReadiness {
        guard HCIHelperPaths.isInstalled else { return .notInstalled }
        do {
            let response = try HCIHelperClient.send(.version, timeout: probeTimeout)
            if case .version(let installed) = response {
                let expected = HCIHelperCodec.currentHelperVersion
                if installed < expected {
                    return .outdated(installed: installed, expected: expected)
                }
                return .ready
            }
            // Unexpected success payload — still try PING before giving up.
            if HCIHelperClient.ping(timeout: probeTimeout) { return .ready }
        } catch {
            // Pre-VERSION helpers throw on VERSION (ERR|bad request) but still PING.
            if HCIHelperClient.ping(timeout: probeTimeout) {
                return .outdated(installed: 0, expected: HCIHelperCodec.currentHelperVersion)
            }
        }
        // Installed but silent. Must not be reported as `.outdated`: a fresh install
        // probed during the launchd restart window would then look like it failed.
        return .unresponsive
    }

    // MARK: - Verify

    /// Only a *responding* daemon proves the install worked.
    ///
    /// Probe immediately, then poll densely with short socket timeouts so a dead
    /// socket during launchd restart does not burn ~2s per attempt. Sleep budget
    /// stays ~7s (enough for slow kickstart); typical success lands in 1–2s.
    private func verifyAfterInstall(opID: UUID) {
        let delays: [TimeInterval] = [
            0, 0.12, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.75, 1.0, 1.5, 2.0,
        ]
        let probeTimeout: TimeInterval = 0.2
        let total = delays.count
        HCIHelperClient.invalidateReadyCache()
        for (index, delay) in delays.enumerated() {
            guard installGeneration == opID else { return }
            publish(.verifying(attempt: index + 1, total: total))
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
            let readiness = Self.computeReadiness(probeTimeout: probeTimeout)
            if readiness.isResponding {
                HCIHelperClient.setCachedReady(readiness.isUsableForCapture)
                publish(.idle(readiness), readiness: readiness)
                rmDebug("🎤 helper install verified readiness=\(String(describing: readiness))")
                return
            }
        }
        guard installGeneration == opID else { return }
        rmDebug("🎤 helper install verification timed out")
        publish(.failed(.verificationTimedOut))
    }

    // MARK: - Admin scripts

    private func runAdminInstall(helperURL: URL, opID: UUID) -> Result<Void, HelperInstallFailure> {
        let script = HCIHelperInstall.makeInstallScript(helperSourcePath: helperURL.path)
        return runAdminShell(script, opID: opID, wallClock: 180)
    }

    private func runAdminUninstall(opID: UUID) -> Result<Void, HelperInstallFailure> {
        let script = HCIHelperInstall.makeUninstallScript()
        return runAdminShell(script, opID: opID, wallClock: 120)
    }

    private func runAdminShell(
        _ script: String,
        opID: UUID,
        wallClock: TimeInterval
    ) -> Result<Void, HelperInstallFailure> {
        guard let scriptData = script.data(using: .utf8) else {
            return .failure(.scriptFailed(exitCode: -1, stderrSnippet: "encode failed"))
        }
        let b64 = scriptData.base64EncodedString()
        let command = "echo \(ShellQuote.single(b64)) | /usr/bin/base64 -D | /bin/sh"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        let proc = Process()
        let errPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScript]
        proc.standardOutput = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return .failure(.authorizationFailed(error.localizedDescription))
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            proc.waitUntilExit()
            group.leave()
        }
        let waitResult = group.wait(timeout: .now() + wallClock)
        if waitResult == .timedOut {
            proc.terminate()
            return .failure(.timedOut)
        }
        guard installGeneration == opID else {
            return .failure(.userCancelled)
        }

        let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            if errText.localizedCaseInsensitiveContains("User canceled")
                || errText.localizedCaseInsensitiveContains("User cancelled") {
                return .failure(.userCancelled)
            }
            return .failure(.scriptFailed(
                exitCode: proc.terminationStatus,
                stderrSnippet: errText
            ))
        }
        return .success(())
    }

    // MARK: - Publish

    private func publish(_ state: HelperInstallState, readiness: HelperReadiness? = nil) {
        stateLock.lock()
        _state = state
        if let readiness {
            _readiness = readiness
        } else if case .idle(let value) = state {
            _readiness = value
        }
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for handler in self.changeHandlers.values {
                handler()
            }
        }
    }
}
