//! gamekit — the games' standard save-state mechanism. Each game serializes its durable state
//! (board, score, best) to JSON in `day-part-prefs` (docs/prefs.md) and restores it the next
//! time it opens. Two write triggers cover every exit path:
//!
//! - **game exit**: [`autosave`] hooks the page scope's cleanup, so closing the cover (the X
//!   button, system back, a route change) saves — on every backend, ArkUI included;
//! - **app backgrounding**: one process-wide set of lifecycle handlers
//!   (`DidEnterBackground` / `WillResignActive` / `WillTerminate`, where the backend delivers
//!   them — docs/lifecycle.md) saves every open game.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use day_reactive::Scope;
use day_spec::Lifecycle;
use serde::Serialize;
use serde::de::DeserializeOwned;

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
    static LIFECYCLE_HOOKED: Cell<bool> = const { Cell::new(false) };
}

fn save_all() {
    // Clone the closures out so a save that touches the registry can't deadlock the borrow.
    let snap: Vec<Rc<dyn Fn()>> = LIVE.with(|m| m.borrow().values().cloned().collect());
    for f in snap {
        f();
    }
}

/// Keep `snapshot` registered as `key`'s live state provider while the CURRENT scope (the
/// game's page) is alive: the state is saved when the scope is disposed (the game exited) and
/// whenever the app is backgrounded. Call once from the game's page builder.
pub fn autosave<T: Serialize>(key: &'static str, snapshot: impl Fn() -> T + 'static) {
    let saver: Rc<dyn Fn()> = Rc::new(move || save(key, &snapshot()));
    LIVE.with(|m| m.borrow_mut().insert(key.to_string(), saver.clone()));

    // One process-wide registration; `lifecycle_supported` skips phases this backend never
    // delivers (docs/lifecycle.md) — scope-cleanup saving still covers those platforms.
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

    Scope::current().on_cleanup(move || {
        saver();
        LIVE.with(|m| {
            m.borrow_mut().remove(key);
        });
    });
}
