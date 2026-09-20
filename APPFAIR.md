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
| version | from `Cargo.toml` | 1.9.0 — past the Skip app's 1.8.9 |
| build number | from `Day.toml` | 36 — past the Skip app's 35 |
| deep-link scheme | `daygames` | `fairegames` |
| targets | eight | `ios-uikit`, `android-mdc` |
| artifacts | `day-games-…` | `fair-games-ios-uikit-unsigned.ipa`, `fair-games-android-mdc.aab` in the queue |
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

`.github/workflows/ci.yml` is the only app workflow. It builds the base app on all eight targets
and publishes their packages on the tag's GitHub release. It does not upload to either store.
No second workflow or flavor packages on the GitHub release are required.

After the release completes, submit its tag and exact commit to
[`appfair/appfair-apps`](https://github.com/appfair/appfair-apps). That queue builds the `appfair`
flavor itself, compares its code and resources with the base release while normalizing declared
identity and launcher-icon differences, then audits the flavor's identity, permissions and
provenance. On publication it signs that build with App Fair's keys and stages `store-appfair/`
for the stores. Executables and non-branding resources must still match; comparison failures
are not automatically waived.

The repository tag (for example, `v2.0.1`) identifies the source release. The store version in
`Day-appfair.toml` has its own sequence and does not have to equal the tag.

Before tagging a release, raise both numbers in `Day-appfair.toml`: `version` past the last one
the App Store accepted, and `build` past the last one either store has seen. Google Play rejects a
`versionCode` it already has, and App Store Connect rejects a version string that does not climb.

## Keeping the fork a fork

The flavor is declared by the files below. The Apple hosts use `$(DAY_APP_TITLE)` and
`$(DAY_URL_SCHEME)` in `platform/{ios,macos}/Runner/Info.plist`, so the generated build settings
supply the flavor's identity. Keep those placeholders aligned with the upstream template. The sole CI workflow publishes the base release; no flavor
workflow is needed:

```
Day-appfair.toml
resource-appfair/
store-appfair/
APPFAIR.md
```
