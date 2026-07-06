import Cocoa

// MARK: - Keybindings
//
// A single registry of every user-configurable command. The menu (AppDelegate)
// reads its key equivalents from here instead of hardcoding them, and the
// settings page (chromeless://settings#shortcuts) edits them through the bridge.
//
// Overrides live in UserDefaults under "CustomShortcuts" as [id: "rawMods|key"].
// Anything not overridden falls back to the command's default.

/// A key combo: a base character plus modifier flags. For letters `key` is the
/// lowercase base ("t"); Shift is carried in `mods`, never baked into the char.
struct Shortcut: Equatable {
    var key: String
    var mods: NSEvent.ModifierFlags

    /// Canonical form for conflict comparison: case-folded key + the four
    /// device-independent modifier bits we care about.
    var canonical: String {
        "\(mods.intersection(Keybindings.relevantMods).rawValue)|\(key.lowercased())"
    }
}

/// One configurable command. `def` is the factory default; the live value comes
/// from `Keybindings.current(id)`.
struct ShortcutCommand {
    let id: String
    let title: String
    let group: String
    let def: Shortcut
}

final class Keybindings {
    static let shared = Keybindings()
    private let defaultsKey = "CustomShortcuts"

    /// The modifiers we persist / match on. (Ignores caps-lock, fn, numeric pad.)
    static let relevantMods: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    /// The registry, in display order. `group` drives the settings sections.
    let commands: [ShortcutCommand] = {
        func s(_ key: String, _ mods: NSEvent.ModifierFlags) -> Shortcut { Shortcut(key: key, mods: mods) }
        let cmd: NSEvent.ModifierFlags = [.command]
        let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
        return [
            // Tabs & windows
            ShortcutCommand(id: "newTab",       title: "New tab",              group: "Tabs & Windows", def: s("t", cmd)),
            ShortcutCommand(id: "closeTab",     title: "Close tab",            group: "Tabs & Windows", def: s("w", cmd)),
            ShortcutCommand(id: "reopenTab",    title: "Reopen closed tab",    group: "Tabs & Windows", def: s("t", cmdShift)),
            ShortcutCommand(id: "newWindow",    title: "New window",           group: "Tabs & Windows", def: s("n", cmd)),
            ShortcutCommand(id: "closeWindow",  title: "Close window",         group: "Tabs & Windows", def: s("w", cmdShift)),
            ShortcutCommand(id: "toggleTabBar", title: "Toggle tab bar",       group: "Tabs & Windows", def: s("t", [.command, .option])),
            ShortcutCommand(id: "splitView",    title: "Split view",           group: "Tabs & Windows", def: s("e", cmdShift)),

            // Navigation
            ShortcutCommand(id: "openLocation", title: "Search or enter a URL", group: "Navigation", def: s("l", cmd)),
            ShortcutCommand(id: "back",         title: "Back",                 group: "Navigation", def: s("[", cmd)),
            ShortcutCommand(id: "forward",      title: "Forward",              group: "Navigation", def: s("]", cmd)),
            ShortcutCommand(id: "reload",       title: "Reload page",          group: "Navigation", def: s("r", cmd)),
            ShortcutCommand(id: "hardReload",   title: "Reload ignoring cache", group: "Navigation", def: s("r", cmdShift)),
            ShortcutCommand(id: "showHistory",  title: "History",              group: "Navigation", def: s("y", cmd)),

            // Page
            ShortcutCommand(id: "find",         title: "Find on page",         group: "Page", def: s("f", cmd)),
            ShortcutCommand(id: "findNext",     title: "Find next",            group: "Page", def: s("g", cmd)),
            ShortcutCommand(id: "findPrev",     title: "Find previous",        group: "Page", def: s("g", cmdShift)),
            ShortcutCommand(id: "addBookmark",  title: "Bookmark this page",   group: "Page", def: s("d", cmd)),
            ShortcutCommand(id: "copyURL",      title: "Copy current URL",     group: "Page", def: s("c", cmdShift)),
            ShortcutCommand(id: "zoomIn",       title: "Zoom in",              group: "Page", def: s("=", cmd)),
            ShortcutCommand(id: "zoomOut",      title: "Zoom out",             group: "Page", def: s("-", cmd)),
            ShortcutCommand(id: "resetZoom",    title: "Actual size",          group: "Page", def: s("0", cmd)),

            // View & window state
            ShortcutCommand(id: "zenMode",      title: "Frameless mode",       group: "View", def: s("l", cmdShift)),
            ShortcutCommand(id: "fullScreen",   title: "Full screen",          group: "View", def: s("f", [.command, .control])),
            ShortcutCommand(id: "pip",          title: "Picture in picture",   group: "View", def: s("p", cmdShift)),
            ShortcutCommand(id: "pin",          title: "Pin on top",           group: "View", def: s("p", cmd)),
            ShortcutCommand(id: "downloads",    title: "Downloads",            group: "View", def: s("j", cmdShift)),
            ShortcutCommand(id: "snapshot",     title: "Snapshot to desktop",  group: "View", def: s("s", cmdShift)),
            ShortcutCommand(id: "settings",     title: "Settings",             group: "View", def: s(",", cmd)),
        ]
    }()

