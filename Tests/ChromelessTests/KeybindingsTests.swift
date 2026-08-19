import AppKit
import Foundation
import Testing
@testable import ChromelessCore

@Suite("Keybindings — encode/decode, conflicts, display, persistence")
struct KeybindingsTests {

    private let cmd: NSEvent.ModifierFlags = [.command]
    private let cmdShift: NSEvent.ModifierFlags = [.command, .shift]

    // MARK: Encode / decode

    @Test("encode produces readable token strings")
    func encode() {
        #expect(Keybindings.encode(Shortcut(key: "t", mods: cmd)) == "cmd+t")
        #expect(Keybindings.encode(Shortcut(key: "t", mods: cmdShift)) == "cmd+shift+t")
        #expect(Keybindings.encode(Shortcut(key: "k", mods: [.control, .option])) == "ctrl+alt+k")
    }

    @Test("decode is the inverse of encode")
    func roundTrip() {
        for sc in [Shortcut(key: "t", mods: cmd),
                   Shortcut(key: "l", mods: cmdShift),
                   Shortcut(key: ",", mods: cmd),
                   Shortcut(key: " ", mods: [.command, .control])] {
            #expect(Keybindings.decode(Keybindings.encode(sc)) == sc)
        }
    }

    @Test("decode rejects garbage and the legacy bitmask format")
    func decodeRejects() {
        #expect(Keybindings.decode("") == nil)
        #expect(Keybindings.decode("cmd+") == nil)          // missing key
        #expect(Keybindings.decode("hyper+t") == nil)       // unknown modifier token
        #expect(Keybindings.decode("1179648|t") == nil)     // pre-token bitmask format
    }

    // MARK: Canonical form

    @Test("canonical folds case and ignores irrelevant modifier bits")
    func canonical() {
        let a = Shortcut(key: "T", mods: [.command, .shift, .capsLock, .function])
        let b = Shortcut(key: "t", mods: cmdShift)
        #expect(a.canonical == b.canonical)
    }

    // MARK: Registry integrity

    @Test("Every command id is unique and has a non-empty default")
    func registryIntegrity() {
        let kb = withDefaults { Keybindings(defaults: $0) }
        let ids = kb.commands.map(\.id)
        #expect(Set(ids).count == ids.count)
        for c in kb.commands {
            #expect(!c.def.key.isEmpty)
            #expect(!c.title.isEmpty)
            #expect(!c.group.isEmpty)
        }
    }

    @Test("No two default bindings collide")
    func defaultsDoNotCollide() {
        let kb = withDefaults { Keybindings(defaults: $0) }
        var seen: [String: String] = [:]
        for c in kb.commands {
            let key = c.def.canonical
            #expect(seen[key] == nil, "\(c.id) collides with \(seen[key] ?? "?") on \(key)")
            seen[key] = c.id
        }
    }

    // MARK: Lookup / mutation

    @Test("current falls back to the default when no override exists")
    func currentDefault() {
        let kb = withDefaults { Keybindings(defaults: $0) }
        #expect(kb.current("newTab") == Shortcut(key: "t", mods: cmd))
        #expect(!kb.isCustomized("newTab"))
    }

    @Test("set stores an override and persists it to the defaults domain")
    func setPersists() {
        withDefaults { defaults in
            let kb = Keybindings(defaults: defaults)
            #expect(kb.set("newTab", Shortcut(key: "k", mods: cmd)))
            #expect(kb.current("newTab") == Shortcut(key: "k", mods: cmd))
            #expect(kb.isCustomized("newTab"))

            // A fresh instance reading the same domain sees the override.
            let reloaded = Keybindings(defaults: defaults)
            #expect(reloaded.current("newTab") == Shortcut(key: "k", mods: cmd))
        }
    }

    @Test("Setting a combo back to the default drops the override")
    func setBackToDefaultClearsOverride() {
        withDefaults { defaults in
            let kb = Keybindings(defaults: defaults)
            kb.set("newTab", Shortcut(key: "k", mods: cmd))
            #expect(kb.set("newTab", Shortcut(key: "t", mods: cmd))) // the factory default
            #expect(!kb.isCustomized("newTab"))
        }
    }

    @Test("set rejects conflicts with other commands")
    func setRejectsConflict() {
        withDefaults { defaults in
            let kb = Keybindings(defaults: defaults)
            // ⌘W is closeTab's default; binding newTab onto it must fail.
            #expect(!kb.set("newTab", Shortcut(key: "w", mods: cmd)))
            #expect(kb.current("newTab") == Shortcut(key: "t", mods: cmd)) // unchanged
            #expect(kb.conflict(for: "newTab", Shortcut(key: "w", mods: cmd)) == "closeTab")
        }
    }

