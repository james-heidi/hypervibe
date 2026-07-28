//
//  RemoteMicLab.swift
//  HyperVibe
//
//  Minimal readiness for the internal bundled PacketLogger + one-shot HCI helper.
//

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
            hciHelper: HelperInstallCoordinator.shared.readiness.isUsableForCapture
                || HCIHelperClient.isReadyCached(),
            remoteAddress: MicCapturePipeline.detectRemoteAddress()
        )
    }
}
