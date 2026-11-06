import Carbon.HIToolbox
import Foundation

/// The characters the user's own keyboard layout produces for a key with
/// modifiers held, for synthetic key presses: Option+2 types "™" on a US
/// keyboard, not "2", and a page testing that its shortcuts stay out of the
/// way while the user types needs to see the same character a real press
/// would deliver. Both engines' automation use this, so a chord means the
/// same thing on each.
enum MacKeyboardLayout {
    /// Mac virtual key codes for the characters of a US layout. A character
    /// with no key of its own gets `nil`, and is sent with its characters
    /// alone, which is what an input method does.
    private static let virtualKeyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50, " ": 49,
    ]

    static func virtualKeyCode(for character: Character) -> UInt16? {
        virtualKeyCodes[Character(character.lowercased())]
    }

    /// What the current keyboard layout types for `keyCode` with these
    /// modifiers held; nil when the layout has nothing for it (a dead key,
    /// or no layout data), in which case the caller keeps the plain
    /// character.
    static func characters(keyCode: UInt16, shift: Bool, option: Bool) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var modifierKeyState: UInt32 = 0
        if shift { modifierKeyState |= UInt32(shiftKey >> 8) }
        if option { modifierKeyState |= UInt32(optionKey >> 8) }
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = layoutData.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), modifierKeyState, UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        // A control character means the layout has no printable result.
        guard text.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return nil }
        return text
    }

    /// The text a press of `character` with these modifiers types, in the
    /// current layout: the plain character when no modifier changes it.
    static func typedText(for character: Character, shift: Bool, option: Bool) -> String {
        guard shift || option, let keyCode = virtualKeyCode(for: character),
              let translated = characters(keyCode: keyCode, shift: shift, option: option) else { return String(character) }
        return translated
    }
}
