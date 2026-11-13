//! Rules: when a cell is born, and when it lives on, by how many of its
//! eight neighbours are alive.
//!
//! A rule is written as `B3/S23`, Conway's: a dead cell with 3 live
//! neighbours is born, a live one with 2 or 3 survives, and every other
//! cell is dead in the next generation. `B36/S23` is HighLife, `B2/S` is
//! Seeds, `B3678/S34678` is Day & Night.

use alloc::string::String;
use core::fmt::{Display, Write};

/// When a cell is born and when it survives: `born[n]` if a dead cell
/// with `n` live neighbours comes alive, `survive[n]` if a live one stays
/// so.
#[derive(Copy, Discard, Eq, Send, Sync)]
pub struct Rule { pub born: [bool; 9], pub survive: [bool; 9] }

impl Rule {
    /// Conway's rule, `B3/S23`.
    pub fn conway() -> Rule {
        let mut born = [false; 9];
        let mut survive = [false; 9];
        born[3] = true;
        survive[2] = true;
        survive[3] = true;
        Rule { born, survive }
    }

    /// The rule `s` writes, as `B3/S23`, or `None` if it isn't one. The
    /// letters may be small, and the digits in any order.
    pub fn parse(s: &str) -> Option<Rule> {
        let mut parts = s.split('/');
        let b = parts.next()?;
        let s = parts.next()?;
        if parts.next().is_some() {
            return None;
        }
        let born = counts(b, 'B')?;
        let survive = counts(s, 'S')?;
        Some(Rule { born, survive })
    }
}

/// The counts `part` lists after its letter, `letter` or the same small,
/// as `[bool; 9]`: `B36` is `3` and `6`.
fn counts(part: &str, letter: char) -> Option<[bool; 9]> {
    let mut chars = part.chars();
    let first = chars.next()?;
    if first.to_ascii_uppercase() != letter {
        return None;
    }
    let mut seen = [false; 9];
    for c in chars {
        let d = c.to_digit(10)?;
        if d > 8 {
            return None;
        }
        seen[d as usize] = true;
    }
    Some(seen)
}

/// Writes the rule as `B3/S23`.
impl Display for Rule {
    fn fmt<W: Write>(&self, out: &mut W) -> Result<(), W::Error> with W::e {
        out.put("B")?;
        digits(out, &self.born)?;
        out.put("/S")?;
        digits(out, &self.survive)
    }
}

/// Writes each `n` for which `set[n]`, in order.
fn digits<W: Write>(out: &mut W, set: &[bool; 9]) -> Result<(), W::Error> with W::e {
    let mut n: usize = 0;
    while n < 9 {
        if set[n] {
            out.put(&n)?;
        }
        n = n + 1;
    }
    Ok(())
}

#[test]
fn rules_read_back() {
    let r = Rule::parse("B36/S23").unwrap();
    assert_eq(String::of(&r).as_str(), "B36/S23");
    assert(Rule::parse("b3/s23").unwrap() == Rule::conway());
    assert(Rule::parse("B2/S").unwrap().survive == [false; 9]);
    assert(Rule::parse("B9/S23").is_none());
    assert(Rule::parse("S23/B3").is_none());
    assert(Rule::parse("B3").is_none());
    assert(Rule::parse("B3/S2/S3").is_none());
    assert(Rule::parse("B3/S2x").is_none());
}
