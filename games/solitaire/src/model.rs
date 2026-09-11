//! Klondike: the deal, the rules and scoring, undo, the save format, and the solver behind
//! "winnable deals only".
//!
//! # The solver
//!
//! A deal is winnable when some line of play wins it with every card known (the "thoughtful"
//! game). The solver decides that the way Blake and Gent's Solvitaire does ("The Winnability of
//! Klondike Solitaire and Many Other Patience Games", JAIR 2025, arXiv:1906.12314), the most
//! complete study of the question:
//!
//! - **The stock as a pool.** Rather than searching every turn of the stock, a move may play any
//!   stock card that some number of turns would bring to the top of the waste. Turning one card
//!   at a time with unlimited passes, that is every card in it.
//! - **Depth-first search with a transposition table.** A position already explored is never
//!   explored again. The key is canonical: the columns are sorted before hashing, because a
//!   position with its columns in another order plays the same.
//! - **The paper's two proven dominances.** A card goes home automatically when no card that
//!   could still need it is out (at most two ranks above both foundations of the other color and
//!   three above the other one of its own), and part of a built run moves only to free the card
//!   beneath it for its foundation.
//! - **No worrying back** a foundation card that the first dominance would send straight home.
//! - **A streamlined first pass** that always plays to the foundations when it can, which finds
//!   most wins far sooner; only when it fails does the complete search run.
//! - **Restarts.** Depth-first search is heavy-tailed: one early wrong turn can cost more
//!   positions than the whole budget. A few short complete passes, each with the move order
//!   lightly shuffled, find most of the remaining wins before the long, unshuffled pass.
//!
//! A win the solver finds is replayed through [`Model`]'s own rules before the deal counts as
//! winnable, so a solver bug could cost a deal but never deal an unwinnable one. With every card
//! known, about 90% of draw-one deals and 82% of draw-three deals can be won (Blake and Gent).

use std::collections::HashSet;
use std::hash::{BuildHasherDefault, Hasher};

use serde::{Deserialize, Serialize};

/// Tableau columns.
pub const COLS: usize = 7;
/// Cards in the pack.
pub const DECK: usize = 52;
/// The most cards a column can hold: six face down under a full king-to-ace run.
const MAX_COL: usize = 19;
/// The most face-down cards a column starts with (and so can ever have).
const MAX_HIDDEN: usize = COLS - 1;
/// The most cards the stock and the waste hold between them.
const TALON: usize = 24;

/// Points, the classic scoring: a card from the waste to the tableau, any card to a foundation,
/// a tableau card turned face up, and a card taken back down from a foundation.
pub const SCORE_WASTE_TO_TABLEAU: i64 = 5;
pub const SCORE_TO_FOUNDATION: i64 = 10;
pub const SCORE_REVEAL: i64 = 5;
pub const SCORE_FOUNDATION_TO_TABLEAU: i64 = -15;
/// A win's time bonus is this divided by the seconds it took, for a game of at least
/// `TIME_BONUS_MIN_SECS`.
const TIME_BONUS: f64 = 700_000.0;
const TIME_BONUS_MIN_SECS: f64 = 30.0;
/// Undo reaches back this many moves.
const HISTORY: usize = 500;

/// The save format's one character per card.
const CODES: &[u8; DECK] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/// A card: `suit * 13 + rank - 1`. The suits alternate color, ♠ ♥ ♣ ♦, so `suit & 1` is red.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct Card(pub u8);

impl Card {
    pub const fn new(suit: u8, rank: u8) -> Card {
        Card(suit * 13 + rank - 1)
    }
    pub const fn suit(self) -> u8 {
        self.0 / 13
    }
    /// 1 (ace) through 13 (king).
    pub const fn rank(self) -> u8 {
        self.0 % 13 + 1
    }
    pub const fn red(self) -> bool {
        self.suit() & 1 == 1
    }
    /// Whether this card can sit on `under` in the tableau: one rank lower, the other color.
    pub const fn stacks_on(self, under: Card) -> bool {
        self.rank() + 1 == under.rank() && self.red() != under.red()
    }
    fn code(self) -> char {
        CODES[self.0 as usize] as char
    }
    fn from_code(b: u8) -> Option<Card> {
        CODES.iter().position(|&c| c == b).map(|i| Card(i as u8))
    }
}

/// How many cards a turn of the stock deals onto the waste.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub enum DrawMode {
    One,
    Three,
}

pub const DRAW_MODES: [DrawMode; 2] = [DrawMode::One, DrawMode::Three];

impl DrawMode {
    pub fn count(self) -> usize {
        match self {
            DrawMode::One => 1,
            DrawMode::Three => 3,
        }
    }
    /// A stable index for per-mode records.
    pub fn index(self) -> usize {
        match self {
            DrawMode::One => 0,
            DrawMode::Three => 1,
        }
    }
    /// What turning the waste back over costs.
    pub fn recycle_cost(self) -> i64 {
        match self {
            DrawMode::One => 100,
            DrawMode::Three => 20,
        }
    }
}

/// SplitMix64: the deal's shuffle, identical on every platform for a given seed.
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Rng {
        Rng(seed)
    }
    pub fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        mix(self.0)
    }
    pub fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
}

/// The SplitMix64 finalizer: spreads every input bit over the whole word.
fn mix(mut z: u64) -> u64 {
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// Somewhere a card can be.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Pile {
    Stock,
    Waste,
    Foundation(usize),
    Tableau(usize),
}

impl Pile {
    fn valid(self) -> bool {
        match self {
            Pile::Stock | Pile::Waste => true,
            Pile::Foundation(i) => i < 4,
            Pile::Tableau(i) => i < COLS,
        }
    }
}

/// One thing a player can do.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Move {
    /// Turn cards from the stock onto the waste, or the waste back over when the stock is empty.
    Draw,
    /// Move the top `count` cards of `from` onto `to`.
    Shift { from: Pile, count: usize, to: Pile },
}

/// What a move did, for the score, the effects and the haptics.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Outcome {
    /// The score's change, time bonus included.
    pub gain: i64,
    /// Cards turned from the stock.
    pub drew: usize,
    /// The waste went back over as the stock.
    pub recycled: bool,
    /// A tableau column's card turned face up.
    pub revealed: Option<(usize, Card)>,
    /// A card reached a foundation.
    pub homed: Option<Card>,
    /// That card was a king: its suit is complete.
    pub suit_done: bool,
    /// A tableau column left empty.
    pub emptied: Option<usize>,
    pub won: bool,
}

/// Where every card is.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct Table {
    pub tableau: [Vec<Card>; COLS],
    /// How many cards at the bottom of each column are face down.
    pub hidden: [usize; COLS],
    /// The stock, its top (the next card turned) last.
    pub stock: Vec<Card>,
    /// The waste, its top (the playable card) last.
    pub waste: Vec<Card>,
    pub foundations: [Vec<Card>; 4],
}

/// The order a dealer lays the tableau out: across the columns a row at a time, each row one
/// column shorter. Yields `(column, row)`.
pub fn deal_order() -> impl Iterator<Item = (usize, usize)> {
    (0..COLS).flat_map(|row| (row..COLS).map(move |col| (col, row)))
}

/// Turn up to `n` cards from the stock onto the waste, or turn the waste back over as the stock
/// when the stock is empty. Returns whether it turned the waste over.
fn turn(stock: &mut Vec<Card>, waste: &mut Vec<Card>, n: usize) -> bool {
    if stock.is_empty() {
        // The waste's first card turned is the stock's top again.
        stock.extend(waste.drain(..).rev());
        return true;
    }
    for _ in 0..n.min(stock.len()) {
        if let Some(c) = stock.pop() {
            waste.push(c);
        }
    }
    false
}

impl Table {
    /// A shuffled pack dealt out: a column of one to seven cards, only the last face up, and the
    /// rest in the stock.
    pub fn deal(seed: u64) -> Table {
        let mut deck: Vec<Card> = (0..DECK as u8).map(Card).collect();
        let mut rng = Rng::new(seed);
        for i in (1..DECK).rev() {
            deck.swap(i, rng.below(i + 1));
        }
        let mut t = Table::default();
        let mut cards = deck.into_iter();
        for (col, _) in deal_order() {
            if let Some(c) = cards.next() {
                t.tableau[col].push(c);
            }
        }
        for (col, hidden) in t.hidden.iter_mut().enumerate() {
            *hidden = col;
        }
        // The rest of the pack goes face down with its next card on top.
        t.stock = cards.rev().collect();
        t
    }

