# The App Fair release

This repository is a fork of [Day Games](https://github.com/daybrite/Day-Games) that also ships
**Fair Games**, the App Fair Project's app: the same source, built as the `appfair`
[flavor](https://daybrite.dev/docs/flavors), carrying the identity of the store records that
already exist.

Those records were served until now by the Skip app at `appfair/Faire-Games-Skip`, whose last
release was 1.8.9 (build 35). A build from this flavor is the next version of that app, not a new
one, so everyone who has Fair Games installed gets it as an update.

## What the flavor restates

| | base app (`Day.toml`) | `appfair` (`Day-appfair.toml`) |
|---|---|---|
| app id | `dev.daybrite.games` | `org.appfair.app.Faire-Games` |
| Android application id | (the same) | `org.appfair.app.Faire_Games` — the id Google Play knows |
| name | Day Games | Fair Games |
| version | 0.1.4, from `Cargo.toml` | 1.9.0 — past the Skip app's 1.8.9 |
| build number | 6 | 36 — past the Skip app's 35 |
| deep-link scheme | `daygames` | `fairegames` |
| targets | eight | `ios-uikit`, `android-mdc` |
| artifacts | `day-games-…` | `fair-games-1.9.0-ios-uikit.ipa`, `fair-games-1.9.0-android-mdc.aab` |
| icon | `resource/icons/icon.svg` | `resource-appfair/icons/icon.svg` — the pixel heart the app ships today |
| store listing | `store/` | `store-appfair/` — App Fair's name, URLs and copy |

Build it, and check what it produced:

```sh
day build --flavor appfair -p ios-uikit
day pack  --flavor appfair -p android-mdc
day --flavor appfair metadata          # the merged identity, before building anything
day --flavor appfair lint
```

Output lands under `build/day/flavors/appfair/`, so the two apps never overwrite each other.

## Releasing

`.github/workflows/appfair.yml` builds the flavor on every change to these files and, on a
`vX.Y.Z` tag, uploads it: the App Store and Google Play jobs take the `flavor-appfair-dist-…`
packages and stage `store-appfair/` as the listing. `ci.yml` is untouched — it still builds the
base app on all eight targets and owns the tag's GitHub release.

Before tagging a release, raise both numbers in `Day-appfair.toml`: `version` past the last one
the App Store accepted, and `build` past the last one either store has seen. Google Play rejects a
`versionCode` it already has, and App Store Connect rejects a version string that does not climb.

## Keeping the fork a fork

Everything above is new files. The only changed file the flavor needed was
`platform/{ios,macos}/Runner/Info.plist`, where `day lint --fix` replaced two scaffolded literals
(the app name and the URL scheme) with the `$(DAY_APP_TITLE)` and `$(DAY_URL_SCHEME)` build
settings Day.toml drives — a migration the upstream scaffold now writes by itself, and one worth
sending upstream so the fork and Day Games stay byte-identical outside these files:

```
Day-appfair.toml
resource-appfair/
store-appfair/
.github/workflows/appfair.yml
APPFAIR.md
```
