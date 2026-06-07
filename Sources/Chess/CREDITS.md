# Chess module credits

The bundled chess piece artwork is open-source under licences compatible with
Faire-Games' own GPL-2.0-or-later licence.

## Piece sets

### `piece_cburnett_*` — Colin M. L. Burnett's Wikipedia chess set

* Author: Colin M. L. Burnett (Wikipedia user "Cburnett")
* Licence: GNU GPL version 2 or later (GPLv2+)
* Original SVGs sourced from the Lichess project's bundled copy at
  <https://github.com/lichess-org/lila/tree/master/public/piece/cburnett>
* See <https://en.wikipedia.org/wiki/User:Cburnett> for the original artwork.

### `piece_merida_*` — Armando Hernandez Marroquin's Merida set

* Author: Armando Hernandez Marroquin
* Licence: GNU GPL version 2 or later (GPLv2+)
* Original SVGs sourced from the Lichess project's bundled copy at
  <https://github.com/lichess-org/lila/tree/master/public/piece/merida>

## Format note

Both sets ship in the module as PDF-backed `.imageset` bundles inside
`Resources/Module.xcassets/`. The PDFs were rendered from the upstream SVG
files via `rsvg-convert` so that they can be loaded by SwiftUI's `Image` (and
by SkipUI on Android) while preserving their vector representation.

## Engine

The chess rules, board representation, and AlphaBeta search are provided by
the SkipChess library (<https://github.com/skiptools/skip-chess>) which ships
under the Mozilla Public License 2.0.

All other code in this module is original and licensed under the project's
GPL-2.0-or-later licence; see the top-level `LICENSE.GPL` for the full text.
