//! Compiles the word lists into the game: every `words/<locale>/<deck>.txt` becomes an entry of
//! `LOCALES` in `$OUT_DIR/words.rs`, which src/model.rs includes. Adding a locale or a deck is
//! adding files; no code changes (words/README.md).

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

fn sorted_entries(dir: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("reading {}: {e}", dir.display()))
        .filter_map(|e| e.ok().map(|e| e.path()))
        .collect();
    out.sort();
    out
}

fn name_of(path: &Path) -> String {
    path.file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or_default()
        .to_string()
}

fn main() {
    let root =
        PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("cargo sets this")).join("words");
    println!("cargo:rerun-if-changed=words");

    let mut out = String::from(
        "/// Every word list: `(locale, [(deck id, file text)])`, sorted by locale and deck id.\n\
         pub static LOCALES: &[(&str, &[(&str, &str)])] = &[\n",
    );
    for locale in sorted_entries(&root).into_iter().filter(|p| p.is_dir()) {
        let tag = name_of(&locale);
        assert!(
            tag.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'),
            "words/{tag}: a locale folder is named by its language tag, like `en` or `pt-BR`"
        );
        let _ = writeln!(out, "    ({tag:?}, &[");
        for deck in sorted_entries(&locale) {
            if deck.extension().and_then(|e| e.to_str()) != Some("txt") {
                continue;
            }
            let id = name_of(&deck);
            assert!(
                id.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'),
                "words/{tag}/{id}.txt: a deck id is lowercase letters, digits and hyphens"
            );
            let path = deck.to_string_lossy().into_owned();
            let _ = writeln!(out, "        ({id:?}, include_str!({path:?})),");
        }
        let _ = writeln!(out, "    ]),");
    }
    out.push_str("];\n");

    let dest = PathBuf::from(std::env::var("OUT_DIR").expect("cargo sets this")).join("words.rs");
    std::fs::write(&dest, out).unwrap_or_else(|e| panic!("writing {}: {e}", dest.display()));
}
