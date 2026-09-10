# Day Games — UI strings (https://daybrite.dev/docs/localization). Add a locale by dropping a
# sibling folder (e.g. locales/fr/app.ftl) and registering it in src/lib.rs.

app_title = Day Games

nav_breakout = Breakout
nav_sirtet = Sirtet
nav_sudoku = Sudoku
nav_2048 = 2048

close_game = Close game

# Shared game chrome (gamekit::chrome)
gk_pause = Pause
gk_paused = PAUSED
gk_resume = Resume
gk_new_game = New Game
gk_settings = Settings
gk_instructions = Instructions
gk_quit = Quit Game
gk_play_again = Play Again
gk_game_over = GAME OVER
gk_score = Score
gk_best = Best
gk_new_high_score = New High Score!
gk_vibrations = Vibrations
gk_data = Data
gk_done = Done
gk_cancel = Cancel
gk_reset_high_score = Reset High Score
gk_reset_high_score_title = Reset High Score?
gk_reset_high_score_message = This will permanently reset the high score to zero.
gk_reset_confirm = Reset
gk_game_over_heading = Game over

# Breakout
bk_score = SCORE: { $n }
bk_level = LV { $n }
bk_level_caption = Level
bk_tap_to_launch = TAP TO LAUNCH
bk_drag_to_move = DRAG TO MOVE PADDLE
bk_level_clear = LEVEL { $n } CLEAR!
bk_next_level = Next Level
bk_help_intro = Bounce a ball off your paddle to break every brick.
bk_help_play = How to play
bk_help_play_1 = • **Drag** anywhere on the play area to move the paddle. It rides above your finger, and a quick upward swipe smashes the ball harder.
bk_help_play_2 = • Keep the ball in play. If it falls below the paddle, you lose a life.
bk_help_play_3 = • Hit every brick to clear the level and advance. Bricks broken in quick succession multiply your score.
bk_help_powerups = Power-ups
bk_help_powerups_1 = Some bricks drop power-ups when broken. Catch them with the paddle for short-lived bonuses such as a wider paddle, a slower ball, a smashing ball that flies straight through bricks, extra balls, or an extra life.
bk_help_lives = Lives and game over
bk_help_lives_1 = You start with three lives. Lose all of them and the game ends. Clearing every brick advances you to the next, faster level, where some bricks take more than one hit.

# Sirtet
st_title = SIRTET
st_score = SCORE { $n }
st_level_lines = LV { $level }   LINES { $lines }
st_high = HIGH { $n }
st_level = Level
st_lines = Lines
st_game_over = Game Over
st_clear_single = SINGLE
st_clear_double = DOUBLE
st_clear_triple = TRIPLE
st_clear_sirtet = SIRTET!
st_help_intro = Stack the falling pieces and clear complete rows before the well fills up.
st_help_play = How to play
st_help_play_1 = • **Drag left or right** to move the falling piece; on a keyboard, the arrow keys move it.
st_help_play_2 = • **Tap** to rotate the piece.
st_help_play_3 = • **Drag down** to drop the piece faster.
st_help_lines = Clearing lines
st_help_lines_1 = • Fill a complete horizontal row to clear it.
st_help_lines_2 = • Clearing **several lines at once** scores extra. Four at a time is the biggest reward.
st_help_levels = Levels and speed
st_help_levels_1 = The game speeds up as you clear lines. Higher levels drop pieces faster.
st_help_over_1 = The game ends when a new piece can no longer enter the well.

