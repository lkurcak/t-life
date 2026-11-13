//! A board: cells, each alive or dead, in rows, on a torus: the row
//! above the top one is the bottom one, and the cell left of the first in
//! a row is the last. And how one generation of it becomes the next.

use alloc::string::String;
use grid::Grid;
use rand::Rng;

use crate::rule::Rule;

/// Cells on a torus `width` wide and `height` high, at least one each way:
/// `true` for a live one.
pub type Board = { g: Grid<bool> | g.width() >= 1 && g.height() >= 1 };

/// A board `width` by `height` with each cell alive `percent` times in a
/// hundred, from `rng`; `None` if it can't be one, as when a side is 0.
pub fn soup(
    width: usize,
    height: usize,
    rng: &mut Rng,
    percent: { p: u64 | p <= 100 },
) -> Option<{ b: Board | b.width() == width && b.height() == height }> with alloc {
    if width == 0 || height == 0 {
        return None;
    }
    Grid::from_fn(width, height, |_x, _y| rng.chance(percent))
}

/// The row of the next generation `here` becomes, into `out`, with
/// `above` and `below` the rows next to it, by `rule`. Rows wrap around:
/// the cell left of the first is the last.
///
/// Each engine works out each row with this, so they all agree.
pub fn next_row(
    rule: &Rule,
    above: &[bool],
    here: { h: &[bool] | h.len() == above.len() },
    below: { b: &[bool] | b.len() == above.len() },
    out: { o: &mut [bool] | o.len() == above.len() },
) {
    let w = above.len();
    if w == 0 {
        return;
    }
    let mut x: usize = 0;
    while x < w {
        let l = if x == 0 { w - 1 } else { x - 1 };
        let r = if x + 1 == w { 0 } else { x + 1 };
        let n = one(above[l])
            + one(above[x])
            + one(above[r])
            + one(here[l])
            + one(here[r])
            + one(below[l])
            + one(below[x])
            + one(below[r]);
        out[x] = if here[x] { rule.survive[n] } else { rule.born[n] };
        x = x + 1;
    }
}

/// 1 for a live cell, 0 for a dead one.
fn one(alive: bool) -> { n: usize | n <= 1 } {
    if alive { 1 } else { 0 }
}

/// The row above row `y` of a board `height` high: the bottom one for the
/// top.
pub fn up(height: usize, y: { y: usize | y < height }) -> { u: usize | u < height } {
    if y == 0 { height - 1 } else { y - 1 }
}

/// The row below row `y` of a board `height` high: the top one for the
/// bottom.
pub fn down(height: usize, y: { y: usize | y < height }) -> { d: usize | d < height } {
    if y + 1 == height { 0 } else { y + 1 }
}

/// How many cells of `board` are alive.
pub fn population(board: &Board) -> usize {
    let cells = board.cells();
    let mut n: usize = 0;
    let mut i: usize = 0;
    while i < cells.len() invariant n <= i {
        if cells[i] {
            n = n + 1;
        }
        i = i + 1;
    }
    n
}

/// A number that's the same for two boards with the same cells, and most
/// likely different otherwise: FNV-1a over the cells, a byte each, after
/// the size.
pub fn hash(board: &Board) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    h = mix(h, board.width() as u64);
    h = mix(h, board.height() as u64);
    for c in board.iter() {
        h = mix(h, if *c { 1 } else { 0 });
    }
    h
}

/// FNV-1a's step: `h` with `v` in it.
fn mix(h: u64, v: u64) -> u64 { core::num::wrapping_mul(h ^ v, 0x100000001b3) }

/// The board as text, a line a row: `#` for a live cell, `.` for a dead
/// one.
pub fn text(board: &Board) -> String with alloc {
    let mut s = String::new();
    let mut y: usize = 0;
    while y < board.height() {
        for c in board.row(y) {
            s.push(if *c { '#' } else { '.' });
        }
        s.push('\n');
        y = y + 1;
    }
    s
}