    private lazy var byId: [String: ShortcutCommand] =
        Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })

    /// id → override. Absent means "use the default".
    private var overrides: [String: Shortcut] = [:]

    /// While the settings page is recording a new combo, the menu drops all key
    /// equivalents so the raw keystroke reaches the web recorder instead of
    /// firing a menu command. Toggled via the bridge; rebuild the menu after.
    var suspended = false

    private init() { load() }

    // MARK: Lookup

    /// The live combo for a command (override if set, else default).
    func current(_ id: String) -> Shortcut {
        overrides[id] ?? byId[id]?.def ?? Shortcut(key: "", mods: [])
    }

    func isCustomized(_ id: String) -> Bool { overrides[id] != nil }

    /// Combos owned by fixed, non-configurable handlers — standard Edit/app menu
    /// items and the raw ⌘1–9 tab switch in TabbedWebView. Binding a configurable
    /// command onto one of these would shadow the built-in, so we reject it. The
    /// conflict check only covers the registry, so this fills the gap.
    private static let reserved: [String: String] = {
        func c(_ key: String, _ mods: NSEvent.ModifierFlags) -> String { Shortcut(key: key, mods: mods).canonical }
        let cmd: NSEvent.ModifierFlags = [.command]
        let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
        var m: [String: String] = [
            c("z", cmd): "Undo", c("z", cmdShift): "Redo", c("x", cmd): "Cut",
            c("c", cmd): "Copy", c("v", cmd): "Paste", c("a", cmd): "Select All",
            c("q", cmd): "Quit", c("h", cmd): "Hide", c("m", cmd): "Minimize",
        ]
        for d in 1...9 { m[c(String(d), cmd)] = "Switch to tab \(d)" }
        return m
    }()

    /// If `shortcut` is owned by a fixed built-in, the built-in's name; else nil.
    func reservedReason(_ shortcut: Shortcut) -> String? { Self.reserved[shortcut.canonical] }

    /// Returns the id of a different command already bound to `shortcut`, if any.
    func conflict(for id: String, _ shortcut: Shortcut) -> String? {
        let target = shortcut.canonical
        for c in commands where c.id != id {
            if current(c.id).canonical == target { return c.id }
        }
        return nil
    }

    // MARK: Mutation

    /// Set an override. Empty key is ignored. Returns false if it collides with
    /// another command (nothing is written in that case).
    @discardableResult
    func set(_ id: String, _ shortcut: Shortcut) -> Bool {
        guard byId[id] != nil, !shortcut.key.isEmpty else { return false }
        if conflict(for: id, shortcut) != nil { return false }
        if byId[id]?.def == shortcut {
            overrides.removeValue(forKey: id) // back to default → drop the override
        } else {
            overrides[id] = shortcut
        }
        save()
        return true
    }

    func reset(_ id: String) {
        overrides.removeValue(forKey: id)
        save()
    }

    func resetAll() {
        overrides.removeAll()
        save()
    }

    // MARK: Menu / display formatting

    /// The (keyEquivalent, modifierMask) an NSMenuItem needs. Mirrors AppKit's
    /// quirk: a Shift+letter must be an uppercase char with Shift dropped from
    /// the mask, otherwise the equivalent never matches the event.
    func menuEquivalent(_ id: String) -> (String, NSEvent.ModifierFlags) {
        if suspended { return ("", []) }
        let sc = current(id)
        var key = sc.key
        var mask = sc.mods.intersection(Self.relevantMods)
        if mask.contains(.shift), key.count == 1, let ch = key.first, ch.isLetter {
            key = key.uppercased()
            mask.remove(.shift)
        }
        return (key, mask)
    }

    /// Human-readable combo, e.g. "⇧⌘T". Modifier order matches macOS.
    func displayString(_ shortcut: Shortcut) -> String {
        var out = ""
        if shortcut.mods.contains(.control) { out += "⌃" }
        if shortcut.mods.contains(.option)  { out += "⌥" }
        if shortcut.mods.contains(.shift)   { out += "⇧" }
        if shortcut.mods.contains(.command) { out += "⌘" }
        out += Self.keyLabel(shortcut.key)
        return out
    }

    /// Symbol/uppercase form of a base key for display.
    static func keyLabel(_ key: String) -> String {
        switch key {
        case " ":  return "Space"
        case "\u{08}", "\u{7f}": return "⌫"
        case "\u{1b}": return "esc"
        case "\r": return "↩"
        case "\t": return "⇥"
        case "-":  return "−"
        default:   return key.count == 1 ? key.uppercased() : key
        }
    }

    // MARK: Persistence

    private func load() {
        guard let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] else { return }
        for (id, s) in raw {
            let parts = s.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let bits = UInt(parts[0]) else { continue }
            let key = String(parts[1])
            guard !key.isEmpty, byId[id] != nil else { continue }
            let sc = Shortcut(key: key, mods: NSEvent.ModifierFlags(rawValue: bits).intersection(Self.relevantMods))
            // Ignore anything that would shadow a fixed built-in (belt-and-suspenders
            // against hand-edited defaults or combos reserved by a newer build).
            if reservedReason(sc) != nil { continue }
            overrides[id] = sc
        }
    }

    private func save() {
        var raw: [String: String] = [:]
        for (id, sc) in overrides {
            raw[id] = "\(sc.mods.intersection(Self.relevantMods).rawValue)|\(sc.key)"
        }
        UserDefaults.standard.set(raw, forKey: defaultsKey)
    }
}
