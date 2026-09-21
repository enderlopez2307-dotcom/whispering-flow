import AVFoundation
import CoreAudio
import Foundation

/// Input devices, by the same UID the preferences already persist.
///
/// `AVCaptureDevice.uniqueID` for an audio device *is* its CoreAudio UID string,
/// so enumeration can use the friendlier AVFoundation API while device
/// selection still goes through CoreAudio, which is the only thing
/// `AVAudioEngine`'s input unit understands.
enum AudioDeviceRegistry {

    struct Device: Sendable, Equatable, Identifiable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    static func availableInputs() -> [Device] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified)
        return session.devices.map { Device(uid: $0.uniqueID, name: $0.localizedName) }
    }

    static func name(forUID uid: String) -> String? {
        availableInputs().first { $0.uid == uid }?.name
    }

    /// The system default input, or nil if the machine has no microphone at all.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Resolve a stored UID to a live device. Returns nil when the device has
    /// been unplugged, which is the case the caller has to fall back from.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &deviceID)
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func hasAnyInput() -> Bool { !availableInputs().isEmpty }
}
