import Foundation

// MARK: - RelayBrowserHandler

/// 浏览器操作处理器：截图等功能
struct RelayBrowserHandler {

    // MARK: - 属性

    /// 关联的 RelayBridge，用于发送 V1 命令到本地 socket
    let bridge: RelayBridge

    // MARK: - 公开接口

    /// 对指定 surface 执行截图
    /// - Parameter surfaceID: 终端 surface 标识
    /// - Returns: 包含截图结果的字典；成功时含 base64 图像数据，失败时含 error 字段
    func captureScreenshot(surfaceID: String) -> [String: Any] {
        let command = "screenshot \(surfaceID)"
        guard let response = bridge.sendV1Command(command) else {
            return [
                "success": false,
                "error": "无法连接到本地 socket",
            ]
        }

        // 响应格式：`OK {base64}` 或 `ERROR {message}`
        if response.hasPrefix("OK ") {
            let base64 = String(response.dropFirst(3))
                .trimmingCharacters(in: .whitespaces)
            if base64.isEmpty {
                return [
                    "success": false,
                    "error": "截图数据为空",
                ]
            }
            return [
                "success": true,
                "surfaceID": surfaceID,
                "encoding": "base64",
                "mimeType": "image/png",
                "data": base64,
            ]
        }

        // 提取错误信息
        let errorMessage: String
        if response.hasPrefix("ERROR ") {
            errorMessage = String(response.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else {
            errorMessage = response
        }

        return [
            "success": false,
            "error": errorMessage,
        ]
    }
}
