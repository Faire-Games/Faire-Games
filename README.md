# Day Games

A [Day](https://daybrite.dev) app: one Rust codebase, native widgets on every platform.

## Run it

Day compiles **one backend per binary**, so choose a target when you build or launch — a bare
`cargo build` enables no backend feature and will not link. The Day CLI supplies the right
feature for each target:

```sh
day doctor                  # check the toolchains for your targets
day launch -p ios-uikit   # build + run
day build  -p ios-uikit   # build only
```

Targets live in `Day.toml`. To use plain cargo, pass the backend feature yourself, e.g.
`cargo build --features appkit` (macOS) / `--features gtk` / `--features uikit` /
`--features mdc` (Android).

## What's inside

- `src/lib.rs` — the UI (`root()`), shared across every platform: a home grid of game tiles
  that presents each game in a fullscreen cover with an X to exit. Tile previews are drawn by
  each game's own crate with the same code that renders gameplay.
- `games/` — one crate per game (`games/breakout`, `games/sirtet`, `games/sudoku`,
  `games/twentyfortyeight`): canvas or grid-layout UI, physics on the frame clock, and a
  serde save-state.
- `gamekit/` — the shared persistence mechanism: each game's state is saved when it closes or
  the app is backgrounded, and restored the next time it opens.
- `resource/locales/en/app.ftl` — every user-facing string ([localization](https://daybrite.dev/docs/localization)).
- `dayscript/smoke.yaml` — a [dayscript](https://daybrite.dev/docs/dayscript) UI test:
  `day launch -p ios-uikit --script dayscript/smoke.yaml`.
- `platform/` — the thin native host projects (Xcode / Gradle / hvigor) the mobile targets
  build through; `day build` keeps their identity in sync with `Day.toml`.
- `Day.toml` — app metadata + the target list.

`day lint` checks routes, element ids, and locale coverage.