/// Works out the next generation of `board` by `rule` into `next`, here,
/// row by row, with no threads: what the engines must agree with.
pub fn step(
    board: &Board,
    rule: &Rule,
    next: &mut { g: Grid<bool> | g.width() == board.width() && g.height() == board.height() },
) {
    let h = board.height();
    let mut y: usize = 0;
    while y < h {
        next_row(rule, board.row(up(h, y)), board.row(y), board.row(down(h, y)), next.row_mut(y));
        y = y + 1;
    }
}

/// The board `rows` draw, `#` for a live cell, or `None` if there's no
/// row, or the first is empty. A row shorter than the first is dead past
/// its end.
fn drawn(rows: &[&str]) -> Option<Board> with alloc {
    let w = rows.first()?.len();
    let h = rows.len();
    if w == 0 || h == 0 {
        return None;
    }
    Grid::from_fn(
        w,
        h,
        |x, y| match rows.get(y) {
            Some(r) => r.as_bytes().get(x) == Some(&b'#'),
            None => false,
        },
    )
}

/// `board`, `gens` generations on by `rule`.
fn after(board: &Board, rule: &Rule, gens: u32) -> Board with alloc {
    let w = board.width();
    let h = board.height();
    let mut now: { g: Board | g.width() == w && g.height() == h } = board.copy();
    let mut next: { g: Board | g.width() == w && g.height() == h } = board.copy();
    let mut k: u32 = 0;
    while k < gens {
        step(&now, rule, &mut next);
        let done = next;
        next = now;
        now = done;
        k = k + 1;
    }
    now
}

#[test]
fn a_blinker_blinks() {
    let Some(b) = drawn(&[".....", "..#..", "..#..", "..#..", "....."]) else { panic("drawn") };
    let Some(flat) = drawn(&[".....", ".....", ".###.", ".....", "....."]) else { panic("drawn") };
    let life = Rule::conway();
    assert_eq(text(&after(&b, &life, 1)).as_str(), text(&flat).as_str());
    assert_eq(text(&after(&b, &life, 2)).as_str(), text(&b).as_str());
    assert_eq(&population(&b), &3);
}

#[test]
fn a_glider_goes_round_the_torus() {
    let Some(g) = drawn(
        &[".#......", "..#.....", "###.....", "........", "........", "........"],
    ) else {
        panic("drawn")
    };
    // A glider moves a cell down and a cell right every 4 generations: on
    // a board 8 wide and 6 high, it's back where it started when it has
    // gone round both ways, after 24 moves, the least that 8 and 6 both
    // divide: 96 generations.
    let Some(moved) = drawn(
        &["........", "..#.....", "...#....", ".###....", "........", "........"],
    ) else {
        panic("drawn")
    };
    let life = Rule::conway();
    assert_eq(text(&after(&g, &life, 4)).as_str(), text(&moved).as_str());
    assert_eq(text(&after(&g, &life, 96)).as_str(), text(&g).as_str());
    assert(hash(&after(&g, &life, 48)) != hash(&g));
    assert_eq(&population(&after(&g, &life, 50)), &5);
}

#[test]
fn seeds_die_out_where_life_lives_on() {
    // A block lives on under Conway's rule. Under Seeds, B2/S, no cell
    // survives, and the cells beside its sides, which see two of it, are
    // born: it becomes a ring.
    let Some(block) = drawn(&["......", "......", "..##..", "..##..", "......", "......"]) else {
        panic("drawn")
    };
    let Some(seeds) = Rule::parse("B2/S") else { panic("rule") };
    assert_eq(text(&after(&block, &Rule::conway(), 7)).as_str(), text(&block).as_str());
    let ring = after(&block, &seeds, 1);
    assert_eq(text(&ring).as_str(), "......\n..##..\n.#..#.\n.#..#.\n..##..\n......\n");
}