    pub fn pile(&self, p: Pile) -> &[Card] {
        match p {
            Pile::Stock => &self.stock,
            Pile::Waste => &self.waste,
            Pile::Foundation(i) => self.foundations.get(i).map_or(&[], |f| f.as_slice()),
            Pile::Tableau(i) => self.tableau.get(i).map_or(&[], |c| c.as_slice()),
        }
    }

    fn pile_mut(&mut self, p: Pile) -> &mut Vec<Card> {
        match p {
            Pile::Stock => &mut self.stock,
            Pile::Waste => &mut self.waste,
            Pile::Foundation(i) => &mut self.foundations[i],
            Pile::Tableau(i) => &mut self.tableau[i],
        }
    }

    /// Face-up cards in a column.
    pub fn face_up(&self, col: usize) -> usize {
        self.tableau[col].len() - self.hidden[col]
    }

    /// The foundation `card` can go on now: its suit's pile once one is started, otherwise the
    /// first empty one for an ace.
    pub fn foundation_slot(&self, card: Card) -> Option<usize> {
        let started = self
            .foundations
            .iter()
            .position(|f| f.first().is_some_and(|c| c.suit() == card.suit()));
        match started {
            Some(i) => {
                let top = self.foundations[i].last()?;
                (top.rank() + 1 == card.rank()).then_some(i)
            }
            None if card.rank() == 1 => self.foundations.iter().position(|f| f.is_empty()),
            None => None,
        }
    }

    pub fn won(&self) -> bool {
        self.foundations.iter().all(|f| f.len() == 13)
    }

    /// How many turns of the stock bring `card` to the top of the waste, if any number does.
    pub fn draws_to(&self, card: Card, mode: DrawMode) -> Option<usize> {
        if self.waste.last() == Some(&card) {
            return Some(0);
        }
        if !self.stock.contains(&card) && !self.waste.contains(&card) {
            return None;
        }
        let (mut stock, mut waste) = (self.stock.clone(), self.waste.clone());
        // Two whole passes show every card any number of turns can.
        for n in 1..=2 * (TALON + 2) {
            turn(&mut stock, &mut waste, mode.count());
            if waste.last() == Some(&card) {
                return Some(n);
            }
        }
        None
    }

    /// Every card exactly once, columns that could arise in play, and foundations that build up
    /// by suit from the ace.
    pub fn valid(&self) -> bool {
        let mut seen = [false; DECK];
        let all = self
            .tableau
            .iter()
            .flatten()
            .chain(&self.stock)
            .chain(&self.waste)
            .chain(self.foundations.iter().flatten());
        let mut count = 0;
        for c in all {
            if c.0 as usize >= DECK || seen[c.0 as usize] {
                return false;
            }
            seen[c.0 as usize] = true;
            count += 1;
        }
        if count != DECK || self.stock.len() + self.waste.len() > TALON {
            return false;
        }
        for (col, &hidden) in self.tableau.iter().zip(&self.hidden) {
            let bad_count = col.len() > MAX_COL || hidden > MAX_HIDDEN;
            let bad_face = if col.is_empty() {
                hidden != 0
            } else {
                hidden >= col.len()
            };
            if bad_count || bad_face || !col[hidden..].windows(2).all(|w| w[1].stacks_on(w[0])) {
                return false;
            }
        }
        let mut suits = [false; 4];
        for f in &self.foundations {
            let Some(first) = f.first() else {
                continue;
            };
            if suits[first.suit() as usize] {
                return false;
            }
            suits[first.suit() as usize] = true;
            if f.iter()
                .enumerate()
                .any(|(k, c)| c.suit() != first.suit() || c.rank() as usize != k + 1)
            {
                return false;
            }
        }
        true
    }

    /// The compact text form saves and undo history use.
    pub fn encode(&self) -> String {
        let codes = |cards: &[Card]| cards.iter().map(|c| c.code()).collect::<String>();
        let cols: Vec<String> = self
            .tableau
            .iter()
            .zip(&self.hidden)
            .map(|(col, &h)| format!("{h}{}", codes(col)))
            .collect();
        let found: Vec<String> = self.foundations.iter().map(|f| codes(f)).collect();
        format!(
            "{};{};{};{}",
            cols.join(","),
            codes(&self.stock),
            codes(&self.waste),
            found.join(",")
        )
    }

    /// The table [`Table::encode`] wrote, when it is a valid one.
    pub fn decode(s: &str) -> Option<Table> {
        let cards = |s: &str| -> Option<Vec<Card>> { s.bytes().map(Card::from_code).collect() };
        let parts: Vec<&str> = s.split(';').collect();
        let [cols, stock, waste, found] = parts.as_slice() else {
            return None;
        };
        let mut t = Table::default();
        let cols: Vec<&str> = cols.split(',').collect();
        if cols.len() != COLS {
            return None;
        }
        for (i, col) in cols.iter().enumerate() {
            let hidden = col.bytes().next()?.checked_sub(b'0')? as usize;
            t.hidden[i] = hidden;
            t.tableau[i] = cards(col.get(1..)?)?;
        }
        t.stock = cards(stock)?;
        t.waste = cards(waste)?;
        let found: Vec<&str> = found.split(',').collect();
        if found.len() != 4 {
            return None;
        }
        for (i, f) in found.iter().enumerate() {
            t.foundations[i] = cards(f)?;
        }
        t.valid().then_some(t)
    }
}

/// A position undo can return to.
#[derive(Clone, Debug, PartialEq)]
struct Snap {
    table: Table,
    score: i64,
    moves: u32,
    recycles: u32,
}

/// A game in progress.
#[derive(Clone, Debug)]
pub struct Model {
    pub table: Table,
    pub mode: DrawMode,
    pub score: i64,
    pub moves: u32,
    /// Seconds of play, counted from the first move.
    pub elapsed: f64,
    pub recycles: u32,
    pub won: bool,
    /// The deal was proven winnable before it was dealt.
    pub proven: bool,
    history: Vec<Snap>,
}

impl Model {
    pub fn new(mode: DrawMode, table: Table, proven: bool) -> Model {
        Model {
            won: table.won(),
            table,
            mode,
            score: 0,
            moves: 0,
            elapsed: 0.0,
            recycles: 0,
            proven,
            history: Vec::new(),
        }
    }

    /// Whether the clock runs: from the first move until the win.
    pub fn started(&self) -> bool {
        self.moves > 0 && !self.won
    }

    pub fn tick(&mut self, dt: f64) {
        if self.started() {
            self.elapsed += dt;
        }
    }

    pub fn can_draw(&self) -> bool {
        !self.won && !(self.table.stock.is_empty() && self.table.waste.is_empty())
    }

    /// The cards a shift of `count` from `from` would carry, when they may move together.
    pub fn run(&self, from: Pile, count: usize) -> Option<&[Card]> {
        if !from.valid() || count == 0 {
            return None;
        }
        let pile = self.table.pile(from);
        match from {
            Pile::Stock => None,
            Pile::Waste | Pile::Foundation(_) => {
                (count == 1 && !pile.is_empty()).then(|| &pile[pile.len() - 1..])
            }
            Pile::Tableau(c) => {
                if count > self.table.face_up(c) {
                    return None;
                }
                let run = &pile[pile.len() - count..];
                run.windows(2).all(|w| w[1].stacks_on(w[0])).then_some(run)
            }
        }
    }

    pub fn can_shift(&self, from: Pile, count: usize, to: Pile) -> bool {
        if self.won || from == to || !to.valid() {
            return false;
        }
        let Some(run) = self.run(from, count) else {
            return false;
        };
        let first = run[0];
        match to {
            Pile::Foundation(i) => {
                count == 1
                    && !matches!(from, Pile::Foundation(_))
                    && self.table.foundation_slot(first) == Some(i)
            }
            Pile::Tableau(c) => match self.table.tableau[c].last() {
                None => first.rank() == 13,
                Some(&top) => first.stacks_on(top),
            },
            Pile::Stock | Pile::Waste => false,
        }
    }

