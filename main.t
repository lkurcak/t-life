//! t-life: Life-like cellular automata, worked out by several threads.
//!
//! On a terminal it's animated, and keys say what to do. Otherwise, as
//! when its output goes to a file, it writes the board after a number of
//! generations, as text; and `--bench` times the ways it has of working
//! them out, and checks that they agree.
//!
//! `life [--rule B3/S23] [--size WxH] [--seed N] [--threads N]
//! [--engine pool|spawn|one] [--gens N] [--bench]`
//!
//! Nothing in it panics: `implicit_panics` warns of any arithmetic, or
//! index, the checker can't prove is in range, and CI denies warnings.
#![warn(implicit_panics)]

use alloc::string::String;
use std::env::Args;
use std::io::{Error, Stdout};
use std::thread::Threads;
use std::time::Clock;
use std::Os;

use board::Board;
use engine::{Engine, Local};
use grid::Grid;
use play::Show;
use rand::Rng;
use rule::Rule;

mod board;
mod engine;
mod play;
mod pool;
mod rule;
mod spawn;

/// How many cells in a hundred are alive at the start.
pub const ALIVE: u64 = 35;

/// How many threads, unless the command line says: as many as the
/// machine runs at once, up to 1024.
fn default_threads(threads: &Threads) -> { n: u32 | n >= 1 && n <= 1024 } {
    let n = threads.available();
    if n > 1024 { 1024 } else { n as u32 }
}

/// Which engine works out the generations.
#[derive(Copy, Discard, Eq)]
enum Kind {
    /// A thread for each band of rows, kept for the whole run.
    Pool,
    /// Threads started for each generation.
    Spawn,
    /// This thread, alone.
    One,
}

/// What the command line says.
#[derive(Copy, Discard)]
struct Asked {
    rule: Rule,
    size: Option<(usize, usize)>,
    seed: Option<u64>,
    threads: { n: u32 | n >= 1 && n <= 1024 },
    kind: Kind,
    gens: Option<u64>,
    bench: bool,
}

/// What it says when it can't use the command line.
const USAGE: &str = "usage: life [--rule B3/S23] [--size WxH] [--seed N] [--threads N] \
    [--engine pool|spawn|one] [--gens N] [--bench]";

fn main(os: Os) -> Result<(), Error> {
    let mut input = os.stdin;
    let mut out = os.stdout;
    let mut err = os.stderr;
    let Some(asked) = asked(os.args, &os.threads) else { return err.line(USAGE) };
    let seed = match asked.seed {
        Some(seed) => seed,
        None => os.entropy.u64()?,
    };
    let mut rng = Rng::new(seed);
    if asked.bench {
        return bench(&mut out, &os.threads, os.clock, &mut rng, &asked, seed);
    }
    if asked.gens.is_none() && input.is_terminal() && out.is_terminal() {
        let mut raw = input.raw()?;
        let mut screen = term::Screen::enter(&mut out)?;
        let (width, height) = match asked.size {
            Some(s) => s,
            None => play::fit(screen.out().size()?),
        };
        let Some(start) = board::soup(width, height, &mut rng, ALIVE) else {
            screen.out().put("The terminal's too small; any key to stop.")?;
            screen.out().flush()?;
            let _ = term::read(&mut raw, os.clock)?;
            return Ok(());
        };
        let mut show = Show::new(about(&asked), asked.rule);
        let out = screen.out();
        return match asked.kind {
            Kind::Pool => pool::run(&os.threads, &start, asked.rule, asked.threads, |p| {
                play::play(p, &mut show, out, &mut raw, os.clock, &mut rng)
            }),
            _ => {
                let spawn = asked.kind == Kind::Spawn;
                let mut e = Local::new(&os.threads, &start, asked.rule, asked.threads, spawn);
                play::play(&mut e, &mut show, out, &mut raw, os.clock, &mut rng)
            },
        };
    }
    let (width, height) = asked.size.unwrap_or((32, 16));
    let Some(start) = board::soup(width, height, &mut rng, ALIVE) else {
        return err.line("The board must be at least one cell each way.");
    };
    let gens = asked.gens.unwrap_or(0);
    let end = by(&os.threads, &start, &asked, asked.kind, gens);
    let s = if gens == 1 { "" } else { "s" };
    out.line(&f"{asked.rule}, {width} by {height}, seed {seed}, after {gens} generation{s}:")?;
    out.put(board::text(&end).as_str())?;
    out.line(&f"population {board::population(&end)}, hash {board::hash(&end):x}")
}

