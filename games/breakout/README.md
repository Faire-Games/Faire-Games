# breakout

A **composite** Day piece — a reusable widget built purely from Day's core primitives. There is no
per-backend or native code and no cargo features, so it works on every backend (AppKit, GTK, Qt,
UIKit, Android, XAML) for free.

## Use

Add it as a dependency (versioned, from crates.io by default) and call the builder from your app:

```rust
use day::prelude::*;
use breakout::breakout;

fn view() -> AnyPiece {
    column((
        label("Downloads"),
        breakout("3 new"),
    )).any()
}
```

## Build

```sh
cargo build                 # compiles the library against day on crates.io
```

Composite pieces have no runnable binary of their own — they are verified by compiling and by being
used from an app. Scaffold against the day git remote with `--git`, or against a local day checkout
with `DAY_LOCAL` set / `day new piece … --local <path>`.

## Next steps

- Rename `breakout` and give it real parameters / builder methods.
- Compose from `row` / `column` / `canvas` / `label` and the `Decorate` modifiers.
- Bind reactive attributes to a `Signal<_>` for live updates.