    pub fn legal(&self, m: Move) -> bool {
        match m {
            Move::Draw => self.can_draw(),
            Move::Shift { from, count, to } => self.can_shift(from, count, to),
        }
    }

    /// Make a move; `None` when it is not legal here.
    pub fn apply(&mut self, m: Move) -> Option<Outcome> {
        if !self.legal(m) {
            return None;
        }
        let snap = Snap {
            table: self.table.clone(),
            score: self.score,
            moves: self.moves,
            recycles: self.recycles,
        };
        let mut out = Outcome::default();
        match m {
            Move::Draw => {
                let before = self.table.waste.len();
                let t = &mut self.table;
                if turn(&mut t.stock, &mut t.waste, self.mode.count()) {
                    out.recycled = true;
                    self.recycles += 1;
                    out.gain = -self.mode.recycle_cost();
                } else {
                    out.drew = self.table.waste.len() - before;
                }
            }
            Move::Shift { from, count, to } => {
                let src = self.table.pile_mut(from);
                let at = src.len() - count;
                let run: Vec<Card> = src.drain(at..).collect();
                let first = run[0];
                self.table.pile_mut(to).extend(run);
                out.gain = match (from, to) {
                    (Pile::Waste, Pile::Tableau(_)) => SCORE_WASTE_TO_TABLEAU,
                    (_, Pile::Foundation(_)) => SCORE_TO_FOUNDATION,
                    (Pile::Foundation(_), Pile::Tableau(_)) => SCORE_FOUNDATION_TO_TABLEAU,
                    _ => 0,
                };
                if let Pile::Tableau(c) = from {
                    let len = self.table.tableau[c].len();
                    if len == 0 {
                        out.emptied = Some(c);
                    } else if self.table.hidden[c] == len {
                        self.table.hidden[c] -= 1;
                        out.revealed = Some((c, self.table.tableau[c][len - 1]));
                        out.gain += SCORE_REVEAL;
                    }
                }
                if let Pile::Foundation(_) = to {
                    out.homed = Some(first);
                    out.suit_done = first.rank() == 13;
                }
            }
        }
        // The score never goes below zero.
        out.gain = out.gain.max(-self.score);
        self.score += out.gain;
        self.moves += 1;
        self.history.push(snap);
        if self.history.len() > HISTORY {
            self.history.remove(0);
        }
        if self.table.won() {
            self.won = true;
            let bonus = self.time_bonus();
            self.score += bonus;
            out.gain += bonus;
            out.won = true;
        }
        Some(out)
    }

    /// The classic win bonus for the time taken.
    pub fn time_bonus(&self) -> i64 {
        if self.elapsed >= TIME_BONUS_MIN_SECS {
            (TIME_BONUS / self.elapsed) as i64
        } else {
            0
        }
    }

    pub fn can_undo(&self) -> bool {
        !self.won && !self.history.is_empty()
    }

    /// Take back the last move.
    pub fn undo(&mut self) -> bool {
        if !self.can_undo() {
            return false;
        }
        let Some(s) = self.history.pop() else {
            return false;
        };
        self.table = s.table;
        self.score = s.score;
        self.moves = s.moves;
        self.recycles = s.recycles;
        true
    }

    /// Where a tap sends the top `count` cards of `from`: home when a single card can go, else
    /// onto another column, an empty one only for a king that is not already heading one.
    pub fn best_target(&self, from: Pile, count: usize) -> Option<Pile> {
        if count == 1
            && let Some(&c) = self.table.pile(from).last()
            && let Some(slot) = self.table.foundation_slot(c)
            && self.can_shift(from, 1, Pile::Foundation(slot))
        {
            return Some(Pile::Foundation(slot));
        }
        let mut empty = None;
        for c in 0..COLS {
            let to = Pile::Tableau(c);
            if !self.can_shift(from, count, to) {
                continue;
            }
            if !self.table.tableau[c].is_empty() {
                return Some(to);
            }
            empty = empty.or(Some(to));
        }
        let bare_king = matches!(from, Pile::Tableau(c)
            if self.table.hidden[c] == 0 && self.table.tableau[c].len() == count);
        empty.filter(|_| !bare_king)
    }

    /// Nothing left to uncover or turn: every remaining card can go home in order.
    pub fn can_finish(&self) -> bool {
        !self.won
            && self.table.stock.is_empty()
            && self.table.waste.is_empty()
            && self.table.hidden.iter().all(|&h| h == 0)
    }

    /// The next card home while finishing: the lowest column top that can go.
    pub fn finish_move(&self) -> Option<Move> {
        (0..COLS)
            .filter_map(|c| {
                let card = *self.table.tableau[c].last()?;
                let slot = self.table.foundation_slot(card)?;
                Some((card.rank(), c, slot))
            })
            .min()
            .map(|(_, c, slot)| Move::Shift {
                from: Pile::Tableau(c),
                count: 1,
                to: Pile::Foundation(slot),
            })
    }

    /// No move can make progress: nothing goes home, no stock card can be played, and no
    /// column move uncovers anything. (Turning the stock over and over changes nothing.)
    pub fn stuck(&self) -> bool {
        !self.won && candidates(&SState::from_table(&self.table), self.mode, false, None).is_empty()
    }

    /// The move the solver's ordering likes best here, for a hint when no winning line is known.
    pub fn suggestion(&self) -> Option<Step> {
        candidates(&SState::from_table(&self.table), self.mode, false, None)
            .first()
            .copied()
    }

    /// The moves that carry out one solver step from here: turns of the stock until a stock card
    /// is on the waste, then the shift.
    pub fn moves_for(&self, step: Step) -> Option<Vec<Move>> {
        let t = &self.table;
        let shift = |from, count, to| Move::Shift { from, count, to };
        let from_talon = |card: Card, to: Pile| -> Option<Vec<Move>> {
            let n = t.draws_to(card, self.mode)?;
            let mut v = vec![Move::Draw; n];
            v.push(shift(Pile::Waste, 1, to));
            Some(v)
        };
        match step {
            Step::TalonHome(c) => {
                let card = Card(c);
                from_talon(card, Pile::Foundation(t.foundation_slot(card)?))
            }
            Step::TalonTo(c, col) => from_talon(Card(c), Pile::Tableau(col as usize)),
            Step::ColHome(col) => {
                let card = *t.tableau.get(col as usize)?.last()?;
                let slot = t.foundation_slot(card)?;
                Some(vec![shift(
                    Pile::Tableau(col as usize),
                    1,
                    Pile::Foundation(slot),
                )])
            }
            Step::ColTo { from, count, to } => Some(vec![shift(
                Pile::Tableau(from as usize),
                count as usize,
                Pile::Tableau(to as usize),
            )]),
            Step::HomeTo { suit, to } => {
                let slot = t
                    .foundations
                    .iter()
                    .position(|f| f.first().is_some_and(|c| c.suit() == suit))?;
                Some(vec![shift(
                    Pile::Foundation(slot),
                    1,
                    Pile::Tableau(to as usize),
                )])
            }
        }
    }

    pub fn save_state(&self) -> SaveState {
        SaveState {
            mode: self.mode,
            table: self.table.encode(),
            score: self.score,
            moves: self.moves,
            elapsed: self.elapsed,
            recycles: self.recycles,
            won: self.won,
            proven: self.proven,
            history: self
                .history
                .iter()
                .map(|s| (s.table.encode(), s.score, s.moves, s.recycles))
                .collect(),
        }
    }

    /// The game a save describes, when every position in it is a valid one.
    pub fn from_save(s: SaveState) -> Option<Model> {
        let table = Table::decode(&s.table)?;
        let mut history = Vec::with_capacity(s.history.len());
        for (t, score, moves, recycles) in s.history {
            history.push(Snap {
                table: Table::decode(&t)?,
                score,
                moves,
                recycles,
            });
        }
        let won = table.won();
        if won != s.won || s.score < 0 || !s.elapsed.is_finite() || s.elapsed < 0.0 {
            return None;
        }
        Some(Model {
            table,
            mode: s.mode,
            score: s.score,
            moves: s.moves,
            elapsed: s.elapsed,
            recycles: s.recycles,
            won,
            proven: s.proven,
            history,
        })
    }
}

