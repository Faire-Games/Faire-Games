//! The bundled sound clips: every clip a game names is bundled and preloaded, every bundled clip
//! is played by something, and each one is in the format `day-part-sound` plays on every platform
//! without converting (16-bit PCM WAV, mono, 44.1 kHz).

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use gamekit::chrome::{Sfx, cues};

/// Each game's directory under `games/`, with the clips it preloads besides the shared ones.
const GAMES: &[(&str, &[Sfx])] = &[
    ("blockblast", blockblast::SOUNDS),
    ("breakout", breakout::SOUNDS),
    ("charades", charades::SOUNDS),
    ("mines", mines::SOUNDS),
    ("reversi", reversi::SOUNDS),
    ("pipes", pipes::SOUNDS),
    ("sirtet", sirtet::SOUNDS),
    ("solitaire", solitaire::SOUNDS),
    ("sudoku", sudoku::SOUNDS),
    ("twentyfortyeight", twentyfortyeight::SOUNDS),
];

/// Android's and HarmonyOS's SoundPool refuse a clip that decodes past about 1 MB.
const MAX_CLIP_BYTES: u64 = 1_000_000;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn assets() -> PathBuf {
    root().join("resource/assets")
}

fn names(clips: &[Sfx]) -> BTreeSet<String> {
    clips.iter().map(|c| c.as_str().to_string()).collect()
}

/// Every `"sounds/…"` string literal in the Rust files under `dir`.
fn named_in(dir: &Path) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            out.extend(named_in(&path));
        } else if path.extension().is_some_and(|e| e == "rs") {
            let text = std::fs::read_to_string(&path).unwrap();
            let mut rest = text.as_str();
            while let Some(i) = rest.find("\"sounds/") {
                let tail = &rest[i + 1..];
                let end = tail.find('"').unwrap();
                out.insert(tail[..end].to_string());
                rest = &tail[end..];
            }
        }
    }
    out
}

/// Every `.wav` under `dir`, as a path relative to `resource/assets/`.
fn bundled(dir: &Path, out: &mut BTreeSet<String>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            bundled(&path, out);
        } else if path.extension().is_some_and(|e| e == "wav") {
            let rel = path.strip_prefix(assets()).unwrap();
            out.insert(rel.to_string_lossy().replace('\\', "/"));
        }
    }
}

#[test]
fn every_named_clip_is_bundled_and_preloaded() {
    let shared = names(cues::SHARED);
    assert!(
        named_in(&root().join("gamekit/src")).is_subset(&shared),
        "a shared cue plays a clip missing from cues::SHARED"
    );
    for (game, sounds) in GAMES {
        let preloaded: BTreeSet<String> = names(sounds).union(&shared).cloned().collect();
        let named = named_in(&root().join("games").join(game).join("src"));
        assert!(!named.is_empty(), "{game} names no clips");
        let missing: Vec<_> = named.difference(&preloaded).collect();
        assert!(
            missing.is_empty(),
            "{game} plays clips it never preloads: {missing:?}"
        );
        for clip in &preloaded {
            assert!(assets().join(clip).is_file(), "{clip} is not bundled");
        }
    }
}

#[test]
fn every_bundled_clip_is_played() {
    let mut played = names(cues::SHARED);
    for (_, sounds) in GAMES {
        played.extend(names(sounds));
    }
    let mut files = BTreeSet::new();
    bundled(&assets().join("sounds"), &mut files);
    let unused: Vec<_> = files.difference(&played).collect();
    assert!(unused.is_empty(), "bundled clips nothing plays: {unused:?}");
}

#[test]
fn clips_are_16_bit_mono_44k_pcm() {
    let mut files = BTreeSet::new();
    bundled(&assets().join("sounds"), &mut files);
    for clip in files {
        let path = assets().join(&clip);
        let bytes = std::fs::read(&path).unwrap();
        assert!(
            bytes.len() as u64 <= MAX_CLIP_BYTES,
            "{clip} is too long for SoundPool"
        );
        assert!(
            bytes.len() > 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WAVE",
            "{clip} is not a WAV file"
        );
        let mut at = 12;
        let mut fmt = None;
        while at + 8 <= bytes.len() {
            let id = &bytes[at..at + 4];
            let len = u32::from_le_bytes(bytes[at + 4..at + 8].try_into().unwrap()) as usize;
            if id == b"fmt " {
                fmt = Some(&bytes[at + 8..at + 8 + len]);
                break;
            }
            at += 8 + len + (len & 1);
        }
        let fmt = fmt.unwrap_or_else(|| panic!("{clip} has no fmt chunk"));
        let u16_at = |i: usize| u16::from_le_bytes([fmt[i], fmt[i + 1]]);
        let rate = u32::from_le_bytes(fmt[4..8].try_into().unwrap());
        assert_eq!(
            (u16_at(0), u16_at(2), rate, u16_at(14)),
            (1, 1, 44_100, 16),
            "{clip}: want PCM, mono, 44.1 kHz, 16-bit"
        );
    }
}
