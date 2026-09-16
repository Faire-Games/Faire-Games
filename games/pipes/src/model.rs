//! A connected tree, scrambled by rotations. Any leak-free connected arrangement wins;
//! puzzles are guaranteed solvable, but we do not require a unique solution.
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

pub const SIZES: [usize; 3] = [5, 7, 9];
// Clockwise ports: north, east, south, west.
pub const PORTS: [u8; 4] = [1, 2, 4, 8];
pub fn rotate(mask: u8) -> u8 {
    ((mask << 1) | (mask >> 3)) & 15
}

pub fn neighbor(size: usize, i: usize, dir: usize) -> Option<usize> {
    let (x, y) = (i % size, i / size);
    match dir {
        0 if y > 0 => Some(i - size),
        1 if x + 1 < size => Some(i + 1),
        2 if y + 1 < size => Some(i + size),
        3 if x > 0 => Some(i - 1),
        _ => None,
    }
}
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}
/// Randomized depth-first spanning tree rooted at the center. No off-board ports or loops.
pub fn solution(size: usize, seed: u64) -> Vec<u8> {
    let mut rng = Rng(seed | 1);
    let mut tiles = vec![0; size * size];
    let mut seen = vec![false; tiles.len()];
    let root = tiles.len() / 2;
    seen[root] = true;
    let mut stack = vec![root];
    while let Some(&i) = stack.last() {
        let candidates: Vec<_> = (0..4)
            .filter_map(|dir| {
                neighbor(size, i, dir)
                    .filter(|&j| !seen[j])
                    .map(|j| (dir, j))
            })
            .collect();
        if candidates.is_empty() {
            stack.pop();
            continue;
        }
        // Reduce before converting: usize is 32-bit on WebAssembly and 64-bit on desktop.
        let (dir, j) = candidates[(rng.next() % candidates.len() as u64) as usize];
        tiles[i] |= PORTS[dir];
        tiles[j] |= PORTS[(dir + 2) % 4];
        seen[j] = true;
        stack.push(j);
    }
    tiles
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SaveState {
    pub size: usize,
    pub seed: u64,
    pub tiles: Vec<u8>,
    pub locked: Vec<bool>,
    pub moves: u32,
}
#[derive(Clone, Debug)]
pub struct Network {
    /// Distance from the source, also used to animate the completion wave.
    pub distance: Vec<Option<usize>>,
    pub connected: usize,
    pub leaks: usize,
}
impl Network {
    pub fn solved(&self) -> bool {
        self.connected == self.distance.len() && self.leaks == 0
    }
}
impl SaveState {
    pub fn new(size: usize, seed: u64) -> Self {
        assert!(SIZES.contains(&size));
        let mut rng = Rng((seed ^ 0x9e3779b97f4a7c15) | 1);
        let mut tiles = solution(size, seed);
        for tile in &mut tiles {
            for _ in 0..rng.next() % 4 {
                *tile = rotate(*tile);
            }
        }
        let mut board = Self {
            size,
            seed,
            locked: vec![false; tiles.len()],
            tiles,
            moves: 0,
        };
        // A rare scramble could already be solved. Rotate a non-cross tile in that case.
        if board.network().solved() {
            let i = board.tiles.iter().position(|&m| m != 15).unwrap();
            board.tiles[i] = rotate(board.tiles[i]);
        }
        board
    }
    pub fn save_state(&self) -> Self {
        self.clone()
    }
    pub fn apply_save(self) -> Option<Self> {
        if !SIZES.contains(&self.size)
            || self.tiles.len() != self.size * self.size
            || self.locked.len() != self.tiles.len()
        {
            return None;
        }
        // Validate each tile's shape against the seeded generator, not merely its port count.
        let original = solution(self.size, self.seed);
        for (&mask, mut expected) in self.tiles.iter().zip(original) {
            let mut matches = false;
            for _ in 0..4 {
                matches |= mask == expected;
                expected = rotate(expected);
            }
            if !matches {
                return None;
            }
        }
        Some(self)
    }
    pub fn turn(&mut self, i: usize) -> bool {
        if i >= self.tiles.len() || self.locked[i] || self.network().solved() {
            return false;
        }
        let next = rotate(self.tiles[i]);
        if next == self.tiles[i] {
            return false;
        }
        self.tiles[i] = next;
        self.moves = self.moves.saturating_add(1);
        true
    }
    pub fn toggle_lock(&mut self, i: usize) -> bool {
        if i >= self.tiles.len() || self.network().solved() {
            return false;
        }
        self.locked[i] = !self.locked[i];
        true
    }
    pub fn restart(&mut self) {
        *self = Self::new(self.size, self.seed);
    }
    pub fn network(&self) -> Network {
        let mut distance = vec![None; self.tiles.len()];
        let root = self.tiles.len() / 2;
        distance[root] = Some(0);
        let mut queue = VecDeque::from([root]);
        let mut connected = 0;
        while let Some(i) = queue.pop_front() {
            connected += 1;
            for dir in 0..4 {
                if self.tiles[i] & PORTS[dir] == 0 {
                    continue;
                }
                if let Some(j) = neighbor(self.size, i, dir)
                    && self.tiles[j] & PORTS[(dir + 2) % 4] != 0
                    && distance[j].is_none()
                {
                    distance[j] = Some(distance[i].unwrap() + 1);
                    queue.push_back(j);
                }
            }
        }
        let leaks = self
            .tiles
            .iter()
            .enumerate()
            .map(|(i, &mask)| {
                (0..4)
                    .filter(|&dir| {
                        mask & PORTS[dir] != 0
                            && neighbor(self.size, i, dir)
                                .is_none_or(|j| self.tiles[j] & PORTS[(dir + 2) % 4] == 0)
                    })
                    .count()
            })
            .sum();
        Network {
            distance,
            connected,
            leaks,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rotations_keep_ports_and_return_to_start() {
        assert_eq!([rotate(1), rotate(2), rotate(4), rotate(8)], [2, 4, 8, 1]);
        for mask in 1..16 {
            let mut m = mask;
            for _ in 0..4 {
                m = rotate(m);
                assert_eq!(m.count_ones(), mask.count_ones());
            }
            assert_eq!(m, mask);
        }
    }
    #[test]
    fn generation_is_solvable_nontrivial_and_deterministic() {
        for size in SIZES {
            for seed in 0..100 {
                let mut b = SaveState::new(size, seed);
                assert_eq!(b, SaveState::new(size, seed));
                assert!(!b.network().solved());
                assert_eq!(
                    b.tiles.iter().map(|m| m.count_ones()).sum::<u32>(),
                    2 * (size * size - 1) as u32
                );
                b.tiles = solution(size, seed);
                assert!(b.network().solved());
            }
        }
        assert_ne!(SaveState::new(5, 1).tiles, SaveState::new(5, 3).tiles);
    }
    #[test]
    fn ports_must_match_and_cannot_wrap() {
        let b = SaveState {
            size: 3,
            seed: 1,
            tiles: vec![0, 0, 2, 8, 2, 8, 0, 0, 0],
            locked: vec![false; 9],
            moves: 0,
        };
        assert_eq!(b.network().connected, 2);
        assert_eq!(b.network().leaks, 2);
        let mut b = b;
        b.tiles[5] = 2;
        assert_eq!(b.network().connected, 1);
        assert!(!b.network().solved());
    }
    #[test]
    fn locked_tiles_and_finished_boards_reject_moves() {
        let mut b = SaveState::new(5, 15);
        let i = b.tiles.iter().position(|&m| m != 15).unwrap();
        b.toggle_lock(i);
        let before = b.clone();
        assert!(!b.turn(i));
        assert_eq!(b, before);
        b.toggle_lock(i);
        assert!(b.turn(i));
        assert_eq!(b.moves, 1);
        assert!(!b.turn(usize::MAX));
        b.tiles = solution(b.size, b.seed);
        assert!(!b.turn(i));
        assert!(!b.toggle_lock(i));
    }
    #[test]
    fn restart_and_save_restore_preserve_the_puzzle() {
        let mut b = SaveState::new(7, 15);
        let original = b.clone();
        b.turn(0);
        b.toggle_lock(1);
        let json = serde_json::to_string(&b.save_state()).unwrap();
        assert_eq!(
            serde_json::from_str::<SaveState>(&json)
                .unwrap()
                .apply_save()
                .unwrap(),
            b
        );
        b.restart();
        assert_eq!(b, original);
        let mut bad = b.clone();
        bad.tiles.pop();
        assert!(bad.apply_save().is_none());
        let mut bad = b.clone();
        bad.locked.clear();
        assert!(bad.apply_save().is_none());
        let mut bad = b.clone();
        bad.tiles[0] = 0;
        assert!(bad.apply_save().is_none());
        b.size = usize::MAX;
        assert!(b.apply_save().is_none());
    }
    #[test]
    fn a_full_solution_can_be_reached_using_only_player_rotations() {
        let mut b = SaveState::new(5, 15);
        let solved = solution(b.size, b.seed);
        for (i, &want) in solved.iter().enumerate() {
            for _ in 0..4 {
                if b.tiles[i] == want {
                    break;
                }
                assert!(b.turn(i));
            }
            assert_eq!(b.tiles[i], want);
        }
        assert!(b.network().solved());
        // Shared with dayscript/pipes.yaml; keep this identical on 32- and 64-bit targets.
        assert_eq!(b.moves, 33);
    }
}
