import Foundation

/// Renderer-facing pet state. Deliberately independent from Moppet's
/// `PetState` so the MatePet module can be dropped into another host without
/// importing the app's cleaning / Brain code. The host maps its own state enum
/// to this one (see `PetState.matePetState` in the app target).
public enum MatePetState: String, Sendable, CaseIterable {
    case idle
    case thinking
    case talking
    case scanning
    case cleaning
    case celebrating
    case sleeping
    case sad
}

/// One-shot actions that sit *above* the state machine (Mate-Engine's Dance /
/// Hide / Chibi / locomotion layer). An action plays for its own duration and
/// then hands control back to `state`, so a dance does not permanently change
/// the pet's mood.
public enum MatePetAction: String, Sendable {
    case dance
    case hide
    case appear
    case wake
    case chibiOn
    case chibiOff
    case walkLeft
    case walkRight
    case stopWalk
    case poke
    case pet
    case stretch
    case wave
}

/// Which part of the avatar the pointer hit. Three-vrm does not expose a
/// collider, so the interaction layer uses the same coarse split Mate-Engine
/// uses: the upper band of the pet frame is the head, the rest is the body.
public enum MatePetHitRegion: String, Sendable {
    case head
    case body
}

/// Events emitted by the page. Everything crosses the JS bridge as JSON; the
/// engine translates it into this typed enum so the host never parses strings.
public enum MatePetEvent: Sendable {
    /// The HTML shell is alive and `window.matePet` exists. The panel may be
    /// revealed now (the page shows its own loading veil until the VRM lands).
    case ready
    /// The VRM is loaded, rigged and has rendered its first frame.
    case modelReady
    /// Page-side failure. `message` is already human-readable.
    case loadError(String)
    /// Diagnostic line from the page (WebGL warnings, missing expressions…).
    case log(String)
    /// The hide animation finished; the host should order the panel out.
    case hideFinished
    /// Repeated head pokes / petting strokes, so the host can grow the bond.
    case petted(count: Int)
}

/// Persisted MatePet-only preferences. Kept in the module (not `PetSettings`)
/// so the host's window preferences and the avatar preferences stay separate.
public enum MatePetSettings {
    private static let chibiKey = "matepet.chibi"
    private static let wanderKey = "matepet.wander"
    private static let mutedKey = "matepet.muted"

    public static var chibi: Bool {
        get { UserDefaults.standard.bool(forKey: chibiKey) }
        set { UserDefaults.standard.set(newValue, forKey: chibiKey) }
    }

    /// Random desktop walk. On by default to match Mate-Engine's locomotion,
    /// but with a long randomizer (20–40s) so the pet is not constantly moving.
    public static var wander: Bool {
        get {
            if UserDefaults.standard.object(forKey: wanderKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: wanderKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: wanderKey) }
    }

    public static var muted: Bool {
        get { UserDefaults.standard.bool(forKey: mutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: mutedKey) }
    }
}