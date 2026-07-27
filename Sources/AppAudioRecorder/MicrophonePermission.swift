import AVFoundation

/// 麦克风权限查询与申请。
enum MicrophonePermission {
    /// 确保已获得麦克风权限；未决定时触发系统弹窗申请。被拒绝或受限则抛出。
    static func ensureAuthorized() async throws(RecorderError) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            // 桥接 completion handler 式旧 API 为 async。
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            guard granted else { throw .microphonePermissionDenied }
        case .denied, .restricted:
            throw .microphonePermissionDenied
        @unknown default:
            throw .microphonePermissionDenied
        }
    }
}
