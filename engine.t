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
    /// The board now, and the one the next generation is worked out in.
    now: { g: Board | g.width() == width && g.height() == height },
    next: { g: Board | g.width() == width && g.height() == height },
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
            now: board.copy(),
            next: board.copy(),
        }
    }
}

impl<'a> Engine for Local<'a> {
    fn run(&mut self, gens: u32) with alloc {
        let mut k: u32 = 0;
        while k < gens {
            if self.spawn {
                spawn::step(self.threads, &self.now, &self.rule, self.count, &mut self.next);
            } else {
                board::step(&self.now, &self.rule, &mut self.next);
            }
            core::mem::swap(&mut self.now, &mut self.next);
            k = k + 1;
        }
    }

    fn board(&self) -> Option<Grid<bool>> with alloc { Some(self.now.copy()) }

    fn load(&mut self, board: Grid<bool>) with alloc {
        if board.width() == self.width && board.height() == self.height {
            self.now = board;
        }
    }
}
