//! The pool engine: a thread for each band of rows, kept for as long as
//! the pool lives.
//!
//! Each thread has its band's cells to itself, and two rows more, one
//! above and one below, for the rows next to its band, which other threads
//! have. Each generation, each thread puts its band's top and bottom rows
//! where its neighbours can read them, waits for all the others to have
//! done the same, reads its neighbours' rows into its own two, and works
//! out its band's next generation. Only those edge rows are shared, each
//! in a `Mutex`; the bands aren't.
//!
//! The rows go in one of two sets, by whether the generation is even or
//! odd: a thread that's quick writes the next generation's rows in the
//! other set, so it can't change one that a slower neighbour is still
//! reading.

use alloc::list::List;
use core::sync::{Atomic, Mutex};
use grid::Grid;
use std::thread::{JoinHandle, Threads};

use crate::board::{self, Board};
use crate::engine::Engine;
use crate::rule::Rule;
use crate::sync::Barrier;

/// A band's rows, and one more above and below them: what the neighbours
/// had at their edges.
#[derive(Discard, Send)]
struct Band {
    /// How many rows it has.
    rows: { r: usize | r >= 1 },
    /// The row after its last, on the board: its first is `end - rows`.
    end: { e: usize | e >= rows },
    /// How many cells wide the board is.
    width: usize,
    /// This generation: row 0 is the row above the band, rows 1 to
    /// `rows` are the band's, and row `rows + 1` is the row below it.
    now: { g: Grid<bool> | g.height() == rows + 2 && g.width() == width },
    /// The next generation, as it's worked out, rows as in `now`.
    next: { g: Grid<bool> | g.height() == rows + 2 && g.width() == width },
}

impl Band {
    /// Rows `top` on of `board`, `rows` of them, as a band, or `None` if
    /// there aren't that many.
    fn of(board: &Board, top: usize, rows: { r: usize | r >= 1 }) -> Option<Band> with alloc {
        let h = board.height();
        if top >= h || rows > h - top {
            return None;
        }
        let w = board.width();
        let tall = core::num::checked_add(rows, 2)?;
        let now = Grid::new(w, tall, false)?;
        let next = Grid::new(w, tall, false)?;
        let mut band = Band { rows, end: top + rows, width: w, now, next };
        band.load(board);
        Some(band)
    }

    /// Puts the band's rows of `board` in it.
    fn load(&mut self, board: &Grid<bool>) {
        let mut r: usize = 1;
        while r <= self.rows invariant r >= 1 {
            let y = self.end - self.rows + (r - 1);
            if y < board.height() {
                copy(board.row(y), self.now.row_mut(r));
            }
            r = r + 1;
        }
    }

    /// Puts the band's rows in `board`.
    fn store(&self, board: &mut Grid<bool>) {
        let mut r: usize = 1;
        while r <= self.rows invariant r >= 1 {
            let y = self.end - self.rows + (r - 1);
            if y < board.height() {
                copy(self.now.row(r), board.row_mut(y));
            }
            r = r + 1;
        }
    }

    /// The band's next generation, from its rows and the two next to
    /// them, which must be there.
    ///
    /// It takes the band and gives it back, rather than changing it
    /// through a `&mut`: `core::mem::swap(&mut self.now, &mut self.next)`
    /// forgets that each is `rows + 2` high (FRICTION.md).
    fn step(self, rule: &Rule) -> Band {
        let Band { rows, end, width, now, next: mut next } = self;
        let mut r: usize = 1;
        while r <= rows invariant r >= 1 {
            board::next_row(rule, now.row(r - 1), now.row(r), now.row(r + 1), next.row_mut(r));
            r = r + 1;
        }
        Band { rows, end, width, now: next, next: now }
    }
}

/// Copies what it can of `from` into `to`: as many cells as the shorter
/// has.
fn copy(from: &[bool], to: &mut [bool]) {
    let mut x: usize = 0;
    while x < from.len() && x < to.len() {
        to[x] = from[x];
        x = x + 1;
    }
}

/// A band's top and bottom rows, as its neighbours read them.
#[derive(Discard, Send, Sync)]
struct Edges { top: Mutex<List<bool>>, bottom: Mutex<List<bool>> }

/// What the threads share: how they wait for each other, what they're to
/// do, and the edges.
#[derive(Discard, Send, Sync)]
struct Shared {
    /// Where the pool's threads wait for each other, each generation.
    team: Barrier,
    /// Where they wait for the pool's owner too: before each run, so it
    /// can say what to do, and after, so it can look.
    all: Barrier,
    /// How many generations to work out next.
    gens: Atomic<u32>,
    /// Whether to take the bands from `board` first.
    load: Atomic<bool>,
    /// Whether to stop.
    stop: Atomic<bool>,
    /// Each band's edges, in even generations and in odd ones.
    even: List<Edges>,
    odd: List<Edges>,
    /// The board: where the threads put their bands after each run, and
    /// take them from on `load`.
    board: Mutex<Grid<bool>>,
}

