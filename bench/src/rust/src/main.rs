use ratatui::{
    backend::{Backend, CrosstermBackend},
    buffer::Buffer,
    layout::Rect,
    style::{Color, Modifier},
};
use std::{
    hint::black_box,
    io::{self, Write},
    time::Instant,
};

fn paint(cols: u16, rows: u16, salt: usize, heavy: bool) -> Buffer {
    let mut b = Buffer::empty(Rect::new(0, 0, cols, rows));
    let alphabet = b"abcdefghijklmnopqrstuvwxyz0123456789";
    for y in 0..rows {
        for x in 0..cols {
            let i = y as usize * cols as usize + x as usize;
            let symbol =
                (alphabet[(i + if heavy { 0 } else { salt }) % alphabet.len()] as char).to_string();
            let c = &mut b[(x, y)];
            c.set_symbol(&symbol);
            if heavy {
                c.set_fg(Color::Rgb(
                    (i * 13 + salt * 17) as u8,
                    (i * 7 + 31) as u8,
                    (i * 3 + 53) as u8,
                ));
                if (i + salt) % 2 == 0 {
                    c.modifier = Modifier::BOLD;
                }
            }
        }
    }
    b
}
fn hex(data: &[u8]) {
    let mut out = io::stdout().lock();
    for b in data {
        write!(out, "{b:02x}").unwrap();
    }
    writeln!(out).unwrap();
}
fn main() -> io::Result<()> {
    ratatui::crossterm::style::force_color_output(true);
    let args: Vec<_> = std::env::args().collect();
    assert_eq!(args.len(), 6);
    let task = args[1].as_str();
    assert!(
        [
            "buffer_diff",
            "full_repaint",
            "unchanged_diff",
            "style_heavy"
        ]
        .contains(&task)
    );
    let timed = args[2] == "full";
    let check = args[2] == "check";
    let cols: u16 = args[3].parse().unwrap();
    let rows: u16 = args[4].parse().unwrap();
    let iterations: usize = args[5].parse().unwrap();
    assert!(cols >= 4 && rows >= 4 && iterations > 0);
    let heavy = task == "style_heavy";
    let a = paint(cols, rows, 0, heavy);
    let mut b = paint(cols, rows, if heavy { 1 } else { 0 }, heavy);
    if task == "buffer_diff" {
        for i in (0..b.content.len()).step_by(97) {
            b.content[i].set_symbol("!");
        }
    }
    let blank = Buffer::empty(a.area);
    let mut output = Vec::<u8>::with_capacity(cols as usize * rows as usize * 64 + 8192);
    if task != "buffer_diff" {
        {
            let mut backend = CrosstermBackend::new(&mut output);
            backend.draw(blank.diff(&a).into_iter())?;
            Backend::flush(&mut backend)?;
        }
        if check {
            hex(&output);
        }
        output.clear();
    }
    let mut count = 0;
    let mut bytes = 0;
    let mut style_elapsed = 0;
    let start = if timed && !heavy {
        Some(Instant::now())
    } else {
        None
    };
    for n in 0..iterations {
        let (from, to) = match task {
            "buffer_diff" => (&a, &b),
            "full_repaint" => (&blank, &a),
            "unchanged_diff" => (&a, &a),
            "style_heavy" if n % 2 == 0 => (&a, &b),
            "style_heavy" => (&b, &a),
            _ => unreachable!(),
        };
        let draw_start = if timed && heavy {
            Some(Instant::now())
        } else {
            None
        };
        let updates = from.diff(to);
        count += updates.len();
        black_box(&updates);
        if task != "buffer_diff" {
            output.clear();
            {
                let mut backend = CrosstermBackend::new(&mut output);
                backend.draw(updates.into_iter())?;
                Backend::flush(&mut backend)?;
            }
            bytes += output.len();
            black_box(&output);
            if let Some(start) = draw_start {
                style_elapsed += start.elapsed().as_nanos();
            }
            if check {
                hex(&output);
            }
        }
    }
    let ns = if heavy {
        style_elapsed
    } else {
        start.map(|s| s.elapsed().as_nanos()).unwrap_or(0)
    };
    println!("result\t{iterations}\t{count}\t{bytes}\t{ns}");
    Ok(())
}
