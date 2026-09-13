/// Which system level a HUD is about.
public enum HUDKind: String, Sendable, CaseIterable, Codable {
    case volume
    case brightness
}

/// One level as the monitors report it, normalised for the views.
public struct HUDReading: Equatable, Sendable {
    public let kind: HUDKind
    /// Always within 0...1; a non-finite input reads as 0.
    public let level: Double
    /// Volume only — the system mute switch. Always `false` for brightness.
    public let isMuted: Bool

    public init(kind: HUDKind, level: Double, isMuted: Bool = false) {
        self.kind = kind
        self.level = level.isFinite ? min(max(level, 0), 1) : 0
        self.isMuted = kind == .volume && isMuted
    }
}

/// The copy and symbols the HUD draws (spec §2 "Copy and symbols").
public enum HUDGlyph {
    public static func label(for kind: HUDKind) -> String {
        switch kind {
        case .volume: "Sound"
        case .brightness: "Brightness"
        }
    }

    public static func symbol(for reading: HUDReading) -> String {
        switch reading.kind {
        case .brightness:
            return "sun.max.fill"
        case .volume:
            if reading.isMuted || reading.level == 0 { return "speaker.slash.fill" }
            if reading.level < 1.0 / 3.0 { return "speaker.wave.1.fill" }
            if reading.level < 2.0 / 3.0 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }

    /// How much of the bar is filled: the level, or nothing while muted.
    public static func barFraction(for reading: HUDReading) -> Double {
        reading.isMuted ? 0 : reading.level
    }
}