/// A pool working on a board.
#[derive(Discard)]
pub struct Pool<'a> { shared: &'a Shared, width: usize, height: usize }

impl<'a> Engine for Pool<'a> {
    fn run(&mut self, gens: u32) {
        self.shared.gens.store(gens);
        self.shared.all.wait();
        self.shared.all.wait();
    }

    fn board(&self) -> Option<Grid<bool>> with alloc { Some(self.shared.board.lock(|b| b.copy())) }

    fn load(&mut self, board: Grid<bool>) {
        if board.width() != self.width || board.height() != self.height {
            return;
        }
        let _old = self.shared.board.lock(|b| core::mem::replace(b, board));
        self.shared.load.store(true);
        self.shared.gens.store(0);
        self.shared.all.wait();
        self.shared.all.wait();
        self.shared.load.store(false);
    }
}

/// Makes a pool of up to `count` threads, from `threads`, working on
/// `board` by `rule`; calls `f` with it, and stops it after: `f` runs it.
/// It has a thread for each band of rows, and no more threads than the
/// board has rows.
pub fn run<R, effect e, F: FnOnce(&mut Pool<'_>) -> R with e>(
    threads: &Threads,
    board: &Board,
    rule: Rule,
    count: { n: u32 | n >= 1 && n <= 1024 },
    f: F,
) -> R with {alloc, e} {
    let height = board.height();
    let n: usize = if count as usize < height { count as usize } else { height };
    let shared = Shared {
        team: Barrier::new(n as u32),
        all: Barrier::new(n as u32 + 1),
        gens: Atomic::new(0),
        load: Atomic::new(false),
        stop: Atomic::new(false),
        even: edges(n),
        odd: edges(n),
        board: Mutex::new(board.copy()),
    };
    let s = &shared;
    let mut handles: List<JoinHandle<'_, ()>> = List::new();
    let q = height / n;
    let extra = height % n;
    let mut top: usize = 0;
    let mut i: usize = 0;
    while i < n {
        let rows = if i < extra { q + 1 } else { q };
        if rows >= 1 {
            if let Some(band) = Band::of(board, top, rows) {
                handles.push(threads.spawn(move || work(band, i, n, s, rule)));
            }
        }
        top = core::num::saturating_add(top, rows);
        i = i + 1;
    }
    let mut pool = Pool { shared: s, width: board.width(), height };
    let r = f(&mut pool);
    shared.stop.store(true);
    shared.all.wait();
    handles.free_with(|h| h.join());
    r
}

/// Edges for `n` bands, empty.
fn edges(n: usize) -> List<Edges> with alloc {
    let mut l = List::new();
    let mut i: usize = 0;
    while i < n {
        l.push(Edges { top: Mutex::new(List::new()), bottom: Mutex::new(List::new()) });
        i = i + 1;
    }
    l
}

/// What thread `i` of `n` does: works on `band`, as `shared` says, until
/// it says to stop.
fn work(mut band: Band, i: usize, n: usize, shared: &Shared, rule: Rule) with alloc {
    let mut gen: u64 = 0;
    loop {
        shared.all.wait();
        if shared.stop.load() {
            return;
        }
        if shared.load.load() {
            shared.board.lock(|b| band.load(b));
        }
        let gens = shared.gens.load();
        let mut k: u32 = 0;
        while k < gens {
            let edges = if gen % 2 == 0 { &shared.even } else { &shared.odd };
            exchange(&mut band, i, n, edges, &shared.team);
            band = band.step(&rule);
            gen = core::num::wrapping_add(gen, 1);
            k = k + 1;
        }
        shared.board.lock(|b| band.store(b));
        shared.all.wait();
    }
}

/// Puts `band`'s edge rows in `edges[i]`, waits at `team` for the other
/// bands to have done the same, and takes the rows next to it from its
/// neighbours': band `i - 1`'s bottom row, and band `i + 1`'s top one,
/// round the board.
fn exchange(band: &mut Band, i: usize, n: usize, edges: &List<Edges>, team: &Barrier) with alloc {
    if i >= edges.len() || i >= n {
        return;
    }
    let rows = band.rows;
    put(&edges[i].top, band.now.row(1));
    put(&edges[i].bottom, band.now.row(rows));
    team.wait();
    let above = board::up(n, i);
    let below = board::down(n, i);
    if above < edges.len() && below < edges.len() {
        get(&edges[above].bottom, band.now.row_mut(0));
        get(&edges[below].top, band.now.row_mut(rows + 1));
    }
}

/// Puts `row` in `edge`.
fn put(edge: &Mutex<List<bool>>, row: &[bool]) with alloc {
    edge.lock(|l| {
        l.clear();
        for c in row {
            l.push(*c);
        }
    })
}

/// Copies `edge` into `row`.
fn get(edge: &Mutex<List<bool>>, row: &mut [bool]) { edge.lock(|l| copy(l.as_slice(), row)) }
