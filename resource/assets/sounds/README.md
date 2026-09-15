# Sound clips

Every clip in this directory comes from one of six sound packs by Kenney (Kenney Vleugels,
[kenney.nl](https://kenney.nl)), released under
[Creative Commons CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). Each pack's own
`License.txt` says: "You may use these assets in personal and commercial projects. Credit (Kenney
or www.kenney.nl) would be nice but is not mandatory." We credit Kenney here anyway.

| Pack | Version | Page |
|---|---|---|
| Interface Sounds | 1.0 | https://kenney.nl/assets/interface-sounds |
| UI Audio | | https://kenney.nl/assets/ui-audio |
| Impact Sounds | 1.0 | https://kenney.nl/assets/impact-sounds |
| Digital Audio | | https://kenney.nl/assets/digital-audio |
| Casino Audio | 1.1 | https://kenney.nl/assets/casino-audio |
| Music Jingles | | https://kenney.nl/assets/music-jingles |

## How they were prepared

The packs ship Ogg Vorbis. Each clip here was converted with ffmpeg to the format
`day-part-sound` plays everywhere without conversion: 16-bit PCM WAV, mono, 44.1 kHz, with no
metadata chunks. Leading and trailing silence below −60 dBFS was trimmed, and each clip's peak was
set by its role: −9 dBFS for the frequent interface ticks, −4 dBFS for impacts and card sounds,
and −2 dBFS for clears, jingles and endings. The shuffle keeps its first 1.5 seconds, faded out.

```sh
trim="aformat=sample_rates=44100:channel_layouts=mono,silenceremove=start_periods=1:start_threshold=-60dB,areverse,silenceremove=start_periods=1:start_threshold=-60dB,areverse"
# measure the trimmed clip's peak, then apply the gain that brings it to its target
ffmpeg -i in.ogg -af "$trim,volumedetect" -f null -
ffmpeg -i in.ogg -af "$trim,volume=<target − peak>dB" -ac 1 -ar 44100 -c:a pcm_s16le \
  -map_metadata -1 -fflags +bitexact -flags:a +bitexact out.wav
```

## Where each clip came from

| Clip | Pack | Original file |
|---|---|---|
| shared/select | Interface Sounds | select_001 |
| shared/tick | Interface Sounds | tick_002 |
| shared/tap | Interface Sounds | click_001 |
| shared/pluck | Interface Sounds | pluck_001 |
| shared/start | Interface Sounds | maximize_003 |
| shared/success | Interface Sounds | confirmation_001 |
| shared/warning | Interface Sounds | error_004 |
| shared/hint | Interface Sounds | glass_002 |
| shared/thud | Impact Sounds | impactPunch_medium_000 |
| shared/letdown | Digital Audio | lowDown |
| shared/over_arcade | Digital Audio | zapThreeToneDown |
| shared/over_puzzle | Digital Audio | lowThreeTone |
| breakout/brick_1 | Impact Sounds | impactGlass_light_000 |
| breakout/brick_2 | Impact Sounds | impactGlass_medium_000 |
| breakout/brick_4 | Impact Sounds | impactGlass_heavy_000 |
| breakout/paddle | Impact Sounds | impactTin_medium_000 |
| breakout/power | Digital Audio | powerUp2 |
| breakout/life | Digital Audio | powerUp11 |
| breakout/smash | Digital Audio | phaserUp4 |
| breakout/level | Music Jingles | 8-Bit jingles/jingles_NES00 |
| sirtet/rotate | Interface Sounds | toggle_004 |
| sirtet/lock | Impact Sounds | impactSoft_medium_000 |
| sirtet/clear_1 | Digital Audio | pepSound1 |
| sirtet/clear_2 | Digital Audio | pepSound3 |
| sirtet/clear_3 | Digital Audio | powerUp7 |
| sirtet/clear_4 | Music Jingles | 8-Bit jingles/jingles_NES13 |
| 2048/slide | Interface Sounds | drop_001 |
| 2048/merge_m | Interface Sounds | pluck_002 |
| 2048/merge_l | Impact Sounds | impactBell_heavy_004 |
| 2048/undo | Interface Sounds | minimize_003 |
| 2048/won | Music Jingles | Steel jingles/jingles_STEEL02 |
| sudoku/place | UI Audio | click1 |
| sudoku/clear | Interface Sounds | back_002 |
| sudoku/notes | Interface Sounds | toggle_001 |
| sudoku/undo | Interface Sounds | minimize_007 |
| sudoku/redo | Interface Sounds | maximize_007 |
| sudoku/checkpoint | UI Audio | switch7 |
| sudoku/solved | Music Jingles | Pizzicato jingles/jingles_PIZZI03 |
| blockblast/lift | Interface Sounds | select_007 |
| blockblast/place | Impact Sounds | impactWood_light_000 |
| blockblast/place_big | Impact Sounds | impactWood_medium_000 |
| blockblast/cancel | Interface Sounds | drop_002 |
| blockblast/clear_1 | Music Jingles | Pizzicato jingles/jingles_PIZZI00 |
| blockblast/clear_2 | Music Jingles | Pizzicato jingles/jingles_PIZZI04 |
| blockblast/clear_3 | Music Jingles | Pizzicato jingles/jingles_PIZZI05 |
| blockblast/clear_4 | Music Jingles | Pizzicato jingles/jingles_PIZZI08 |
| blockblast/clear_5 | Music Jingles | Pizzicato jingles/jingles_PIZZI09 |
| blockblast/perfect | Music Jingles | Pizzicato jingles/jingles_PIZZI07 |
| blockblast/record | Music Jingles | Pizzicato jingles/jingles_PIZZI10 |
| solitaire/shuffle | Casino Audio | card-shuffle |
| solitaire/deal_1 | Casino Audio | card-slide-1 |
| solitaire/deal_2 | Casino Audio | card-slide-2 |
| solitaire/deal_3 | Casino Audio | card-slide-3 |
| solitaire/deal_4 | Casino Audio | card-slide-4 |
| solitaire/draw | Casino Audio | card-place-2 |
| solitaire/recycle | Casino Audio | card-shove-1 |
| solitaire/pickup | Casino Audio | card-slide-6 |
| solitaire/drop | Casino Audio | card-place-1 |
| solitaire/flip | Casino Audio | card-place-4 |
| solitaire/home | Casino Audio | chips-stack-1 |
| solitaire/finish_1 | Casino Audio | chip-lay-1 |
| solitaire/finish_2 | Casino Audio | chip-lay-2 |
| solitaire/finish_3 | Casino Audio | chip-lay-3 |
| solitaire/suit | Music Jingles | Steel jingles/jingles_STEEL09 |
| solitaire/win | Music Jingles | Steel jingles/jingles_STEEL07 |
| solitaire/bounce | Impact Sounds | impactPlate_light_000 |
| solitaire/undo | Interface Sounds | back_001 |
| mines/reveal | Impact Sounds | impactGeneric_light_000 |
| mines/flag | Impact Sounds | impactWood_light_002 |
| mines/unflag | Impact Sounds | impactSoft_medium_002 |
| mines/chord | Impact Sounds | impactGeneric_light_004 |
| mines/boom | Impact Sounds | impactPunch_heavy_002 |
| mines/win | Music Jingles | Sax jingles/jingles_SAX12 |
| charades/correct | Interface Sounds | confirmation_002 |
| charades/pass | Interface Sounds | minimize_004 |
| charades/clock | Interface Sounds | tick_004 |
| charades/time_up | Interface Sounds | error_006 |
| charades/results | Music Jingles | Sax jingles/jingles_SAX07 |
