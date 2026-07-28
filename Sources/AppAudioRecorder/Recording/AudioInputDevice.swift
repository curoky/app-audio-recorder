import AVFoundation

/// 一个可选作录音输入源的麦克风设备。
///
/// `id` 采用 `AVCaptureDevice.uniqueID`，与 `SCStreamConfiguration.microphoneCaptureDeviceID`
/// 期望的 CoreAudio 设备 UID 一致，可直接透传给 ScreenCaptureKit。
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

enum AudioInputDevices {
    /// 当前系统可用的音频输入设备。默认（不指定设备）由系统自动选择，
    /// 此列表只在用户想主动介入、锁定某个具体设备时使用。
    static func available() -> [AudioInputDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map {
            AudioInputDevice(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    /// 系统当前默认的音频输入设备；跟随系统默认录音时实际使用的就是它。
    /// 仅用于界面展示，nil 表示系统当前没有可用输入设备。
    static func systemDefault() -> AudioInputDevice? {
        AVCaptureDevice.default(for: .audio).map {
            AudioInputDevice(id: $0.uniqueID, name: $0.localizedName)
        }
    }
}
