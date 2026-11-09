import Foundation

/// A press of one of the keyboard's special keys, read from the system event that carries it.
///
/// Volume, brightness and the media keys do not arrive as key presses. They come as a
/// "system defined" event of subtype 8, with the key and its state packed into one number:
/// the key in the high 16 bits, and in the low ones 0x0A for down, 0x0B for up, and a low
/// bit set while the key repeats.
public struct MediaKeyPress: Equatable, Sendable {
    public enum Key: Int, Sendable, CaseIterable {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
        case play = 16
        case next = 17
        case previous = 18
        case illuminationUp = 21
        case illuminationDown = 22
    }

    public let key: Key
    public let isDown: Bool
    public let isRepeat: Bool

    public static let subtype = 8

    /// The press in an event's first data field, or nil for a key this does not know.
    public init?(subtype: Int, data1: Int) {
        guard subtype == Self.subtype else { return nil }
        let code = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8
        guard let key = Key(rawValue: code), state == 0x0A || state == 0x0B else { return nil }
        self.key = key
        isDown = state == 0x0A
        isRepeat = flags & 0x1 == 1
    }

    public var isVolume: Bool { key == .soundUp || key == .soundDown || key == .mute }
    public var isBrightness: Bool { key == .brightnessUp || key == .brightnessDown }
}
