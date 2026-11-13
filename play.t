//! On a terminal: the board, drawn again after each few generations, and
//! keys to pause, step, speed up, slow down, start again and quit.

use alloc::string::String;
use core::fmt::Write;
use core::num::saturating_add;
use core::time::Duration;
use std::io::{Error, Raw, Size, Stdout};
use std::time::{Clock, Instant};
use rand::Rng;
use term::Key;

use crate::board::{self, Board};
use crate::engine::Engine;
use crate::rule::Rule;

/// How long each frame is shown, in milliseconds.
const FRAME_MS: u64 = 50;

/// The most generations worked out for one frame.
const FASTEST: u32 = 64;

/// What the keys do, after the numbers.
const HELP: &str = "space: pause  n: step  +/-: speed  r: new  q: quit";

/// How big a board fits on a terminal `size` big, with a line for words
/// under it: each character shows two cells, one above the other.
pub fn fit(size: Size) -> (usize, usize) {
    let cols = size.cols as usize;
    let rows = size.rows as usize;
    let height = if rows >= 2 { (rows - 1) * 2 } else { 0 };
    (cols, height)
}

/// What's being shown, and how.
#[derive(Discard)]
pub struct Show {
    /// What the engine is called, and how many threads it has.
    pub about: String,
    pub rule: Rule,
    /// How many generations there have been.
    gen: u64,
    /// How many to work out for each frame: 0 if paused.
    speed: u32,
    /// How many it was before a pause.
    was: { s: u32 | s >= 1 },
}

impl Show {
    pub fn new(about: String, rule: Rule) -> Show { Show { about, rule, gen: 0, speed: 1, was: 1 } }
}

/// Plays on the terminal until a key says to stop: `engine` works out the
/// generations of boards as big as `width` by `height`, which `rng` fills.
/// Keys come from `raw`, and `clock` times the frames.
pub fn play<E: Engine>(
    engine: &mut E,
    show: &mut Show,
    out: &mut Stdout,
    raw: &mut Raw<'_>,
    clock: Clock,
    rng: &mut Rng,
) -> Result<(), Error> with alloc {
    let mut next = clock.now();
    loop {
        if show.speed > 0 {
            engine.run(show.speed);
            show.gen = saturating_add(show.gen, show.speed as u64);
        }
        // It's a `Board`, but `Engine::board` can't say so (FRICTION.md).
        let Some(b) = engine.board() else { return Ok(()) };
        if b.width() == 0 || b.height() == 0 {
            return Ok(());
        }
        draw(out, &b, show)?;
        next = next.add(Duration::from_millis(FRAME_MS));
        if !wait(engine, show, raw, clock, rng, next, &b)? {
            return Ok(());
        }
    }
}

/// Waits for `until`, doing what the keys pressed meanwhile say: `false`
/// if one says to stop. `board` is what's shown.
fn wait<E: Engine>(
    engine: &mut E,
    show: &mut Show,
    raw: &mut Raw<'_>,
    clock: Clock,
    rng: &mut Rng,
    until: Instant,
    board: &Board,
) -> Result<bool, Error> with alloc {
    while raw.wait(until)? {
        match term::read(raw, clock)? {
            Key::Char('q') | Key::Ctrl('c') | Key::Escape => return Ok(false),
            Key::Char(' ') => {
                if show.speed > 0 {
                    show.was = show.speed;
                    show.speed = 0;
                } else {
                    show.speed = show.was;
                }
            },
            Key::Char('n') => {
                if show.speed == 0 {
                    engine.run(1);
                    show.gen = saturating_add(show.gen, 1);
                    return Ok(true);
                }
            },
            Key::Char('+') | Key::Char('=') => {
                if show.speed > 0 && show.speed < FASTEST {
                    show.speed = show.speed * 2;
                }
            },
            Key::Char('-') => {
                if show.speed > 1 {
                    show.speed = show.speed / 2;
                }
            },
            Key::Char('r') => {
                if let Some(b) = board::soup(board.width(), board.height(), rng, crate::ALIVE) {
                    engine.load(b);
                    show.gen = 0;
                    return Ok(true);
                }
            },
            _ => {},
        }
    }
    Ok(true)
}

/// Draws `board` from the top left corner, two rows of cells to a line,
/// and a line of words under it.
fn draw(out: &mut Stdout, board: &Board, show: &Show) -> Result<(), Error> with alloc {
    let w = board.width();
    let h = board.height();
    let mut s = String::from("\u{1b}[H");
    let mut y: usize = 0;
    while y < h {
        let top = board.row(y);
        let below = if y + 1 < h { Some(board.row(y + 1)) } else { None };
        let mut x: usize = 0;
        while x < w {
            let up = top[x];
            let down = match below {
                Some(r) => x < r.len() && r[x],
                None => false,
            };
            s.push(match (up, down) {
                (true, true) => '█',
                (true, false) => '▀',
                (false, true) => '▄',
                (false, false) => ' ',
            });
            x = x + 1;
        }
        s.push('\n');
        y = saturating_add(y, 2);
    }
    let mut line = String::new();
    line.put(
        &f"gen {show.gen}  pop {board::population(board)}  {show.rule}  {show.about}  ",
    ).into_ok();
    if show.speed == 0 {
        line.push_str("paused");
    } else {
        line.put(&f"x{show.speed}").into_ok();
    }
    line.push_str("  ");
    line.push_str(HELP);
    // As much as fits on the line: it's all one byte to a character.
    let _ = line.truncate(w);
    s.push_str(line.as_str());
    s.push_str("\u{1b}[K");
    out.put(s.as_str())?;
    out.flush()
}
