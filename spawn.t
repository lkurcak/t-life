//! The spawn engine: threads started for each generation, one for each
//! band of rows of the next one, which each writes through a `&mut` that
//! `split_at_mut` gives it, reading the whole of this one. The threads
//! share no cell they write, so they need nothing to wait for each other
//! with but `join`; but a thread is started for each band each generation.

use alloc::list::List;
use core::num::{checked_mul, saturating_add};
use grid::Grid;
use std::thread::{JoinHandle, Threads};

use crate::board::{self, Board};
use crate::rule::Rule;

/// The generation after `board` by `rule`, worked out by up to `count`
/// threads from `threads`, one for each band of rows, and no more than
/// the board has rows.
pub fn step(
    threads: &Threads,
    board: &Board,
    rule: &Rule,
    count: { n: u32 | n >= 1 && n <= 1024 },
    next: &mut { g: Grid<bool> | g.width() == board.width() && g.height() == board.height() },
) with alloc {
    let w = board.width();
    let h = board.height();
    let n: usize = if count as usize < h { count as usize } else { h };
    let q = h / n;
    let extra = h % n;
    let mut rest: &mut [bool] = next.cells_mut();
    let mut handles: List<JoinHandle<'_, ()>> = List::new();
    let mut top: usize = 0;
    let mut i: usize = 0;
    while i < n {
        let rows = if i < extra { q + 1 } else { q };
        let Some(cells) = checked_mul(rows, w) else { break };
        let Some((band, tail)) = rest.split_at_mut(cells) else { break };
        rest = tail;
        let first = top;
        handles.push(threads.spawn(move || rows_of(board, rule, first, band)));
        top = saturating_add(top, rows);
        i = i + 1;
    }
    handles.free_with(|h| h.join());
}

/// Works out the rows of the generation after `board` from row `top` on,
/// into `band`, which has room for whole rows.
fn rows_of(board: &Board, rule: &Rule, top: usize, band: &mut [bool]) {
    let w = board.width();
    let h = board.height();
    let mut y = top;
    let mut start: usize = 0;
    while y < h && start <= band.len() && w <= band.len() - start {
        board::next_row(
            rule,
            board.row(board::up(h, y)),
            board.row(y),
            board.row(board::down(h, y)),
            band.slice_mut(start..start + w),
        );
        start = start + w;
        y = y + 1;
    }
}
