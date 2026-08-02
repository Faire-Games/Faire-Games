# Day Games — UI strings (https://daybrite.dev/docs/localization). Add a locale by dropping a
# sibling folder (e.g. locales/fr/app.ftl) and registering it in src/lib.rs.

app_title = Day Games

nav_breakout = Breakout
nav_sirtet = Sirtet
nav_sudoku = Sudoku
nav_2048 = 2048

close_game = Close game

# Breakout
bk_score = SCORE { $n }
bk_level = LV { $n }
bk_tap_to_launch = Tap to launch
bk_game_over = Game Over
bk_play_again = Tap to play again
bk_wide = WIDE
bk_slow = SLOW
bk_smash = SMASH

# Sirtet
st_title = SIRTET
st_score = SCORE { $n }
st_level_lines = LV { $level }   LINES { $lines }
st_game_over = Game Over
st_play_again = Tap to play again

# 2048
tf_title = 2048
tf_score = SCORE { $n }
tf_best = BEST { $n }
tf_game_over = Game Over
tf_try_again = Tap to try again
tf_keep_going = 2048! Keep going

# Sudoku
su_easy = Easy
su_medium = Medium
su_hard = Hard
su_expert = Expert
su_hints = Hints { $n }
su_hints_unlimited = Hints ∞
su_best = Best { $time }
su_solved = Solved in { $time }!
su_solved_best = Solved in { $time } — new best!
su_revealed = Solution revealed
su_undo = Undo
su_redo = Redo
su_notes = Notes
su_notes_on = Notes ✓
su_hint = Hint
su_checkpoint = Checkpoint
su_commit = Keep
su_revert = Revert
su_erase = Erase
su_reveal = Reveal
su_reveal_title = Reveal the solution?
su_reveal_message = This ends the game — the puzzle will not count as solved.
su_reveal_confirm = Reveal
su_new = New
su_new_title = New game
su_new_message = Pick a difficulty for the new puzzle.
su_cancel = Cancel