/// A game as saved (gamekit): each position in [`Table::encode`]'s text form.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SaveState {
    pub mode: DrawMode,
    pub table: String,
    pub score: i64,
    pub moves: u32,
    pub elapsed: f64,
    pub recycles: u32,
    pub won: bool,
    pub proven: bool,
    /// Undo's positions: table, score, moves, recycles.
    pub history: Vec<(String, i64, u32, u32)>,
}

// ---------------------------------------------------------------------------------------------
// The solver.

fn rank(c: u8) -> u8 {
    c % 13 + 1
}

fn suit(c: u8) -> usize {
    (c / 13) as usize
}

fn red(c: u8) -> bool {
    suit(c) & 1 == 1
}

fn stacks(c: u8, under: u8) -> bool {
    rank(c) + 1 == rank(under) && red(c) != red(under)
}

const FNV_OFFSET: u64 = 0xCBF2_9CE4_8422_2325;
const FNV_PRIME: u64 = 0x0100_0000_01B3;

/// A column for the search: fixed storage, so a position copies without allocating.
#[derive(Clone, Copy)]
struct SCol {
    cards: [u8; MAX_COL],
    len: u8,
    hidden: u8,
}

impl SCol {
    const EMPTY: SCol = SCol {
        cards: [0; MAX_COL],
        len: 0,
        hidden: 0,
    };

    fn top(&self) -> Option<u8> {
        (self.len > 0).then(|| self.cards[self.len as usize - 1])
    }

    fn up(&self) -> usize {
        (self.len - self.hidden) as usize
    }

    fn push(&mut self, c: u8) {
        if (self.len as usize) < MAX_COL {
            self.cards[self.len as usize] = c;
            self.len += 1;
        }
    }

    /// Turn the top card up when the cards over it have gone.
    fn settle(&mut self) {
        if self.len > 0 && self.hidden == self.len {
            self.hidden -= 1;
        }
    }

    fn key(&self) -> u64 {
        let mut h = FNV_OFFSET ^ ((self.hidden as u64) << 8 | self.len as u64);
        for &c in &self.cards[..self.len as usize] {
            h = (h ^ c as u64).wrapping_mul(FNV_PRIME);
        }
        mix(h)
    }
}

/// A position for the search. The stock and waste are one sequence in the order the stock
/// turns them up: the waste is `talon[..w]`, its top at `w - 1`, and the stock follows.
#[derive(Clone, Copy)]
struct SState {
    cols: [SCol; COLS],
    /// Each suit's foundation height, by suit.
    found: [u8; 4],
    talon: [u8; TALON],
    tlen: u8,
    w: u8,
}

impl SState {
    fn from_table(t: &Table) -> SState {
        let mut s = SState {
            cols: [SCol::EMPTY; COLS],
            found: [0; 4],
            talon: [0; TALON],
            tlen: 0,
            w: t.waste.len().min(TALON) as u8,
        };
        for (col, (cards, &hidden)) in s.cols.iter_mut().zip(t.tableau.iter().zip(&t.hidden)) {
            for c in cards {
                col.push(c.0);
            }
            col.hidden = hidden.min(col.len as usize) as u8;
        }
        for f in &t.foundations {
            if let Some(top) = f.last() {
                s.found[top.suit() as usize] = top.rank();
            }
        }
        for c in t.waste.iter().chain(t.stock.iter().rev()).take(TALON) {
            s.talon[s.tlen as usize] = c.0;
            s.tlen += 1;
        }
        s
    }

    fn won(&self) -> bool {
        self.found == [13; 4]
    }

    fn homes(&self, c: u8) -> bool {
        self.found[suit(c)] + 1 == rank(c)
    }

    /// Blake and Gent's first dominance: nothing still out could need this card, so sending it
    /// home can never be a mistake. At most two ranks above both foundations of the other color
    /// and three above the other foundation of its own.
    fn safe(&self, c: u8) -> bool {
        let (r, s) = (rank(c), suit(c));
        r <= 2 || (r <= self.found[s ^ 1].min(self.found[s ^ 3]) + 2 && r <= self.found[s ^ 2] + 3)
    }

    /// Positions in the talon some number of turns brings to the top of the waste, as a mask.
    fn reach(&self, mode: DrawMode) -> u32 {
        let len = self.tlen as usize;
        if mode == DrawMode::One {
            return (1u32 << len) - 1;
        }
        let w = self.w as usize;
        let mut m = 0u32;
        if w > 0 {
            m |= 1 << (w - 1);
        }
        let mut p = w;
        while p < len {
            p = (p + 3).min(len);
            m |= 1 << (p - 1);
        }
        // After turning the waste back over, the passes start again from the first card.
        let mut p = 0;
        while p < len {
            p = (p + 3).min(len);
            m |= 1 << (p - 1);
        }
        m
    }

    /// Play a talon card: turn to it, then take it, leaving the waste below it.
    fn take_talon(&mut self, c: u8) {
        let len = self.tlen as usize;
        if let Some(p) = self.talon[..len].iter().position(|&x| x == c) {
            self.talon.copy_within(p + 1..len, p);
            self.tlen -= 1;
            self.w = p as u8;
        }
    }

    fn apply(&mut self, step: Step) {
        match step {
            Step::TalonHome(c) => {
                self.take_talon(c);
                self.found[suit(c)] += 1;
            }
            Step::TalonTo(c, to) => {
                self.take_talon(c);
                self.cols[to as usize].push(c);
            }
            Step::ColHome(i) => {
                let col = &mut self.cols[i as usize];
                if let Some(c) = col.top() {
                    col.len -= 1;
                    col.settle();
                    self.found[suit(c)] += 1;
                }
            }
            Step::ColTo { from, count, to } => {
                let (f, t) = (from as usize, to as usize);
                let start = self.cols[f].len as usize - count as usize;
                for k in start..self.cols[f].len as usize {
                    let c = self.cols[f].cards[k];
                    self.cols[t].push(c);
                }
                self.cols[f].len -= count;
                self.cols[f].settle();
            }
            Step::HomeTo { suit: s, to } => {
                let s = s as usize;
                let c = s as u8 * 13 + self.found[s] - 1;
                self.found[s] -= 1;
                self.cols[to as usize].push(c);
            }
        }
    }

    /// The transposition table's key. Columns are sorted first: the same position with its
    /// columns in another order is the same position. Turning one at a time, every stock card
    /// is always reachable, so only which cards remain matters, not their order.
    fn key(&self, mode: DrawMode) -> u64 {
        let mut cols: [u64; COLS] = std::array::from_fn(|i| self.cols[i].key());
        cols.sort_unstable();
        let mut h = FNV_OFFSET;
        for c in cols {
            h = mix(h ^ c);
        }
        h ^= mix(u64::from_le_bytes([
            self.found[0],
            self.found[1],
            self.found[2],
            self.found[3],
            1,
            0,
            0,
            0,
        ]))
        .rotate_left(17);
        let talon = &self.talon[..self.tlen as usize];
        let t = match mode {
            DrawMode::One => talon.iter().fold(0u64, |m, &c| m | 1 << c),
            DrawMode::Three => talon.iter().fold(FNV_OFFSET ^ self.w as u64, |h, &c| {
                (h ^ c as u64).wrapping_mul(FNV_PRIME)
            }),
        };
        h ^ mix(t ^ 0xA5A5_5A5A_C3C3_3C3C).rotate_left(31)
    }
}

/// One move of the search, in the order it names cards and columns. A talon step names its
/// card; [`Model::moves_for`] works out the turns of the stock it takes.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Step {
    TalonHome(u8),
    TalonTo(u8, u8),
    ColHome(u8),
    ColTo { from: u8, count: u8, to: u8 },
    HomeTo { suit: u8, to: u8 },
}

/// Send every safe card home (the first dominance), recording each as a step.
fn auto_home(s: &mut SState, mode: DrawMode, path: &mut Vec<Step>) {
    loop {
        let mut moved = false;
        for i in 0..COLS {
            if let Some(c) = s.cols[i].top()
                && s.homes(c)
                && s.safe(c)
            {
                s.apply(Step::ColHome(i as u8));
                path.push(Step::ColHome(i as u8));
                moved = true;
            }
        }
        // Only turning one at a time does the stock work like a reserve the dominance holds for.
        if mode == DrawMode::One {
            let mut i = 0;
            while i < s.tlen as usize {
                let c = s.talon[i];
                if s.homes(c) && s.safe(c) {
                    s.apply(Step::TalonHome(c));
                    path.push(Step::TalonHome(c));
                    moved = true;
                } else {
                    i += 1;
                }
            }
        }
        if !moved {
            break;
        }
    }
}

