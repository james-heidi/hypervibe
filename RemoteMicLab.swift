//
//  RemoteMicLab.swift
//  HyperVibe
//
//  Minimal readiness for the internal bundled PacketLogger + one-shot HCI helper.
//

import AppKit
import Foundation

struct RemoteMicReadiness {
    var packetLogger: Bool
    var hciHelper: Bool
    var remoteAddress: String?

    var isReady: Bool {
        packetLogger && hciHelper && remoteAddress != nil
    }

    var checklistText: String {
        func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        return [
            "\(mark(packetLogger)) 内置 PacketLogger",
            "\(mark(hciHelper)) 麦克风组件（一次性管理员安装）",
            "\(mark(remoteAddress != nil)) Siri Remote 已配对\(remoteAddress.map { " (\($0))" } ?? "")",
            "OpenAI 需 API Key；Parakeet 在菜单选择时下载模型",
        ].joined(separator: "\n")
    }
}

enum RemoteMicLab {
    static let enabledDefaultsKey = "remoteMicEnabled"

    static func evaluate() -> RemoteMicReadiness {
        RemoteMicReadiness(
            packetLogger: MicCapturePipeline.packetLoggerURL() != nil,
            hciHelper: HCIHelperClient.isReady(),
            remoteAddress: MicCapturePipeline.detectRemoteAddress()
        )
    }

    /// Installs the LaunchDaemon helper with one admin prompt if missing.
    @discardableResult
    static func ensureHelperInstalled(presentUI: Bool = true) -> Bool {
        if HCIHelperClient.isReady() { return true }
        guard let helper = HCIHelperPaths.bundledHelperURL() else {
            if presentUI {
                let alert = NSAlert.hyperVibeAlert()
                alert.messageText = "缺少麦克风组件"
                alert.informativeText = "当前 HyperVibe.app 未包含 com.hypervibe.hcihelper。请重新运行 ./build.sh && ./create_app_bundle.sh。"
                alert.runHyperVibeModal()
            }
            return false
        }
        if presentUI {
            let alert = NSAlert.hyperVibeAlert()
            alert.messageText = "安装遥控器麦克风组件"
            alert.informativeText = """
            需要一次性管理员授权，安装后台麦克风服务。

            之后按 Siri 听写不再弹出密码框。
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "安装…")
            alert.addButton(withTitle: "取消")
            guard alert.runHyperVibeModal() == .alertFirstButtonReturn else { return false }
        }
        return HCIHelperClient.installWithAdminPrompt(bundledHelperURL: helper)
    }

}
