//! What an engine does: works out generations, and gives the board.

use grid::Grid;
use std::thread::Threads;

use crate::board::{self, Board};
use crate::rule::Rule;
use crate::spawn;

/// Something that works out generations of a board.
pub trait Engine {
    /// Works out `gens` more generations.
    fn run(&mut self, gens: u32) with alloc;

    /// The board, as it is now: `None` only if something's gone wrong.
    /// It's a `Board`, at least a cell each way, but a trait's method
    /// can't say so yet (FRICTION.md).
    fn board(&self) -> Option<Grid<bool>> with alloc;

    /// Starts again from `board`, if it's as big as the one it has; if it
    /// isn't, goes on with what it has.
    fn load(&mut self, board: Grid<bool>) with alloc;
}

/// The engines with no threads of their own, on two boards: `one` works
/// out each generation here, `spawn` with threads it starts for it.
#[derive(Discard)]
pub struct Local<'a> {
    threads: &'a Threads,
    rule: Rule,
    count: { n: u32 | n >= 1 && n <= 1024 },
    /// Whether to start threads.
    spawn: bool,
    width: usize,
    height: usize,
    /// The two boards: each generation is worked out from one into the
    /// other. `b` is the board now if `on_b`.
    a: { g: Board | g.width() == width && g.height() == height },
    b: { g: Board | g.width() == width && g.height() == height },
    on_b: bool,
}

impl<'a> Local<'a> {
    /// An engine starting from `board`, by `rule`; with up to `count`
    /// threads from `threads` if `spawn`.
    pub fn new(
        threads: &'a Threads,
        board: &Board,
        rule: Rule,
        count: { n: u32 | n >= 1 && n <= 1024 },
        spawn: bool,
    ) -> Local<'a> with alloc {
        Local {
            threads,
            rule,
            count,
            spawn,
            width: board.width(),
            height: board.height(),
            a: board.copy(),
            b: board.copy(),
            on_b: false,
        }
    }
}

impl<'a> Engine for Local<'a> {
    fn run(&mut self, gens: u32) with alloc {
        let mut k: u32 = 0;
        while k < gens {
            // Not `core::mem::swap(&mut self.a, &mut self.b)` after each,
            // which forgets how big they are (FRICTION.md).
            if self.on_b {
                if self.spawn {
                    spawn::step(self.threads, &self.b, &self.rule, self.count, &mut self.a);
                } else {
                    board::step(&self.b, &self.rule, &mut self.a);
                }
            } else {
                if self.spawn {
                    spawn::step(self.threads, &self.a, &self.rule, self.count, &mut self.b);
                } else {
                    board::step(&self.a, &self.rule, &mut self.b);
                }
            }
            self.on_b = !self.on_b;
            k = k + 1;
        }
    }

    fn board(&self) -> Option<Grid<bool>> with alloc {
        Some(if self.on_b { self.b.copy() } else { self.a.copy() })
    }

    fn load(&mut self, board: Grid<bool>) with alloc {
        if board.width() == self.width && board.height() == self.height {
            self.a = board;
            self.on_b = false;
        }
    }
}