/// How far a restart's shuffle can lift a move past a better-rated one.
const JITTER: usize = 160;

/// Every move worth searching from `s`, most promising first. `streamline` keeps only the
/// foundation moves whenever there are any (the streamlined pass); `jitter` shuffles the order a
/// little (a restart).
fn candidates(s: &SState, mode: DrawMode, streamline: bool, jitter: Option<&mut Rng>) -> Vec<Step> {
    let mut out: Vec<(i32, Step)> = Vec::with_capacity(24);
    let first_empty = s.cols.iter().position(|c| c.len == 0);
    for (i, col) in s.cols.iter().enumerate() {
        if let Some(c) = col.top()
            && s.homes(c)
        {
            let reveals = col.hidden > 0 && col.up() == 1;
            let prio = if reveals {
                900 + 10 * col.hidden as i32
            } else {
                700
            };
            out.push((prio, Step::ColHome(i as u8)));
        }
    }
    let reach = s.reach(mode);
    let talon: Vec<u8> = (0..s.tlen as usize)
        .filter(|&p| reach & (1 << p) != 0)
        .map(|p| s.talon[p])
        .collect();
    for &c in &talon {
        if s.homes(c) {
            out.push((650, Step::TalonHome(c)));
        }
    }
    if streamline && !out.is_empty() {
        out.sort_by_key(|&(p, _)| std::cmp::Reverse(p));
        return out.into_iter().map(|(_, m)| m).collect();
    }
    for &c in &talon {
        for (i, col) in s.cols.iter().enumerate() {
            match col.top() {
                Some(top) if stacks(c, top) => out.push((500, Step::TalonTo(c, i as u8))),
                // Empty columns are interchangeable: only the first is tried.
                None if rank(c) == 13 && first_empty == Some(i) => {
                    out.push((450, Step::TalonTo(c, i as u8)))
                }
                _ => {}
            }
        }
    }
    for (from, col) in s.cols.iter().enumerate() {
        let (len, up) = (col.len as usize, col.up());
        for count in 1..=up {
            let start = len - count;
            let base = col.cards[start];
            let whole = count == up;
            // The second dominance: split a run only to free the card beneath it for home.
            if !whole && !s.homes(col.cards[start - 1]) {
                continue;
            }
            for (to, dest) in s.cols.iter().enumerate() {
                if to == from {
                    continue;
                }
                match dest.top() {
                    Some(top) if stacks(base, top) => {}
                    // A king already heading an otherwise empty column gains nothing by moving.
                    None if rank(base) == 13
                        && first_empty == Some(to)
                        && !(whole && col.hidden == 0) => {}
                    _ => continue,
                }
                let prio = if whole && col.hidden > 0 {
                    800 + 10 * col.hidden as i32
                } else if whole {
                    250
                } else {
                    400
                };
                out.push((
                    prio,
                    Step::ColTo {
                        from: from as u8,
                        count: count as u8,
                        to: to as u8,
                    },
                ));
            }
        }
    }
    // Worrying back: a card down from its foundation, unless the first dominance would send it
    // straight home again.
    for (su, &f) in s.found.iter().enumerate() {
        if f == 0 {
            continue;
        }
        let c = su as u8 * 13 + f - 1;
        if s.safe(c) {
            continue;
        }
        for (to, dest) in s.cols.iter().enumerate() {
            match dest.top() {
                Some(top) if stacks(c, top) => {}
                None if f == 13 && first_empty == Some(to) => {}
                _ => continue,
            }
            out.push((
                60,
                Step::HomeTo {
                    suit: su as u8,
                    to: to as u8,
                },
            ));
        }
    }
    if let Some(rng) = jitter {
        for (p, _) in out.iter_mut() {
            *p += rng.below(JITTER) as i32;
        }
    }
    out.sort_by_key(|&(p, _)| std::cmp::Reverse(p));
    out.into_iter().map(|(_, m)| m).collect()
}

/// The transposition table hashes its already-mixed keys as they are.
#[derive(Default)]
struct KeyHasher(u64);

impl Hasher for KeyHasher {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = self.0.rotate_left(8) ^ b as u64;
        }
    }
    fn write_u64(&mut self, n: u64) {
        self.0 = n;
    }
}

type Seen = HashSet<u64, BuildHasherDefault<KeyHasher>>;

/// How many distinct positions each pass may explore before the next one starts. A zero skips
/// that pass.
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    /// The streamlined pass.
    pub streamlined: u64,
    /// Each restart, and how many restarts there are.
    pub restart: u64,
    pub restarts: u32,
    /// The last, unshuffled complete search.
    pub full: u64,
}

/// For proving a new deal winnable: a deal that needs more than this is passed over.
/// Many short restarts prove the most deals for the work (measured over 500 random deals of each
/// kind: about 85% of draw-one and 76% of draw-three deals, around 7 ms a deal in a release build).
pub const DEAL_LIMITS: Limits = Limits {
    streamlined: 3_000,
    restart: 2_000,
    restarts: 20,
    full: 10_000,
};

/// For a hint from the current position: the long last pass is what can prove a position lost.
pub const HINT_LIMITS: Limits = Limits {
    streamlined: 2_000,
    restart: 2_000,
    restarts: 8,
    full: 25_000,
};

/// A pass of the search.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Phase {
    /// Foundation moves only, whenever there are any: fast, but it can miss a win.
    Streamlined,
    /// Every move, in a lightly shuffled order.
    Restart(u32),
    /// Every move, in the plain order.
    Full,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Verdict {
    /// A winning line, auto-moves included.
    Winnable(Vec<Step>),
    /// Every line was searched and none wins.
    Unwinnable,
    /// The limits ran out first.
    Unknown,
}

struct Frame {
    state: SState,
    moves: Vec<Step>,
    next: usize,
    /// The path's length before the steps that led here.
    base: usize,
}

/// A resumable depth-first search, so a caller can spread it over frames: [`Solver::run`] does
/// a bounded amount of work and picks up where it stopped.
pub struct Solver {
    mode: DrawMode,
    root: SState,
    root_path: Vec<Step>,
    stack: Vec<Frame>,
    path: Vec<Step>,
    seen: Seen,
    nodes: u64,
    limits: Limits,
    phase: Phase,
    /// The restarts' shuffle, seeded from the position so a search always runs the same.
    rng: Rng,
    verdict: Option<Verdict>,
    /// Positions expanded so far, over every pass.
    pub work: u64,
}

impl Solver {
    pub fn new(table: &Table, mode: DrawMode, limits: Limits) -> Solver {
        let mut root = SState::from_table(table);
        let mut root_path = Vec::new();
        auto_home(&mut root, mode, &mut root_path);
        let mut s = Solver {
            mode,
            root,
            root_path,
            stack: Vec::new(),
            path: Vec::new(),
            seen: Seen::default(),
            nodes: 0,
            limits,
            phase: Phase::Streamlined,
            rng: Rng::new(root.key(mode)),
            verdict: None,
            work: 0,
        };
        if root.won() {
            s.verdict = Some(Verdict::Winnable(s.root_path.clone()));
        } else if s.cap() > 0 {
            s.begin(Phase::Streamlined);
        } else if !s.next_phase() {
            s.verdict = Some(Verdict::Unknown);
        }
        s
    }

    fn cap_of(&self, phase: Phase) -> u64 {
        match phase {
            Phase::Streamlined => self.limits.streamlined,
            Phase::Restart(i) if i < self.limits.restarts => self.limits.restart,
            Phase::Restart(_) => 0,
            Phase::Full => self.limits.full,
        }
    }

    fn cap(&self) -> u64 {
        self.cap_of(self.phase)
    }

    /// Start `phase` from the top.
    fn begin(&mut self, phase: Phase) {
        self.phase = phase;
        self.seen.clear();
        self.nodes = 0;
        self.path = self.root_path.clone();
        self.stack.clear();
        self.seen.insert(self.root.key(self.mode));
        let root = self.root;
        let moves = self.moves_at(&root);
        self.stack.push(Frame {
            state: root,
            moves,
            next: 0,
            base: self.path.len(),
        });
    }

