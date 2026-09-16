//! Pure Reversi rules and a bounded, deterministic computer opponent.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Board {
    pub black: u64,
    pub white: u64,
    pub turn: bool, // true = black
}

impl Default for Board {
    fn default() -> Self {
        Self {
            black: (1 << 28) | (1 << 35),
            white: (1 << 27) | (1 << 36),
            turn: true,
        }
    }
}

impl Board {
    pub fn discs(self, black: bool) -> u64 {
        if black { self.black } else { self.white }
    }
    pub fn count(self, black: bool) -> u32 {
        self.discs(black).count_ones()
    }
    pub fn flips(self, square: usize, black: bool) -> u64 {
        if square >= 64 || (self.black | self.white) & (1 << square) != 0 {
            return 0;
        }
        let own = self.discs(black);
        let other = self.discs(!black);
        let mut flips = 0;
        for (dx, dy) in [
            (-1, -1),
            (0, -1),
            (1, -1),
            (-1, 0),
            (1, 0),
            (-1, 1),
            (0, 1),
            (1, 1),
        ] {
            let (mut x, mut y) = (square as i32 % 8 + dx, square as i32 / 8 + dy);
            let mut ray = 0;
            while (0..8).contains(&x) && (0..8).contains(&y) {
                let bit = 1u64 << (y * 8 + x);
                if other & bit != 0 {
                    ray |= bit;
                } else {
                    if own & bit != 0 {
                        flips |= ray;
                    }
                    break;
                }
                x += dx;
                y += dy;
            }
        }
        flips
    }
    pub fn legal(self, black: bool) -> Vec<usize> {
        (0..64).filter(|&i| self.flips(i, black) != 0).collect()
    }
    pub fn finished(self) -> bool {
        self.legal(true).is_empty() && self.legal(false).is_empty()
    }
    /// Return the captured discs. A forced pass leaves the turn with the mover.
    pub fn play(&mut self, square: usize) -> Option<u64> {
        let flips = self.flips(square, self.turn);
        if flips == 0 {
            return None;
        }
        let added = flips | (1 << square);
        if self.turn {
            self.black |= added;
            self.white &= !flips;
        } else {
            self.white |= added;
            self.black &= !flips;
        }
        self.turn = !self.turn;
        if self.legal(self.turn).is_empty() {
            self.turn = !self.turn;
        }
        Some(flips)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SaveState {
    pub board: Board,
    /// 0 = computer, 1 = pass-and-play. The human plays black in solo games.
    pub mode: usize,
    /// 0 = easy, 1 = medium, 2 = hard.
    pub difficulty: usize,
    pub rng: u64,
}
impl SaveState {
    pub fn new(mode: usize, difficulty: usize, seed: u64) -> Self {
        Self {
            board: Board::default(),
            mode,
            difficulty,
            rng: seed | 1,
        }
    }
    pub fn apply_save(mut self) -> Option<Self> {
        if self.board.black & self.board.white != 0
            || self.mode > 1
            || self.difficulty > 2
            || (self.board.black | self.board.white).count_ones() < 4
        {
            return None;
        }
        if self.board.legal(self.board.turn).is_empty() {
            self.board.turn = !self.board.turn;
        }
        self.rng |= 1;
        Some(self)
    }
    fn random(&mut self) -> u64 {
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 7;
        self.rng ^= self.rng << 17;
        self.rng
    }
    pub fn computer_move(&mut self) -> Option<usize> {
        let mut moves = self.board.legal(self.board.turn);
        if moves.is_empty() {
            return None;
        }
        if self.difficulty == 0 {
            return Some(moves[self.random() as usize % moves.len()]);
        }
        moves.sort_by_key(|&i| -square_weight(i));
        let depth = if self.difficulty == 1 { 2 } else { 4 };
        let side = self.board.turn;
        let mut best = (i32::MIN, moves[0]);
        // Equal budgets per root move avoid favoring whichever branch consumed a global budget.
        for i in moves {
            let mut next = self.board;
            next.play(i);
            let mut budget = 500;
            let score = search(next, side, depth - 1, -100_000, 100_000, &mut budget);
            if score > best.0 {
                best = (score, i);
            }
        }
        Some(best.1)
    }
}

fn square_weight(i: usize) -> i32 {
    let (x, y) = (i % 8, i / 8);
    if (x == 0 || x == 7) && (y == 0 || y == 7) {
        100
    } else if (x <= 1 || x >= 6) && (y <= 1 || y >= 6) {
        -25
    } else if x == 0 || x == 7 || y == 0 || y == 7 {
        8
    } else {
        1
    }
}
fn evaluate(b: Board, side: bool) -> i32 {
    let positional: i32 = (0..64)
        .map(|i| {
            let bit = 1 << i;
            if b.discs(side) & bit != 0 {
                square_weight(i)
            } else if b.discs(!side) & bit != 0 {
                -square_weight(i)
            } else {
                0
            }
        })
        .sum();
    positional + 5 * (b.legal(side).len() as i32 - b.legal(!side).len() as i32)
}
fn search(
    b: Board,
    side: bool,
    depth: usize,
    mut alpha: i32,
    mut beta: i32,
    budget: &mut usize,
) -> i32 {
    if b.finished() {
        let diff = b.count(side) as i32 - b.count(!side) as i32;
        return diff.signum() * 10_000 + diff;
    }
    if depth == 0 || *budget == 0 {
        return evaluate(b, side);
    }
    *budget -= 1;
    let mut moves = b.legal(b.turn);
    moves.sort_by_key(|&i| -square_weight(i));
    let maximizing = b.turn == side;
    let mut best = if maximizing { -100_000 } else { 100_000 };
    for i in moves {
        let mut next = b;
        next.play(i);
        let value = search(next, side, depth - 1, alpha, beta, budget);
        if maximizing {
            best = best.max(value);
            alpha = alpha.max(best);
        } else {
            best = best.min(value);
            beta = beta.min(best);
        }
        if beta <= alpha {
            break;
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn opening_and_illegal_moves() {
        let mut b = Board::default();
        assert_eq!(b.legal(true), [19, 26, 37, 44]);
        let old = b;
        assert_eq!(b.play(27), None);
        assert_eq!(b.play(64), None);
        assert_eq!(b, old);
        assert_eq!(b.play(19), Some(1 << 27));
        assert_eq!((b.count(true), b.count(false), b.turn), (4, 1, false));
    }
    #[test]
    fn captures_all_eight_directions_without_wrapping_edges() {
        let mut b = Board {
            black: 0,
            white: 0,
            turn: true,
        };
        for (dx, dy) in [
            (-1, -1),
            (0, -1),
            (1, -1),
            (-1, 0),
            (1, 0),
            (-1, 1),
            (0, 1),
            (1, 1),
        ] {
            b.white |= 1 << ((3 + dy) * 8 + 3 + dx);
            b.black |= 1 << ((3 + 2 * dy) * 8 + 3 + 2 * dx);
        }
        assert_eq!(b.play(27).unwrap().count_ones(), 8);
        let b = Board {
            black: 1 << 9,
            white: 1 << 8,
            turn: true,
        };
        assert_eq!(b.flips(7, true), 0);
    }
    #[test]
    fn forced_pass_and_early_finish() {
        let mut b = Board {
            black: u64::MAX & !((1 << 0) | (1 << 1) | (1 << 3) | (1 << 4)),
            white: (1 << 1) | (1 << 4),
            turn: true,
        };
        b.play(0).unwrap();
        assert!(b.turn, "white must pass");
        assert!(!b.finished());
        b.play(3).unwrap();
        assert!(b.finished());
        assert_eq!(b.count(true), 64);
        assert!(
            Board {
                black: 0b1111,
                white: 0,
                turn: true
            }
            .finished()
        );
    }
    #[test]
    fn seeded_games_terminate_and_conserve_discs() {
        for seed in 1..12 {
            let mut g = SaveState::new(0, 0, seed);
            for _ in 0..60 {
                let Some(i) = g.computer_move() else { break };
                let before = (g.board.black | g.board.white).count_ones();
                g.board.play(i).unwrap();
                assert_eq!(g.board.black & g.board.white, 0);
                assert_eq!((g.board.black | g.board.white).count_ones(), before + 1);
            }
            assert!(g.board.finished());
        }
    }
    #[test]
    fn save_roundtrip_and_validation() {
        let mut g = SaveState::new(1, 2, 15);
        g.board.play(19);
        let saved = serde_json::to_string(&g).unwrap();
        let restored = serde_json::from_str::<SaveState>(&saved)
            .unwrap()
            .apply_save()
            .unwrap();
        assert_eq!(g.board, restored.board);
        assert_eq!(
            (restored.mode, restored.difficulty, restored.rng),
            (1, 2, 15)
        );
        g.board.white |= g.board.black;
        assert!(g.apply_save().is_none());
    }
    #[test]
    fn opponents_choose_legal_moves_and_take_a_winning_corner() {
        for difficulty in 0..3 {
            let mut g = SaveState::new(0, difficulty, 15);
            let i = g.computer_move().unwrap();
            assert!(g.board.legal(true).contains(&i));
        }
        let mut g = SaveState::new(0, 2, 15);
        g.board = Board {
            black: 1 << 2,
            white: 1 << 1,
            turn: true,
        };
        assert_eq!(g.computer_move(), Some(0));
    }
}