# 2048
tf_title = 2048
tf_score = SCORE { $n }
tf_best = BEST { $n }
tf_game_over = Game Over
tf_keep_going = Keep Going
tf_won_title = 2048!
tf_easy = Easy
tf_normal = Normal
tf_hard = Hard
tf_detail_easy = Only 2s spawn. 3 undos per game.
tf_detail_normal = Classic rules. 90% twos, 10% fours.
tf_detail_hard = 20% fours. Two tiles spawn per move.
tf_choose_difficulty = Choose Difficulty
tf_undo = Undo ({ $n })
tf_undo_a11y = Undo the last move
tf_won_message = You made the 2048 tile. Keep going for a higher score?
tf_help_intro = Combine matching tiles on a 4×4 grid to reach the **2048** tile.
tf_help_play = How to play
tf_help_play_1 = • **Swipe** up, down, left, or right to slide every tile that way; on a keyboard, use the arrow keys.
tf_help_play_2 = • When two tiles with the **same number** collide, they merge into one tile with their **sum**.
tf_help_play_3 = • After every move, a new **2** (or sometimes **4**) appears on a random empty cell.
tf_help_goal = Goal
tf_help_goal_1 = Create a **2048** tile to win. After winning, you can keep going for a higher score.
tf_help_over_1 = The game ends when the board is full and no two adjacent tiles match.
tf_help_tips = Tips
tf_help_tips_1 = • Pick a corner and keep your largest tile parked there.
tf_help_tips_2 = • Build merges in a single direction so smaller tiles line up underneath your big one.
tf_help_tips_3 = • On Easy, **undo** is available. Use it to recover from a mistake.

# Sudoku
su_title = SUDOKU
su_difficulty = Difficulty
su_time = Time
su_easy = Easy
su_medium = Medium
su_hard = Hard
su_expert = Expert
su_detail_easy = 46 clues • unlimited hints
su_detail_medium = 36 clues • 3 hints
su_detail_hard = 30 clues • no hints
su_detail_expert = 26 clues • no hints • no same-number highlight
su_cell_a11y = Row { $row }, column { $col }
su_key_a11y = Enter { $n }
su_notes = Notes
su_notes_on = Notes ✓
su_hint = Hint
su_hint_n = Hint ({ $n })
su_hint_unlimited = Hint (∞)
su_undo = Undo
su_redo = Redo
su_checkpoint = Checkpoint
su_commit = Commit
su_revert = Revert
su_give_up = Give Up
su_give_up_title = Give up?
su_give_up_message = The solution fills the empty cells and the puzzle does not count as solved.
su_give_up_confirm = Give Up
su_stars = ⭐⭐⭐
su_solved_title = Puzzle Solved!
su_new_best = New Best Time!
su_best = Best: { $time }
su_choose_difficulty = Choose Difficulty
su_default_difficulty = Default Difficulty
su_records = Records
su_puzzles_solved = Puzzles Solved
su_reset_records = Reset Sudoku Records
su_reset_title = Reset Sudoku Records?
su_reset_message = This will permanently reset all Sudoku best times and puzzle counts.

# Sudoku instructions (the how-to-play sheet; inline markdown for emphasis)
su_help_intro = Fill the 9×9 grid so every row, every column, and every 3×3 box contains the digits 1 through 9 exactly once.
su_help_play = How to play
su_help_play_1 = • **Tap a cell** to select it.
su_help_play_2 = • **Tap a digit** in the keypad to fill the selected cell.
su_help_play_3 = • When the selected cell already contains a digit, that digit's key sinks in. Tap it again to clear the cell.
su_help_play_4 = • Use **notes mode** (the pencil) to mark candidate digits in a cell while you work out which numbers are still possible.
su_help_checkpoint = Checkpoint
su_help_checkpoint_1 = • Tap **Checkpoint** to start a tentative session. Every digit you place after that point is shown in a distinctive color so you can tell experiment from confirmed work.
su_help_checkpoint_2 = • The Checkpoint button then splits into **Commit** (keep the placements and clear the highlight) and **Revert** (remove every checkpoint placement and return to where the session started).
su_help_undo = Undo and redo
su_help_undo_1 = • Tap **Undo** to take back the most recent move. After undoing, the button splits in two so you can **Redo**.
su_help_undo_2 = • Undo and redo are unlimited within the current puzzle. A new placement after an undo clears the redo history.
su_help_win = Hints and winning
su_help_win_1 = • The starting clues cannot be changed.
su_help_win_2 = • The timer runs while you play. Your **best time** for each difficulty is saved.
su_help_win_3 = • Some difficulties allow **hints**. Use them sparingly.
su_help_win_4 = • The puzzle is complete when every cell holds a valid digit and every row, column, and 3×3 box satisfies the no-repeat rule.
