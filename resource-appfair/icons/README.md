# The Fair Games icon

`icon.svg` is the icon the App Fair build of this app already ships: the one on the home screens
of everyone who installed Fair Games from the App Store or Google Play. An update that changed it
would look like a different app, so the `appfair` flavor keeps it.

It is a vector reconstruction, not a copy. The shipped artwork was a raster set with no master
(`Darwin/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` in the Skip app at
`appfair/Faire-Games-Skip`, drawn for the App Fair Project). The grid, the two pinks and the
background gradient here were measured from that 1024px file and redrawn as rectangles:

| | |
|---|---|
| blocks | 78×78, corner radius 8, on an 88px pitch |
| first block | x=192, y=236 — 8 columns, 7 rows |
| heart rows | `.##..##.` `########` `########` `########` `.######.` `..####..` `...##...` |
| block colors | `#FF6F91` (top two rows), `#FF3D67` (the rest) |
| background | vertical linear gradient, `#241C44` → `#0C081F` |

The source grid above is translated 27px left and 27px up in both the foreground and monochrome
layers. This centers the heart at (512, 512), with equal left/right margins of 165px and
top/bottom margins of 209px in the 1024px frame.

As vector it also gives `day icon build` the layers a raster master cannot: `day:background` and `day:foreground` for the Android adaptive icon, and
`day:monochrome` for the themed one.
