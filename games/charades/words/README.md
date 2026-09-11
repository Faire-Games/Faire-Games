# Charades word lists

Every deck the game offers is a plain text file here, one folder per language:

```
words/
  en/
    animals.txt
    act-it-out.txt
    …
```

The build compiles every file into the game (`build.rs`), so adding a deck or a language means
adding files and changing no code. The lists were written for this project and are licensed like
the rest of the repository.

## The file format

UTF-8 text, one entry per line. Blank lines are skipped, and a line starting with `#` is a comment,
except for two header lines that name the deck in its own language:

```
# title: Animals
# blurb: From aardvarks to zebras.
Aardvark
Albatross
```

The file name is the deck's **id**: lowercase letters, digits and hyphens. The id stays the same in
every language. Saved progress, best scores and the deck's color are keyed by it, and
`ORDER` in `src/model.rs` sets the order decks are offered in. A deck whose id is not in `ORDER`
comes after the listed ones, alphabetically, and gets a color from the id.

`cargo test -p charades` checks every file in every language: a title and a blurb, at least 100
entries, no entry listed twice (ignoring case), none longer than 40 characters, and no stray spaces.
The English decks together must hold at least 3,000 entries.

## What goes in a deck

- Things a group can describe, act out or hum within a few seconds, and that most players know.
- Family-friendly: nothing a parent would skip past at a family gathering.
- No product or company brand names, and no living people. Titles of well-known films and books
  are fine, as are historical figures, characters from works in the public domain, and folklore.
- Natural capitalization: `Hot dog`, `Eiffel Tower`, `Brushing your teeth`.

## Other languages

A language gets its own lists, written for its players rather than translated. A word that is
common in one language can be obscure in another, and film titles, sayings, holidays and famous
people differ between cultures. So:

1. **Folder.** Create `words/<tag>/`, where `<tag>` is the language (`fr`, `de`, `ja`) or a
   regional variant (`pt-BR`, `es-MX`) when the lists need to differ by region.
2. **Decks.** Start from the English ids, since players recognize the colors across languages, but
   write each list fresh. Leave out a deck that doesn't travel, like `sayings`, until it has a
   native list, and add decks that only make sense in that language under a new id.
3. **Titles.** Put each deck's title and blurb in that language in its header. The rest of the
   game's text (buttons, rules, results) is translated in the Fluent catalogs under
   `resource/locales/<tag>/app.ftl`, as for every other game.
4. **Check.** Run `cargo test -p charades`, then play a round with the app set to that language.

The game picks its word lists from the app's language as it opens a deck: the exact tag, then the
language alone (`fr-CA` uses `fr-CA/`, then `fr/`), then English. A player whose language has no
lists yet plays in English.

Later, as lists are added:

- **Choosing a word list.** When more than one language is available, Settings will offer the
  word-list language separately from the app's, for mixed-language groups and learners.
- **Right-to-left scripts.** Arabic and Hebrew decks draw through the same text path as the rest of
  the app's text, which shapes and orders them. A first right-to-left list should be checked on a
  device before it ships.
- **Size.** English is about 40 KB of text. Once many languages ship, the lists can move to data
  assets under `resource/assets/words/<tag>/` and be read when a deck opens, so a phone only
  loads its own language. The file format stays the same, and so does this folder layout.