    /// Go on to the next pass with any room; false when none is left.
    fn next_phase(&mut self) -> bool {
        let mut p = self.phase;
        loop {
            p = match p {
                Phase::Streamlined => Phase::Restart(0),
                Phase::Restart(i) if i + 1 < self.limits.restarts => Phase::Restart(i + 1),
                Phase::Restart(_) => Phase::Full,
                Phase::Full => return false,
            };
            if self.cap_of(p) > 0 {
                self.begin(p);
                return true;
            }
        }
    }

    fn moves_at(&mut self, s: &SState) -> Vec<Step> {
        match self.phase {
            Phase::Streamlined => candidates(s, self.mode, true, None),
            Phase::Restart(_) => candidates(s, self.mode, false, Some(&mut self.rng)),
            Phase::Full => candidates(s, self.mode, false, None),
        }
    }

    /// Expand up to `budget` positions; the verdict once there is one.
    pub fn run(&mut self, budget: u64) -> Option<&Verdict> {
        let mut spent = 0u64;
        while self.verdict.is_none() && spent < budget {
            let Some(top) = self.stack.last_mut() else {
                // Every line from the start is spent. That proves the deal lost, unless the pass
                // only tried foundation moves.
                if self.phase != Phase::Streamlined {
                    self.verdict = Some(Verdict::Unwinnable);
                    break;
                }
                if self.next_phase() {
                    continue;
                }
                self.verdict = Some(Verdict::Unknown);
                break;
            };
            if top.next == top.moves.len() {
                let base = top.base;
                self.stack.pop();
                self.path.truncate(base);
                continue;
            }
            let step = top.moves[top.next];
            top.next += 1;
            let mut s = top.state;
            let base = self.path.len();
            s.apply(step);
            self.path.push(step);
            auto_home(&mut s, self.mode, &mut self.path);
            spent += 1;
            self.work += 1;
            if s.won() {
                self.verdict = Some(Verdict::Winnable(self.path.clone()));
                break;
            }
            if !self.seen.insert(s.key(self.mode)) {
                self.path.truncate(base);
                continue;
            }
            self.nodes += 1;
            if self.nodes >= self.cap() {
                if self.next_phase() {
                    continue;
                }
                self.verdict = Some(Verdict::Unknown);
                break;
            }
            let moves = self.moves_at(&s);
            self.stack.push(Frame {
                state: s,
                moves,
                next: 0,
                base,
            });
        }
        self.verdict.as_ref()
    }
}

/// Play `steps` through the game's own rules from `table`; true when they win it.
pub fn replays_to_win(table: &Table, mode: DrawMode, steps: &[Step]) -> bool {
    let mut m = Model::new(mode, table.clone(), false);
    for &step in steps {
        let Some(moves) = m.moves_for(step) else {
            return false;
        };
        for mv in moves {
            if m.apply(mv).is_none() {
                return false;
            }
        }
    }
    m.won
}

/// Candidate deals tried before settling for one that is not proven.
const MAX_TRIES: u32 = 300;

/// The hunt for a winnable deal, resumable like [`Solver`]: shuffle, prove, and shuffle again
/// until a deal's winning line replays.
pub struct DealSearch {
    rng: Rng,
    mode: DrawMode,
    current: Option<(Table, Solver)>,
    /// Deals shuffled so far.
    pub tried: u32,
}

impl DealSearch {
    pub fn new(seed: u64, mode: DrawMode) -> DealSearch {
        DealSearch {
            rng: Rng::new(seed),
            mode,
            current: None,
            tried: 0,
        }
    }

    /// Search for up to `budget` positions. Returns the deal once one is proven winnable (with
    /// `true`) or, after [`MAX_TRIES`] deals, the next one unproven (with `false`).
    pub fn step(&mut self, budget: u64) -> Option<(Table, bool)> {
        let mut left = budget;
        loop {
            if self.current.is_none() {
                if self.tried >= MAX_TRIES {
                    return Some((Table::deal(self.rng.next()), false));
                }
                self.tried += 1;
                let table = Table::deal(self.rng.next());
                let solver = Solver::new(&table, self.mode, DEAL_LIMITS);
                self.current = Some((table, solver));
            }
            let (table, solver) = self.current.as_mut()?;
            let before = solver.work;
            let verdict = solver.run(left).cloned();
            left = left.saturating_sub(solver.work - before);
            match verdict {
                Some(Verdict::Winnable(path)) => {
                    let table = table.clone();
                    self.current = None;
                    if replays_to_win(&table, self.mode, &path) {
                        return Some((table, true));
                    }
                }
                Some(_) => self.current = None,
                None => return None,
            }
            if left == 0 {
                return None;
            }
        }
    }

