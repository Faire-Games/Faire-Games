//! gamekit — the games' standard save-state mechanism. Each game serializes its durable state
//! (board, score, best) to JSON in `day-part-prefs` (docs/prefs.md) and restores it the next
//! time it opens. Two write triggers cover every exit path:
//!
//! - **game exit**: [`autosave`] hooks the page scope's cleanup, so closing the cover (the X
//!   button, system back, a route change) saves — on every backend, ArkUI included;
//! - **app backgrounding**: one process-wide set of lifecycle handlers
//!   (`DidEnterBackground` / `WillResignActive` / `WillTerminate`, where the backend delivers
//!   them — docs/lifecycle.md) saves every open game.
//!
//! [`on_background`] rides the same lifecycle handlers for a game that wants to react to
//! leaving the foreground — a timed game pauses its clock — before its state is saved.
//!
//! [`chrome`] is the shell every game shares: the pause menu, the results cards, the
//! settings and how-to-play sheets, the pause button, and the haptic gate.

pub mod chrome;

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use day_reactive::Scope;
use day_spec::Lifecycle;
use serde::Serialize;
use serde::de::DeserializeOwned;

thread_local! {
    /// A fixed seed for scripted runs (see [`set_seed_override`]).
    static SEED_OVERRIDE: Cell<Option<u64>> = const { Cell::new(None) };
}

/// Make every later [`seed`] return `seed` — what the app installs from `DAY_GAMES_SEED` so a
/// dayscript walkthrough meets the same puzzle, brick layout, and piece order on every run
/// and every target. One value for all games: they are independent, so sharing it costs
/// nothing, and it keeps the answer independent of which game's preview drew first.
pub fn set_seed_override(seed: u64) {
    SEED_OVERRIDE.with(|s| s.set(Some(seed | 1)));
}

/// A fresh RNG seed per game start: the wall clock's nanoseconds where the platform has one,
/// browser entropy on the web (wasm32 has no `SystemTime`, and asking aborts the app). Always
/// odd, so an xorshift never seeds to zero.
pub fn seed() -> u64 {
    if let Some(fixed) = SEED_OVERRIDE.with(|s| s.get()) {
        return fixed;
    }
    #[cfg(not(target_arch = "wasm32"))]
    let raw = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x9E37_79B9_7F4A_7C15);
    #[cfg(target_arch = "wasm32")]
    let raw = {
        let mut bytes = [0u8; 8];
        // A failed fill leaves zeros; the `| 1` below still yields a valid (if fixed) seed.
        let _ = getrandom::fill(&mut bytes);
        u64::from_le_bytes(bytes)
    };
    raw | 1
}

fn pref_key(key: &str) -> String {
    format!("save.{key}")
}

/// The saved state for `key`, if a readable one exists. An unparsable save (a schema change)
/// is discarded rather than propagated — the game starts fresh.
pub fn restore<T: DeserializeOwned>(key: &str) -> Option<T> {
    let raw = day_part_prefs::get(&pref_key(key))?;
    match serde_json::from_str(&raw) {
        Ok(v) => Some(v),
        Err(e) => {
            eprintln!("gamekit: discarding unreadable save {key:?}: {e}");
            let _ = day_part_prefs::remove(&pref_key(key));
            None
        }
    }
}

/// Persist `state` under `key` now.
pub fn save<T: Serialize>(key: &str, state: &T) {
    match serde_json::to_string(state) {
        Ok(s) => {
            let _ = day_part_prefs::set(&pref_key(key), &s);
        }
        Err(e) => eprintln!("gamekit: failed to serialize save {key:?}: {e}"),
    }
}

/// Delete the saved state for `key`.
pub fn clear(key: &str) {
    let _ = day_part_prefs::remove(&pref_key(key));
}

thread_local! {
    /// Save closures for the games currently open (usually zero or one).
    static LIVE: RefCell<HashMap<String, Rc<dyn Fn()>>> = RefCell::new(HashMap::new());
    /// Background hooks for the games currently open, run before the saves.
    static BACKGROUND: RefCell<HashMap<String, Rc<dyn Fn()>>> = RefCell::new(HashMap::new());
    static LIFECYCLE_HOOKED: Cell<bool> = const { Cell::new(false) };
}

fn save_all() {
    // Clone the closures out so a hook that touches the registry can't deadlock the borrow.
    let hooks: Vec<Rc<dyn Fn()>> = BACKGROUND.with(|m| m.borrow().values().cloned().collect());
    for f in hooks {
        f();
    }
    let snap: Vec<Rc<dyn Fn()>> = LIVE.with(|m| m.borrow().values().cloned().collect());
    for f in snap {
        f();
    }
}

/// One process-wide lifecycle registration; `lifecycle_supported` skips phases this backend
/// never delivers (docs/lifecycle.md) — scope-cleanup saving still covers those platforms.
fn hook_lifecycle() {
    let first = LIFECYCLE_HOOKED.with(|h| !h.replace(true));
    if first {
        for phase in [
            Lifecycle::DidEnterBackground,
            Lifecycle::WillResignActive,
            Lifecycle::WillTerminate,
        ] {
            if day_core::lifecycle_supported(phase) {
                day_core::on_lifecycle(phase, save_all);
            }
        }
    }
}

/// Run `f` whenever the app leaves the foreground while the CURRENT scope (the game's page) is
/// alive — before that game's [`autosave`] snapshot is taken, so a clock it stops is saved
/// stopped. Desktop backends deliver no such phase; the hook is simply never called there.
pub fn on_background(key: &'static str, f: impl Fn() + 'static) {
    let hook: Rc<dyn Fn()> = Rc::new(f);
    BACKGROUND.with(|m| m.borrow_mut().insert(key.to_string(), hook));
    hook_lifecycle();
    Scope::current().on_cleanup(move || {
        BACKGROUND.with(|m| {
            m.borrow_mut().remove(key);
        });
    });
}

/// Keep `snapshot` registered as `key`'s live state provider while the CURRENT scope (the
/// game's page) is alive: the state is saved when the scope is disposed (the game exited) and
/// whenever the app is backgrounded. Call once from the game's page builder.
pub fn autosave<T: Serialize>(key: &'static str, snapshot: impl Fn() -> T + 'static) {
    let saver: Rc<dyn Fn()> = Rc::new(move || save(key, &snapshot()));
    LIVE.with(|m| m.borrow_mut().insert(key.to_string(), saver.clone()));
    hook_lifecycle();

    Scope::current().on_cleanup(move || {
        saver();
        LIVE.with(|m| {
            m.borrow_mut().remove(key);
        });
    });
}
