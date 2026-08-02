import CoreAudio
import Foundation

/// A selectable microphone (CoreAudio input device).
public struct AudioInputDevice: Equatable {
    public let id: AudioDeviceID
    public let uid: String   // stable across relaunches; what we persist
    public let name: String
}

/// Thin CoreAudio wrapper to list input devices and resolve a saved device by
/// its stable UID. Used so the user can pick which microphone Wordly records
/// from, instead of always the system default.
public enum AudioDevices {
    public static func inputs() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInputChannels(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName),
                  !isPrivateAggregate(id),
                  // ponytail: belt and braces. The composition check above is the
                  // principled one, but these devices only exist while an engine
                  // is running, so it could not be observed firing — and a junk
                  // entry in the picker is worse than a redundant condition.
                  !name.hasPrefix("CADefaultDeviceAggregate")
            else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    /// CoreAudio quietly creates a hidden aggregate device wrapping the current
    /// default input, on behalf of whichever process is recording — ours
    /// included. It shows up in the device list as
    /// `CADefaultDeviceAggregate-<pid>-<n>`, which is nobody's microphone and
    /// gets a different name on every launch, so a saved choice would go stale.
    /// Aggregates the user built themselves in Audio MIDI Setup are not private
    /// and stay listed.
    private static func isPrivateAggregate(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        var value: CFDictionary?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr,  // not an aggregate at all
              let composition = value as? [String: Any] else { return false }
        return composition[kAudioAggregateDeviceIsPrivateKey as String] as? Bool == true
            || composition[kAudioAggregateDeviceIsPrivateKey as String] as? Int == 1
    }

    /// Resolve a persisted UID to its current device ID (devices come and go).
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputs().first { $0.uid == uid }?.id
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