    /// Run to the end at once.
    #[cfg(test)]
    pub fn finish(&mut self) -> (Table, bool) {
        loop {
            if let Some(found) = self.step(u64::MAX) {
                return found;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// "AS" is the ace of spades, "TH" the ten of hearts.
    fn c(s: &str) -> Card {
        let b = s.as_bytes();
        let rank = match b[0] {
            b'A' => 1,
            b'T' => 10,
            b'J' => 11,
            b'Q' => 12,
            b'K' => 13,
            d => d - b'0',
        };
        let suit = match b[1] {
            b'S' => 0,
            b'H' => 1,
            b'C' => 2,
            _ => 3,
        };
        Card::new(suit, rank)
    }

    fn cards(spec: &str) -> Vec<Card> {
        spec.split_whitespace().map(c).collect()
    }

    /// A table with every card home except those placed. A suit is home up to its lowest card
    /// placed, so a fixture places every card of a suit above that one somewhere.
    fn endgame(tableau: [(&str, usize); COLS], stock: &str, waste: &str) -> Table {
        let mut t = Table::default();
        let mut placed = Vec::new();
        for (i, (spec, hidden)) in tableau.iter().enumerate() {
            t.tableau[i] = cards(spec);
            t.hidden[i] = *hidden;
            placed.extend(t.tableau[i].iter().copied());
        }
        t.stock = cards(stock);
        t.waste = cards(waste);
        placed.extend(t.stock.iter().chain(&t.waste).copied());
        for s in 0..4u8 {
            // A suit is home up to its lowest card still out.
            let low = placed
                .iter()
                .filter(|c| c.suit() == s)
                .map(|c| c.rank())
                .min()
                .unwrap_or(14);
            t.foundations[s as usize] = (1..low).map(|r| Card::new(s, r)).collect();
        }
        assert!(t.valid(), "the fixture is a real position: {t:?}");
        t
    }

    #[test]
    fn a_deal_lays_out_the_classic_tableau() {
        let t = Table::deal(42);
        for col in 0..COLS {
            assert_eq!(t.tableau[col].len(), col + 1);
            assert_eq!(t.hidden[col], col, "only the last card is face up");
        }
        assert_eq!(t.stock.len(), 24);
        assert!(t.waste.is_empty() && t.valid());
        assert_eq!(t, Table::deal(42), "a seed always deals the same");
        assert_ne!(t, Table::deal(43));
    }

    #[test]
    fn the_tableau_builds_down_in_alternating_colors_and_a_king_takes_an_empty_column() {
        let t = endgame(
            [
                ("KS", 0),
                ("QH", 0),
                ("QC", 0),
                ("JD", 0),
                ("", 0),
                ("", 0),
                ("", 0),
            ],
            "KC QD KD",
            "KH",
        );
        let m = Model::new(DrawMode::One, t, false);
        let (t0, t1, t2, t3, t4) = (
            Pile::Tableau(0),
            Pile::Tableau(1),
            Pile::Tableau(2),
            Pile::Tableau(3),
            Pile::Tableau(4),
        );
        assert!(m.can_shift(t1, 1, t0), "a red queen on a black king");
        assert!(!m.can_shift(t2, 1, t0), "not a black queen on a black king");
        assert!(m.can_shift(t3, 1, t2), "a red jack on a black queen");
        assert!(!m.can_shift(t3, 1, t0), "not two ranks down");
        assert!(m.can_shift(Pile::Waste, 1, t4), "a king to an empty column");
        assert!(!m.can_shift(t1, 1, t4), "a queen may not");
        assert!(!m.can_shift(Pile::Stock, 1, t4), "the stock only turns");
    }

    #[test]
    fn foundations_build_up_by_suit_from_the_ace() {
        let mut t = Table::deal(7);
        let ace = c("AH");
        // Put the ace of hearts on the waste, wherever the deal left it.
        for col in t.tableau.iter_mut() {
            col.retain(|&x| x != ace);
        }
        t.stock.retain(|&x| x != ace);
        for (col, h) in t.tableau.iter().zip(t.hidden.iter_mut()) {
            *h = (*h).min(col.len().saturating_sub(1));
        }
        t.waste.push(ace);
        let mut m = Model::new(DrawMode::One, t, false);
        assert_eq!(m.table.foundation_slot(ace), Some(0));
        assert_eq!(
            m.table.foundation_slot(c("2H")),
            None,
            "a two needs its ace"
        );
        let out = m
            .apply(Move::Shift {
                from: Pile::Waste,
                count: 1,
                to: Pile::Foundation(0),
            })
            .expect("the ace goes home");
        assert_eq!(out.homed, Some(ace));
        assert_eq!(m.score, SCORE_TO_FOUNDATION);
        assert_eq!(m.table.foundation_slot(c("2H")), Some(0));
        assert_eq!(m.table.foundation_slot(c("2S")), None);
        assert_eq!(
            m.table.foundation_slot(c("AS")),
            Some(1),
            "the next empty pile"
        );
    }

    #[test]
    fn draw_three_turns_three_and_recycles_in_the_same_order() {
        let mut t = Table::deal(3);
        let order: Vec<Card> = t.stock.iter().rev().copied().collect();
        t.waste.clear();
        let mut m = Model::new(DrawMode::Three, t, false);
        let out = m.apply(Move::Draw).unwrap();
        assert_eq!(out.drew, 3);
        assert_eq!(m.table.waste, order[..3].to_vec());
        assert_eq!(
            m.table.waste.last(),
            Some(&order[2]),
            "the third card is on top"
        );
        for _ in 0..7 {
            m.apply(Move::Draw).unwrap();
        }
        assert!(m.table.stock.is_empty());
        m.score = 50;
        let out = m.apply(Move::Draw).unwrap();
        assert!(out.recycled);
        assert_eq!(m.score, 30, "turning the waste over costs 20 in draw three");
        m.apply(Move::Draw).unwrap();
        assert_eq!(
            m.table.waste,
            order[..3].to_vec(),
            "the same cards come up again"
        );
        // In draw one it costs 100, and never takes the score below zero.
        let mut one = Model::new(DrawMode::One, Table::deal(3), false);
        for _ in 0..24 {
            one.apply(Move::Draw).unwrap();
        }
        one.score = 40;
        assert_eq!(one.apply(Move::Draw).unwrap().gain, -40);
        assert_eq!(one.score, 0);
    }

    #[test]
    fn moving_off_a_face_down_card_turns_it_up_and_scores() {
        let t = endgame(
            [
                ("9C 8H", 1),
                ("9S", 0),
                ("", 0),
                ("", 0),
                ("", 0),
                ("", 0),
                ("", 0),
            ],
            "TS JS QS KS TC JC QC KC 9H TH JH QH KH",
            "",
        );
        let mut m = Model::new(DrawMode::One, t, false);
        let out = m
            .apply(Move::Shift {
                from: Pile::Tableau(0),
                count: 1,
                to: Pile::Tableau(1),
            })
            .expect("the eight of hearts goes on the nine of spades");
        assert_eq!(out.revealed, Some((0, c("9C"))));
        assert_eq!(m.table.hidden[0], 0);
        assert_eq!(m.score, SCORE_REVEAL);
        assert!(m.undo());
        assert_eq!(m.table.hidden[0], 1, "undo turns it back down");
        assert_eq!(m.score, 0);
        assert!(!m.undo(), "nothing more to undo");
    }

    #[test]
    fn a_save_round_trips_and_a_tampered_one_is_refused() {
        let mut m = Model::new(DrawMode::Three, Table::deal(11), true);
        m.apply(Move::Draw).unwrap();
        m.apply(Move::Draw).unwrap();
        m.elapsed = 12.5;
        let s = m.save_state();
        let back = Model::from_save(s.clone()).expect("a save loads");
        assert_eq!(back.table, m.table);
        assert_eq!(
            (back.score, back.moves, back.mode),
            (m.score, m.moves, m.mode)
        );
        assert_eq!(back.history, m.history);
        let mut dup = s.clone();
        dup.table = dup.table.replacen('A', "B", 1);
        assert!(Model::from_save(dup).is_none(), "a card twice is refused");
        let mut bad = s;
        bad.table = "junk".into();
        assert!(Model::from_save(bad).is_none());
    }

    #[test]
    fn a_position_with_nothing_to_play_is_stuck() {
        // Only spades are left and spades never stack on spades. The ace is buried under the
        // king, every column is taken, and the red and club kings have no empty column to go to.
        let stuck = endgame(
            [
                ("AS KS", 1),
                ("2S", 0),
                ("3S", 0),
                ("4S", 0),
                ("5S", 0),
                ("6S", 0),
                ("7S", 0),
            ],
            "8S 9S TS JS QS",
            "",
        );
        let m = Model::new(DrawMode::One, stuck.clone(), false);
        assert!(m.stuck());
        assert_eq!(exhaustive(&stuck, DrawMode::One, 20_000), Some(false));
        assert_eq!(
            Solver::new(&stuck, DrawMode::One, DEAL_LIMITS)
                .run(u64::MAX)
                .cloned(),
            Some(Verdict::Unwinnable)
        );
        // With a column free, the king moves over and the ace comes up.
        let live = endgame(
            [
                ("AS KS", 1),
                ("2S", 0),
                ("3S", 0),
                ("4S", 0),
                ("5S", 0),
                ("6S", 0),
                ("", 0),
            ],
            "7S 8S 9S TS JS QS",
            "",
        );
        assert!(!Model::new(DrawMode::One, live, false).stuck());
    }

    #[test]
    fn finishing_plays_every_card_home() {
        let t = endgame(
            [
                ("KS QH JC", 0),
                ("KH QS", 0),
                ("KC QD JS", 0),
                ("KD QC JH", 0),
                ("JD", 0),
                ("", 0),
                ("", 0),
            ],
            "",
            "",
        );
        let mut m = Model::new(DrawMode::Three, t, false);
        assert!(m.can_finish());
        let mut n = 0;
        while let Some(mv) = m.finish_move() {
            m.apply(mv).expect("each finishing move is legal");
            n += 1;
        }
        assert!(m.won);
        assert_eq!(n, 12);
    }

    #[test]
    fn the_solver_wins_an_endgame_and_the_line_replays() {
        let t = endgame(
            [
                ("8C 7D", 1),
                ("9H 8S", 0),
                ("7C", 0),
                ("9S", 0),
                ("TD 9C", 1),
                ("", 0),
                ("", 0),
            ],
            "KS KH KC KD QS QH QC QD JS JH JC JD TS TH TC 8H 9D 8D 7S 7H",
            "",
        );
        for mode in DRAW_MODES {
            let mut s = Solver::new(&t, mode, DEAL_LIMITS);
            let Some(Verdict::Winnable(path)) = s.run(u64::MAX).cloned() else {
                panic!("{mode:?}: the endgame is winnable");
            };
            assert!(
                replays_to_win(&t, mode, &path),
                "{mode:?}: the line replays"
            );
        }
    }

    /// Why `steps` fail to replay, or `None` when they win.
    fn replay_error(t: &Table, mode: DrawMode, steps: &[Step]) -> Option<String> {
        let mut m = Model::new(mode, t.clone(), false);
        for (i, &step) in steps.iter().enumerate() {
            let Some(moves) = m.moves_for(step) else {
                return Some(format!(
                    "step {i} {step:?}: no moves for it at {}",
                    m.table.encode()
                ));
            };
            for mv in moves {
                if m.apply(mv).is_none() {
                    return Some(format!(
                        "step {i} {step:?}: {mv:?} refused at {}",
                        m.table.encode()
                    ));
                }
            }
        }
        (!m.won).then(|| format!("no win after the steps: {}", m.table.encode()))
    }

    /// Every legal move, for the exhaustive search the solver is checked against.
    fn every_move(m: &Model) -> Vec<Move> {
        let mut out = vec![Move::Draw];
        let froms = [Pile::Waste]
            .into_iter()
            .chain((0..4).map(Pile::Foundation))
            .chain((0..COLS).map(Pile::Tableau));
        let tos: Vec<Pile> = (0..4)
            .map(Pile::Foundation)
            .chain((0..COLS).map(Pile::Tableau))
            .collect();
        for from in froms {
            let most = match from {
                Pile::Tableau(c) => m.table.face_up(c),
                _ => 1,
            };
            for count in 1..=most {
                for &to in &tos {
                    let mv = Move::Shift { from, count, to };
                    if m.legal(mv) {
                        out.push(mv);
                    }
                }
            }
        }
        out.retain(|&mv| m.legal(mv));
        out
    }

    /// Winnability by brute force over every legal move, no pruning at all; `None` past `cap`.
    fn exhaustive(t: &Table, mode: DrawMode, cap: usize) -> Option<bool> {
        let mut seen = HashSet::new();
        let mut stack = vec![t.clone()];
        while let Some(t) = stack.pop() {
            if t.won() {
                return Some(true);
            }
            if !seen.insert(t.encode()) {
                continue;
            }
            if seen.len() > cap {
                return None;
            }
            let m = Model::new(mode, t, false);
            for mv in every_move(&m) {
                let mut next = Model::new(mode, m.table.clone(), false);
                if next.apply(mv).is_some() {
                    stack.push(next.table);
                }
            }
        }
        Some(false)
    }

    /// A random late-game position: each suit home to a random height, the rest spread over the
    /// columns (some face down) and the stock and waste. With `black`, both red suits are home, so
    /// nothing stacks except on a red card worried back down: small enough to search to the end,
    /// and often lost.
    fn random_endgame(rng: &mut Rng, black: bool) -> Table {
        let mut t = Table::default();
        let mut rest = Vec::new();
        for s in 0..4u8 {
            let home = match (black, s & 1 == 1) {
                (true, true) => 13,
                (true, false) => 5 + rng.below(4) as u8,
                (false, _) => 10 + rng.below(4) as u8,
            };
            t.foundations[s as usize] = (1..=home).map(|r| Card::new(s, r)).collect();
            rest.extend((home + 1..=13).map(|r| Card::new(s, r)));
        }
        for i in (1..rest.len()).rev() {
            rest.swap(i, rng.below(i + 1));
        }
        if black {
            // A card in every column first: with no empty column, a red king cannot come back
            // down for the black cards to build on, which keeps the search small.
            for col in 0..COLS {
                if let Some(card) = rest.pop() {
                    t.tableau[col].push(card);
                }
            }
        }
        for card in rest {
            match rng.below(10) {
                0..=2 => t.stock.push(card),
                3 => t.waste.push(card),
                _ => {
                    // Over every column, so a full tableau with no empty column is common and a
                    // buried card can stay out of reach.
                    let col = rng.below(COLS);
                    if t.tableau[col].len() < 6 {
                        t.tableau[col].push(card);
                    } else {
                        t.stock.push(card);
                    }
                }
            }
        }
        for (col, hidden) in t.tableau.iter().zip(t.hidden.iter_mut()) {
            if col.is_empty() {
                continue;
            }
            // The face-up part is a run: at most the longest built run on top.
            let mut run = 1;
            while run < col.len() && col[col.len() - run].stacks_on(col[col.len() - run - 1]) {
                run += 1;
            }
            let up = 1 + rng.below(run);
            *hidden = (col.len() - up).min(MAX_HIDDEN);
        }
        t
    }

    #[test]
    fn the_solver_agrees_with_exhaustive_search_on_small_endgames() {
        let mut rng = Rng::new(0x5017);
        let (mut agreed, mut wins, mut losses) = (0, 0, 0);
        for i in 0..150 {
            let t = random_endgame(&mut rng, i % 2 == 1);
            if !t.valid() {
                continue;
            }
            for mode in DRAW_MODES {
                let Some(truth) = exhaustive(&t, mode, 12_000) else {
                    continue;
                };
                let verdict = Solver::new(&t, mode, DEAL_LIMITS).run(u64::MAX).cloned();
                match verdict {
                    Some(Verdict::Winnable(path)) => {
                        assert!(truth, "{mode:?}: the solver won a lost position {t:?}");
                        if let Some(e) = replay_error(&t, mode, &path) {
                            panic!("{mode:?} from {}: {e}\npath {path:?}", t.encode());
                        }
                        wins += 1;
                    }
                    Some(Verdict::Unwinnable) => {
                        assert!(!truth, "{mode:?}: the solver gave up a winnable {t:?}");
                        losses += 1;
                    }
                    other => panic!("{mode:?}: small positions resolve, got {other:?}"),
                }
                agreed += 1;
            }
        }
        assert!(
            agreed > 60 && wins > 10 && losses > 0,
            "enough of each verdict: {agreed} resolved, {wins} won, {losses} lost"
        );
    }

    #[test]
    fn every_win_the_solver_finds_on_real_deals_replays() {
        let small = Limits {
            streamlined: 1_500,
            restart: 2_000,
            restarts: 2,
            full: 4_000,
        };
        let mut wins = 0;
        for seed in 1..=12 {
            for mode in DRAW_MODES {
                let t = Table::deal(seed * 7919);
                if let Some(Verdict::Winnable(path)) =
                    Solver::new(&t, mode, small).run(u64::MAX).cloned()
                {
                    assert!(replays_to_win(&t, mode, &path), "seed {seed} {mode:?}");
                    wins += 1;
                }
            }
        }
        assert!(wins > 6, "most deals are won quickly: {wins}");
    }

    #[test]
    fn the_winnable_deal_search_is_deterministic_and_proven() {
        for mode in DRAW_MODES {
            let (a, proven) = DealSearch::new(15, mode).finish();
            assert!(proven, "{mode:?}: a winnable deal turns up");
            // Slicing the work differently finds the same deal.
            let mut sliced = DealSearch::new(15, mode);
            let b = loop {
                if let Some((t, _)) = sliced.step(97) {
                    break t;
                }
            };
            assert_eq!(a, b, "{mode:?}");
        }
    }

    /// `cargo test --release -p solitaire -- --ignored --nocapture measure` (SOLITAIRE_DEALS sets
    /// how many): how many random deals the solver proves winnable, and how fast.
    #[test]
    #[ignore]
    fn measure_winnability() {
        let deals: u64 = std::env::var("SOLITAIRE_DEALS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(1000);
        // SOLITAIRE_LIMITS=streamlined,restart,restarts,full tries other limits.
        let limits = std::env::var("SOLITAIRE_LIMITS")
            .ok()
            .and_then(|s| {
                let v: Vec<u64> = s.split(',').filter_map(|x| x.parse().ok()).collect();
                match v.as_slice() {
                    &[streamlined, restart, restarts, full] => Some(Limits {
                        streamlined,
                        restart,
                        restarts: restarts as u32,
                        full,
                    }),
                    _ => None,
                }
            })
            .unwrap_or(DEAL_LIMITS);
        eprintln!("{limits:?}");
        for mode in DRAW_MODES {
            let (mut win, mut lose, mut unknown, mut work) = (0u64, 0u64, 0u64, 0u64);
            let mut slowest = 0u64;
            let start = std::time::Instant::now();
            for seed in 1..=deals {
                let t = Table::deal(mix(seed));
                let mut s = Solver::new(&t, mode, limits);
                let v = s.run(u64::MAX).cloned();
                work += s.work;
                slowest = slowest.max(s.work);
                match v {
                    Some(Verdict::Winnable(path)) => {
                        assert!(replays_to_win(&t, mode, &path));
                        win += 1;
                    }
                    Some(Verdict::Unwinnable) => lose += 1,
                    _ => unknown += 1,
                }
            }
            let secs = start.elapsed().as_secs_f64();
            eprintln!(
                "{mode:?}: {deals} deals, winnable {:.1}%, unwinnable {:.1}%, unknown {:.1}%, \
                 {:.0} positions a deal (max {slowest}), {:.2} ms a deal",
                100.0 * win as f64 / deals as f64,
                100.0 * lose as f64 / deals as f64,
                100.0 * unknown as f64 / deals as f64,
                work as f64 / deals as f64,
                1000.0 * secs / deals as f64,
            );
        }
    }
}
