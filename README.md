# Day Games

Four games in one app: Breakout, falling blocks, Sudoku, and 2048. Built with
[Day](https://daybrite.dev) in one Rust codebase and rendered with the platform's own widgets on
iPhone, Android, HarmonyOS, macOS, Windows, Linux, and the web. Every game runs entirely on the
device, and your progress is saved when you leave a game and restored when you come back.

## Run it in one command

Install the `day` CLI, then let it clone, build, and launch the app on your desktop:

```sh
cargo install day-cli
day launch --git https://github.com/daybrite/Day-Games.git
```

With no `-p`, the CLI picks the host's own toolkit (`macos-appkit`, `windows-xaml`, `linux-gtk`).
Name a target to run elsewhere: `-p ios-uikit` for a booted Simulator, `-p android-mdc` for a
running emulator or device, `-p harmony-arkui` for HarmonyOS, `-p web-dom` to serve the browser
build. `day doctor` lists what each toolkit needs and prints the install command for anything
missing. The launch prints where it put the checkout, so you can open the code and change it.

## The games

- **Breakout.** Clear the bricks with a paddle that glides under your finger and can smash the
  ball up or down. Quick successive breaks multiply the score, armored bricks arrive on later
  levels, and five power-ups drop from marked bricks: a wider paddle, a slower ball, a ball
  that smashes straight through, extra balls, and an extra life.
- **Falling blocks.** The one you already know how to play, with the next piece shown, lines
  clearing in a flash, and the pieces coming quicker as the level climbs.
- **Sudoku.** Four difficulties, pencil marks, unlimited undo and redo, a checkpoint you can
  commit or revert, hints where the difficulty allows them, and a best time per difficulty.
- **2048.** Slide the tiles, watch them merge, and chase your best score. Reaching 2048 is not
  the end unless you want it to be.

Every game has the same shell: a pause button, a menu to resume, start over, open the
settings, or reread the rules, and a results card with your best score. The rules open by
themselves the first time you play a game. Haptics follow a Vibrations switch in each game's
settings. With a mouse or trackpad the Breakout paddle follows the pointer across the field
and the cursor hides while it does; the arrow keys move the paddle, the piece, the tiles, or
the Sudoku selection.

The home screen is a grid of tiles whose previews are drawn by each game's own crate with the
same code that renders gameplay. Tapping a tile presents the game in a fullscreen cover with an X
to exit. On the phones the games defer the system's edge gestures and disable interactive
dismissal, so an edge swipe mid-game stays in the game.

Everything runs on the device with nothing to sign in to and nothing shown but the game. Each
game is a self-contained crate with physics on the frame clock and a serde save state.

## Build from a clone

Day compiles one toolkit backend per binary, so name a target when you build or launch. Every
target the app ships is listed in `Day.toml`.

```sh
day doctor                       # toolchains present and missing, with fixes
day launch -p macos-appkit       # the Mac's own toolkit (macos-gtk and macos-qt run here too)
day launch -p ios-uikit          # needs a booted Simulator
day launch -p android-mdc        # needs a JDK and a running emulator or device
day launch -p harmony-arkui      # needs the OpenHarmony SDK and an emulator
day launch -p web-dom            # builds the wasm bundle and serves it to your browser
day build  -p windows-xaml       # build only (Windows builds on a Windows host)
```

To build from plain cargo, pass the backend feature yourself, for example
`cargo build --features appkit`; a bare `cargo build` enables no backend and will not link.

Four [dayscripts](https://daybrite.dev/docs/dayscript) drive the app: `smoke.yaml` opens each
game, `sudoku.yaml` walks every Sudoku surface, and `bk.yaml` and `games.yaml` sweep gameplay
for screenshots:

```sh
day launch -p ios-uikit --script dayscript/games.yaml
```

## Inside the code

- `src/lib.rs` is `root()`: the home grid and the fullscreen cover each game opens in, with typed
  routes so deep links and dayscript can open a game by name.
- `games/breakout`, `games/sirtet`, `games/sudoku`, and `games/twentyfortyeight` are one crate
  per game: canvas or grid-layout UI, physics on the frame clock, and a serde save state.
- `gamekit/` is the shared persistence layer: each game's state is saved when its cover closes
  or the app is backgrounded, and restored the next time it opens. A game that keeps a clock
  can also hook the backgrounding itself, which is how Sudoku pauses.
- `resource/locales/en/app.ftl` carries every user-facing string.
- `platform/` holds the thin native host projects the Apple, Android, and HarmonyOS targets
  build through.

`day lint` checks routes, element ids, and locale coverage.

Day Games is open source under the Apache-2.0 license.