    @Test("set rejects unknown ids and empty keys")
    func setRejectsInvalid() {
        withDefaults { defaults in
            let kb = Keybindings(defaults: defaults)
            #expect(!kb.set("noSuchCommand", Shortcut(key: "k", mods: cmd)))
            #expect(!kb.set("newTab", Shortcut(key: "", mods: cmd)))
        }
    }

    @Test("reset and resetAll restore defaults")
    func reset() {
        withDefaults { defaults in
            let kb = Keybindings(defaults: defaults)
            kb.set("newTab", Shortcut(key: "k", mods: cmd))
            kb.set("reload", Shortcut(key: "u", mods: cmd))
            kb.reset("newTab")
            #expect(kb.current("newTab") == Shortcut(key: "t", mods: cmd))
            #expect(kb.isCustomized("reload"))
            kb.resetAll()
            #expect(!kb.isCustomized("reload"))
        }
    }

    // MARK: Reserved / OS-claimed

    @Test("Standard edit-menu combos are reserved")
    func reserved() {
        let kb = withDefaults { Keybindings(defaults: $0) }
        #expect(kb.reservedReason(Shortcut(key: "z", mods: cmd)) == "Undo")
        #expect(kb.reservedReason(Shortcut(key: "c", mods: cmd)) == "Copy")
        #expect(kb.reservedReason(Shortcut(key: "1", mods: cmd)) == "Switch to tab 1")
        #expect(kb.reservedReason(Shortcut(key: "9", mods: cmd)) == "Switch to tab 9")
        #expect(kb.reservedReason(Shortcut(key: "t", mods: cmd)) == nil)
    }

    @Test("Overrides that shadow reserved combos are dropped on load")
    func loadDropsReservedOverrides() {
        withDefaults { defaults in
            // Simulate a hand-edited defaults file binding ⌘C to reload.
            defaults.set(["reload": "cmd+c"], forKey: "CustomShortcuts")
            let kb = Keybindings(defaults: defaults)
            #expect(kb.current("reload") == Shortcut(key: "r", mods: cmd)) // fell back
        }
    }

    @Test("OS-claimed combos produce a warning, not a block")
    func osClaimed() {
        let kb = withDefaults { Keybindings(defaults: $0) }
        #expect(kb.osWarning(Shortcut(key: " ", mods: cmd)) == "Spotlight")
        #expect(kb.osWarning(Shortcut(key: "4", mods: cmdShift)) == "macOS screenshot")
        #expect(kb.osWarning(Shortcut(key: "t", mods: cmd)) == nil)
    }

    // MARK: Menu / display formatting

    @Test("menuEquivalent applies AppKit's Shift+letter quirk")
    func menuEquivalent() {
        withDefaults { defaults in
            let kb = Keybindings(defaults: defaults)
            // ⌘⇧T must become ("T", .command) — uppercase key, Shift dropped.
            let (key, mask) = kb.menuEquivalent("reopenTab")
            #expect(key == "T")
            #expect(mask == cmd)

            // Non-letter keys keep Shift in the mask (no quirk).
            kb.set("zoomIn", Shortcut(key: "=", mods: cmdShift))
            let (k2, m2) = kb.menuEquivalent("zoomIn")
            #expect(k2 == "=" && m2 == cmdShift)

            // Suspended mode blanks every equivalent.
            kb.suspended = true
            #expect(kb.menuEquivalent("newTab") == ("", []))
        }
    }

    @Test("displayString renders modifiers in macOS order")
    func displayString() {
        let kb = withDefaults { Keybindings(defaults: $0) }
        #expect(kb.displayString(Shortcut(key: "t", mods: cmdShift)) == "⇧⌘T")
        #expect(kb.displayString(Shortcut(key: "f", mods: [.command, .control])) == "⌃⌘F")
        #expect(kb.displayString(Shortcut(key: "t", mods: [.command, .option])) == "⌥⌘T")
    }

    @Test("keyLabel maps special keys to symbols")
    func keyLabel() {
        #expect(Keybindings.keyLabel(" ") == "Space")
        #expect(Keybindings.keyLabel("\u{1b}") == "esc")
        #expect(Keybindings.keyLabel("\r") == "↩")
        #expect(Keybindings.keyLabel("\t") == "⇥")
        #expect(Keybindings.keyLabel("-") == "−")
        #expect(Keybindings.keyLabel("t") == "T")
        #expect(Keybindings.keyLabel("f1") == "f1") // multi-char keys pass through
    }
}
