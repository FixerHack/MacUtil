import AudioToolbox
import CoreAudio
import CoreGraphics
import Foundation

/// The volume of the output macOS is sending sound to, through Core Audio.
public enum SystemVolume {
    /// One press of a volume key, as macOS itself steps it.
    public static let step: Float = 1.0 / 16

    static func defaultOutput() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// From 0 to 1, or nil for an output whose volume cannot be set from here (most HDMI
    /// and DisplayPort speakers, which keep their own).
    public static func volume() -> Float? {
        guard let device = defaultOutput() else { return nil }
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    public static func setVolume(_ value: Float) -> Bool {
        guard let device = defaultOutput() else { return false }
        var address = volumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var clamped = Float32(min(1, max(0, value)))
        let size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectSetPropertyData(device, &address, 0, nil, size, &clamped) == noErr else { return false }
        // Turning it up takes the mute off, as the keys do.
        if clamped > 0, isMuted() { setMuted(false) }
        return true
    }

    public static func isMuted() -> Bool {
        guard let device = defaultOutput() else { return false }
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    @discardableResult
    public static func setMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutput() else { return false }
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// The next level for a key press, kept to whole steps the way macOS does.
    public static func stepped(_ value: Float, up: Bool) -> Float {
        let steps = (value / step).rounded() + (up ? 1 : -1)
        return min(1, max(0, steps * step))
    }
}

/// The brightness of the Mac's own screen.
///
/// There is no public way to set it. macOS's own DisplayServices does it, and is looked up
/// by name at run time: if a future macOS renames it, this simply reports that it cannot,
/// and the brightness keys are left to macOS, indicator and all.
public enum DisplayBrightness {
    private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32

    // A handle that is only ever read; dlopen returns the same one to every caller.
    private nonisolated(unsafe) static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    private static var getter: Getter? {
        guard let library, let symbol = dlsym(library, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: Getter.self)
    }

    private static var setter: Setter? {
        guard let library, let symbol = dlsym(library, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: Setter.self)
    }

    /// The built-in screen, which is the one the brightness keys belong to.
    static var builtIn: CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &displays, &count)
        return displays.first { CGDisplayIsBuiltin($0) != 0 }
    }

    public static func brightness() -> Float? {
        guard let getter, let display = builtIn else { return nil }
        var value: Float = 0
        return getter(display, &value) == 0 ? value : nil
    }

    @discardableResult
    public static func setBrightness(_ value: Float) -> Bool {
        guard let setter, let display = builtIn else { return false }
        return setter(display, min(1, max(0, value))) == 0
    }
}