/// Which engine `asked` says, and how many threads it has.
fn about(asked: &Asked) -> String with alloc {
    match asked.kind {
        Kind::Pool => String::of(&f"pool of {asked.threads}"),
        Kind::Spawn => String::of(&f"spawn {asked.threads}"),
        Kind::One => String::from("one thread"),
    }
}

/// `start`, `gens` generations on by the rule `asked` says, worked out by
/// a `kind` engine with as many threads as it says.
fn by(threads: &Threads, start: &Board, asked: &Asked, kind: Kind, gens: u64) -> Board with alloc {
    let end = match kind {
        Kind::Pool => pool::run(threads, start, asked.rule, asked.threads, |p| advance(p, gens)),
        _ => {
            let spawn = kind == Kind::Spawn;
            advance(&mut Local::new(threads, start, asked.rule, asked.threads, spawn), gens)
        },
    };
    // What the closure gives back is a `Board`, but `pool::run`'s `R`
    // doesn't say so (FRICTION.md): it's checked again.
    match end {
        Some(b) => if b.width() >= 1 && b.height() >= 1 { b } else { start.copy() },
        None => start.copy(),
    }
}

/// The board after `engine` works out `gens` more generations.
fn advance<E: Engine>(engine: &mut E, gens: u64) -> Option<Grid<bool>> with alloc {
    let mut left = gens;
    while left > 0 {
        let now: u32 = if left > 1_000_000 { 1_000_000 } else { left as u32 };
        engine.run(now);
        left = left - now as u64;
    }
    engine.board()
}

/// Times each engine at `gens` generations of a board as big as `asked`
/// says, and checks they agree.
fn bench(
    out: &mut Stdout,
    threads: &Threads,
    clock: Clock,
    rng: &mut Rng,
    asked: &Asked,
    seed: u64,
) -> Result<(), Error> {
    let (width, height) = asked.size.unwrap_or((512, 512));
    let gens = asked.gens.unwrap_or(100);
    let Some(start) = board::soup(width, height, rng, ALIVE) else {
        return out.line("The board must be at least one cell each way.");
    };
    out.line(
        &f"{asked.rule}, {width} by {height}, seed {seed}, {gens} generations, up to {asked.threads} threads",
    )?;
    let mut first: Option<u64> = None;
    let mut agree = true;
    for (name, kind) in [("one", Kind::One), ("spawn", Kind::Spawn), ("pool", Kind::Pool)] {
        let t0 = clock.now();
        let end = by(threads, &start, asked, kind, gens);
        let ms = clock.now().since(t0).as_millis();
        let h = board::hash(&end);
        out.line(&f"{name:<6}{ms:>8} ms   hash {h:x}")?;
        match first {
            None => first = Some(h),
            Some(f) => agree = agree && f == h,
        }
    }
    out.line(if agree { "They agree." } else { "They DON'T agree." })
}

/// Reads the command line: `None` if it's not as `USAGE` says.
fn asked(args: Args, threads: &Threads) -> Option<Asked> {
    let mut a = Asked {
        rule: Rule::conway(),
        size: None,
        seed: None,
        threads: default_threads(threads),
        kind: Kind::Pool,
        gens: None,
        bench: false,
    };
    let mut words = args.iter();
    while let Some(flag) = words.next() {
        if flag == "--bench" {
            a.bench = true;
            continue;
        }
        let value = words.next()?;
        match flag {
            "--rule" => a.rule = Rule::parse(value)?,
            "--size" => {
                let mut sides = value.split('x');
                let w = sides.next()?.parse::<usize>().ok()?;
                let h = sides.next()?.parse::<usize>().ok()?;
                if sides.next().is_some() {
                    return None;
                }
                a.size = Some((w, h));
            },
            "--seed" => a.seed = Some(value.parse::<u64>().ok()?),
            "--threads" => {
                let n = value.parse::<u32>().ok()?;
                if n < 1 || n > 1024 {
                    return None;
                }
                a.threads = n;
            },
            "--engine" => {
                a.kind = match value {
                    "pool" => Kind::Pool,
                    "spawn" => Kind::Spawn,
                    "one" => Kind::One,
                    _ => return None,
                }
            },
            "--gens" => a.gens = Some(value.parse::<u64>().ok()?),
            _ => return None,
        }
    }
    Some(a)
}
