//! The ratatui side of every operation it has: same protocol and corpus as
//! the visor ops program. Buffers, widgets' data and frames are built outside
//! the timed interval; one clock pair per batch unless a frame needs
//! preparation, which then sits outside a per-frame clock.
use pulldown_cmark::{Event, Parser, Tag};
use ratatui::{
    backend::{Backend, CrosstermBackend},
    buffer::{Buffer, CellWidth},
    crossterm::{
        event::{
            DisableBracketedPaste, DisableFocusChange, DisableMouseCapture, EnableBracketedPaste,
            EnableFocusChange, EnableMouseCapture,
        },
        queue,
        terminal::{EnterAlternateScreen, LeaveAlternateScreen},
    },
    layout::{Constraint, Layout, Rect},
    style::{Color, Modifier, Style},
    symbols::Marker,
    text::{Line, Span},
    widgets::{
        Axis, Bar, BarChart, BarGroup, Block, Chart, Dataset, Gauge, GraphType, LineGauge, List,
        ListState, Padding, Paragraph, Row, Scrollbar, ScrollbarOrientation, ScrollbarState,
        Sparkline, StatefulWidget, Table, TableState, Tabs, Widget, Wrap,
        calendar::{CalendarEventStore, Monthly},
        canvas::{Canvas, Line as CanvasLine, Points, Rectangle},
    },
};
use std::{
    hint::black_box,
    io::{self, Write},
    time::Instant,
};

const WORDS: [&str; 8] = [
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
];
const TABS: [&str; 12] = [
    "tab0", "tab1", "tab2", "tab3", "tab4", "tab5", "tab6", "tab7", "tab8", "tab9", "tab10",
    "tab11",
];

struct Clock {
    timed: bool,
    total: u128,
    started: Option<Instant>,
}
impl Clock {
    fn start(&mut self) {
        if self.timed {
            self.started = Some(Instant::now());
        }
    }
    fn stop(&mut self) {
        if let Some(s) = self.started.take() {
            self.total += s.elapsed().as_nanos();
        }
    }
}

struct Ctx {
    cols: u16,
    rows: u16,
    iterations: usize,
    check: bool,
    clock: Clock,
    corpus: String,
    count: usize,
    bytes: usize,
}
impl Ctx {
    fn file(&self, name: &str) -> String {
        std::fs::read_to_string(format!(
            "{}/{}x{}/{}",
            self.corpus, self.cols, self.rows, name
        ))
        .expect("corpus")
    }
    fn lines(&self, name: &str) -> Vec<String> {
        self.file(name)
            .trim_end_matches('\n')
            .split('\n')
            .map(String::from)
            .collect()
    }
    fn area(&self) -> Rect {
        Rect::new(0, 0, self.cols, self.rows)
    }
}

fn hex_line(tag: &str, data: &[u8]) {
    let mut out = io::stdout().lock();
    write!(out, "{tag}\t").unwrap();
    for b in data {
        write!(out, "{b:02x}").unwrap();
    }
    writeln!(out).unwrap();
}

/// Rows as text, covered columns skipped, rows right-trimmed: the canonical
/// grid every library prints.
fn dump(buf: &Buffer) {
    let mut text = String::new();
    for y in 0..buf.area.height {
        let start = text.len();
        let mut skip = 0u16;
        for x in 0..buf.area.width {
            if skip > 0 {
                skip -= 1;
                continue;
            }
            let sym = buf[(x, y)].symbol();
            text.push_str(if sym.is_empty() { " " } else { sym });
            skip = sym.cell_width().saturating_sub(1);
        }
        let trimmed = text[start..].trim_end_matches(' ').len();
        text.truncate(start + trimmed);
        if y + 1 < buf.area.height {
            text.push('\n');
        }
    }
    hex_line("grid", text.as_bytes());
}

fn rgb(i: usize, salt: usize) -> Color {
    Color::Rgb(
        (i.wrapping_mul(13).wrapping_add(salt.wrapping_mul(17))) as u8,
        (i.wrapping_mul(7).wrapping_add(31)) as u8,
        (i.wrapping_mul(3).wrapping_add(53)) as u8,
    )
}

/// One frame the way ratatui's Terminal::flush draws it: the diff iterator
/// straight into the backend, then a flush.
fn draw_frame(out: &mut Vec<u8>, from: &Buffer, to: &Buffer) -> io::Result<usize> {
    let mut n = 0;
    {
        let mut backend = CrosstermBackend::new(out);
        backend.draw(from.diff_iter(to).inspect(|_| n += 1))?;
        Backend::flush(&mut backend)?;
    }
    Ok(n)
}

fn cell_writes(c: &mut Ctx) {
    let mut buf = Buffer::empty(c.area());
    let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    c.clock.start();
    for n in 0..c.iterations {
        for y in 0..c.rows {
            for x in 0..c.cols {
                let i = y as usize * c.cols as usize + x as usize;
                let k = (i + n) % alphabet.len();
                let cell = &mut buf[(x, y)];
                cell.set_symbol(&alphabet[k..k + 1]).set_fg(rgb(i, n % 2));
                cell.modifier = if (i + n) % 2 == 0 {
                    Modifier::BOLD
                } else {
                    Modifier::empty()
                };
            }
        }
        c.count += c.cols as usize * c.rows as usize;
    }
    c.clock.stop();
    if c.check {
        dump(&buf);
    }
}

fn print_rows(c: &mut Ctx, name: &str) {
    let mut buf = Buffer::empty(c.area());
    let src = c.lines(name);
    c.clock.start();
    for n in 0..c.iterations {
        for y in 0..c.rows {
            let text = &src[(y as usize + n) % src.len()];
            buf.set_string(0, y, text, Style::new().fg(rgb(y as usize, n % 2)));
        }
        c.count += c.rows as usize;
    }
    c.clock.stop();
    if c.check {
        dump(&buf);
    }
}

fn fill_with(c: &Ctx, name: &str) -> Buffer {
    let mut buf = Buffer::empty(c.area());
    let src = c.lines(name);
    for y in 0..c.rows {
        buf.set_string(0, y, &src[y as usize % src.len()], Style::new());
    }
    buf
}

fn wide_repaint(c: &mut Ctx) -> io::Result<()> {
    let buf = fill_with(c, "wide.txt");
    let blank = Buffer::empty(c.area());
    let mut out = Vec::with_capacity(c.cols as usize * c.rows as usize * 64 + 8192);
    c.clock.start();
    for _ in 0..c.iterations {
        out.clear();
        c.count += draw_frame(&mut out, &blank, &buf)?;
        c.bytes += out.len();
        black_box(&out);
    }
    c.clock.stop();
    if c.check {
        dump(&buf);
        hex_line("wire", &out);
    }
    Ok(())
}

fn fill_clear(c: &mut Ctx) {
    let mut buf = Buffer::empty(c.area());
    let area = c.area();
    c.clock.start();
    for n in 0..c.iterations {
        buf.set_style(area, Style::new().bg(rgb(n, 1)));
        buf.reset();
        c.count += 2 * area.area() as usize;
    }
    c.clock.stop();
    if c.check {
        buf.set_style(area, Style::new().bg(rgb(1, 1)));
        dump(&buf);
    }
}

fn scroll_repaint(c: &mut Ctx) -> io::Result<()> {
    let src = c.lines("log.txt");
    let (area, rows) = (c.area(), c.rows);
    let frame = |first: usize| {
        let mut b = Buffer::empty(area);
        for y in 0..rows {
            b.set_string(0, y, &src[(first + y as usize) % src.len()], Style::new());
        }
        b
    };
    let mut prev = frame(0);
    let mut out = Vec::with_capacity(c.cols as usize * c.rows as usize * 64 + 8192);
    draw_frame(&mut out, &Buffer::empty(c.area()), &prev)?;
    if c.check {
        hex_line("wire", &out);
    }
    let mut count = 0;
    let mut bytes = 0;
    // Ratatui's way to show the scrolled log: render the next frame, then
    // diff it against the last one. The whole frame is clocked, as on every
    // side.
    c.clock.start();
    for n in 0..c.iterations {
        let next = frame(n + 1);
        out.clear();
        count += draw_frame(&mut out, &prev, &next)? + 1;
        bytes += out.len();
        if c.check {
            hex_line("wire", &out);
        }
        prev = next;
    }
    c.clock.stop();
    c.count = count;
    c.bytes = bytes;
    if c.check {
        dump(&prev);
    }
    Ok(())
}

fn resize(c: &mut Ctx) {
    let mut buf = fill_with(c, "ascii.txt");
    let small = Rect::new(0, 0, c.cols - 3, c.rows - 2);
    c.clock.start();
    for _ in 0..c.iterations {
        buf.resize(small);
        buf.resize(c.area());
        c.count += 2;
    }
    c.clock.stop();
    if c.check {
        hex_line(
            "value",
            format!("area={}x{}", buf.area.width, buf.area.height).as_bytes(),
        );
    }
}

fn copy_cells(c: &mut Ctx) {
    let src = fill_with(c, "wide.txt");
    let mut dst = Buffer::empty(c.area());
    c.clock.start();
    for _ in 0..c.iterations {
        dst.merge(&src);
        c.count += c.cols as usize * c.rows as usize;
    }
    c.clock.stop();
    if c.check {
        dump(&dst);
    }
}

fn modes(c: &mut Ctx) -> io::Result<()> {
    let mut out = Vec::with_capacity(4096);
    c.clock.start();
    for _ in 0..c.iterations {
        out.clear();
        queue!(
            out,
            EnterAlternateScreen,
            EnableMouseCapture,
            EnableFocusChange,
            EnableBracketedPaste
        )?;
        queue!(
            out,
            DisableBracketedPaste,
            DisableFocusChange,
            DisableMouseCapture,
            LeaveAlternateScreen
        )?;
        c.bytes += out.len();
        c.count += 1;
    }
    c.clock.stop();
    if c.check {
        hex_line("wire", &out);
    }
    Ok(())
}

fn text_width(c: &mut Ctx) {
    let src = c.lines("wide.txt");
    let mut total = 0;
    c.clock.start();
    for _ in 0..c.iterations {
        total = 0;
        for l in &src {
            total += Line::raw(l.as_str()).width();
        }
        black_box(total);
        c.count += src.len();
    }
    c.clock.stop();
    if c.check {
        println!("value\twidth={total}");
    }
}

fn graphemes(c: &mut Ctx) {
    let src = c.lines("emoji.txt");
    let (mut clusters, mut cols) = (0usize, 0usize);
    c.clock.start();
    for _ in 0..c.iterations {
        clusters = 0;
        cols = 0;
        for l in &src {
            let span = Span::raw(l.as_str());
            for g in span.styled_graphemes(Style::new()) {
                clusters += 1;
                cols += g.symbol.cell_width() as usize;
            }
        }
        black_box(cols);
        c.count += clusters;
    }
    c.clock.stop();
    if c.check {
        println!("value\tclusters={clusters}");
        println!("info\tcolumns={cols}");
    }
}

fn text_wrap(c: &mut Ctx) {
    let text = c.file("prose.txt");
    let p = Paragraph::new(text.as_str()).wrap(Wrap { trim: true });
    let mut n = 0;
    c.clock.start();
    for _ in 0..c.iterations {
        n = p.line_count(c.cols);
        black_box(n);
        c.count += n;
    }
    c.clock.stop();
    if c.check {
        println!("value\trows={n}");
    }
}

fn layout_split(c: &mut Ctx) {
    let outer = Layout::vertical([
        Constraint::Length(3),
        Constraint::Percentage(20),
        Constraint::Min(5),
        Constraint::Max(10),
        Constraint::Fill(1),
        Constraint::Fill(2),
    ])
    .spacing(1);
    let inner = Layout::horizontal([
        Constraint::Length(12),
        Constraint::Percentage(25),
        Constraint::Min(8),
        Constraint::Max(30),
        Constraint::Fill(1),
    ])
    .spacing(1);
    let mut report = String::new();
    c.clock.start();
    for n in 0..c.iterations {
        let rows = outer.split(c.area());
        for row in rows.iter() {
            let cells = inner.split(*row);
            black_box(&cells);
            c.count += cells.len();
            if c.check && n == 0 {
                for r in cells.iter() {
                    report += &format!("{},{},{},{};", r.x, r.y, r.width, r.height);
                }
            }
        }
        if c.check && n == 0 {
            for r in rows.iter() {
                report += &format!("R{},{},{},{};", r.x, r.y, r.width, r.height);
            }
        }
    }
    c.clock.stop();
    if c.check {
        println!("rects\t{report}");
    }
}

fn markdown_parse(c: &mut Ctx) {
    let source = c.file("doc.md");
    let mut blocks = 0;
    c.clock.start();
    for _ in 0..c.iterations {
        blocks = 0;
        let mut events = 0;
        for e in Parser::new(&source) {
            events += 1;
            if let Event::Start(
                Tag::Paragraph
                | Tag::Heading { .. }
                | Tag::Item
                | Tag::CodeBlock(_)
                | Tag::BlockQuote(_),
            ) = e
            {
                blocks += 1;
            }
        }
        black_box(events);
        c.count += events;
    }
    c.clock.stop();
    if c.check {
        println!("info\tblocks={blocks}");
    }
}

struct Data {
    prose: String,
    items: Vec<String>,
    table: Vec<[String; 4]>,
    series: Vec<u64>,
    bars: Vec<(u64, String)>,
    wave: Vec<(f64, f64)>,
    scatter: Vec<(f64, f64)>,
}

fn data(c: &Ctx, task: &str) -> Data {
    let n_items = c.rows as usize * 8;
    let wave_n = c.cols as usize * 2;
    let mut wave: Vec<(f64, f64)> = (0..wave_n)
        .map(|i| {
            let x = i as f64 * 100.0 / (wave_n - 1) as f64;
            (x, (x / 8.0).sin())
        })
        .collect();
    if task == "canvas" {
        for p in &mut wave {
            p.1 = (p.1 + 1.0) * 50.0;
        }
    }
    Data {
        prose: if task == "paragraph" {
            c.file("prose.txt")
        } else {
            String::new()
        },
        items: (0..n_items)
            .map(|i| format!("item {:05} {}", i, WORDS[i % WORDS.len()]))
            .collect(),
        table: (0..n_items)
            .map(|i| {
                [
                    format!("r{i}"),
                    format!("name-{}", i % 97),
                    format!("{}", (i * 7919) % 100000),
                    format!("state{}", i % 5),
                ]
            })
            .collect(),
        series: (0..c.cols as usize * 2)
            .map(|i| ((i * 37) % 101) as u64)
            .collect(),
        bars: (0..c.cols as usize / 4)
            .map(|i| (((i * 37) % 101) as u64, format!("b{}", i % 100)))
            .collect(),
        wave,
        scatter: (0..256)
            .map(|i| {
                (
                    ((i * 37) % 101) as f64,
                    ((i * 53) % 201) as f64 / 100.0 - 1.0,
                )
            })
            .collect(),
    }
}

fn widget(c: &mut Ctx, task: &str) {
    let d = data(c, task);
    let area = c.area();
    let mut buf = Buffer::empty(area);
    c.clock.start();
    for n in 0..c.iterations {
        match task {
            "block" => {
                let mut y = 0;
                while y + 6 <= c.rows {
                    let mut x = 0;
                    while x + 20 <= c.cols {
                        Block::bordered()
                            .title("title")
                            .padding(Padding::horizontal(1))
                            .render(Rect::new(x, y, 20, 6), &mut buf);
                        x += 20;
                    }
                    y += 6;
                }
            }
            "paragraph" => Paragraph::new(d.prose.as_str())
                .wrap(Wrap { trim: true })
                .render(area, &mut buf),
            "list" => {
                let mut state = ListState::default().with_selected(Some(d.items.len() / 2));
                let list = List::new(d.items.iter().map(String::as_str))
                    .highlight_symbol("> ")
                    .highlight_spacing(ratatui::widgets::HighlightSpacing::Always)
                    .highlight_style(Style::new().add_modifier(Modifier::REVERSED));
                StatefulWidget::render(list, area, &mut buf, &mut state);
            }
            "table" => {
                let mut state = TableState::default().with_selected(Some(d.table.len() / 2));
                let rows = d
                    .table
                    .iter()
                    .map(|r| Row::new(r.iter().map(String::as_str)));
                let table = Table::new(
                    rows,
                    [
                        Constraint::Length(8),
                        Constraint::Fill(1),
                        Constraint::Length(7),
                        Constraint::Percentage(20),
                    ],
                )
                .header(
                    Row::new(["id", "name", "value", "state"])
                        .style(Style::new().add_modifier(Modifier::BOLD)),
                )
                .row_highlight_style(Style::new().add_modifier(Modifier::REVERSED))
                .highlight_symbol("> ")
                .column_spacing(1);
                StatefulWidget::render(table, area, &mut buf, &mut state);
            }
            "tabs" => {
                for y in 0..c.rows {
                    Tabs::new(TABS)
                        .select(5)
                        .divider("│")
                        .render(Rect::new(0, y, c.cols, 1), &mut buf);
                }
            }
            "gauge" => Gauge::default()
                .ratio(0.6180339887)
                .label("61.8%")
                .render(area, &mut buf),
            "line_gauge" => {
                for y in 0..c.rows {
                    LineGauge::default()
                        .ratio((y + 1) as f64 / c.rows as f64)
                        .label("disk")
                        .render(Rect::new(0, y, c.cols, 1), &mut buf);
                }
            }
            "sparkline" => Sparkline::default().data(&d.series).render(area, &mut buf),
            "barchart" => {
                let bars: Vec<Bar> = d
                    .bars
                    .iter()
                    .map(|(v, l)| Bar::default().value(*v).label(Line::from(l.as_str())))
                    .collect();
                BarChart::default()
                    .data(BarGroup::default().bars(&bars))
                    .bar_width(3)
                    .bar_gap(1)
                    .render(area, &mut buf);
            }
            "chart" => {
                let datasets = vec![
                    Dataset::default()
                        .name("wave")
                        .marker(Marker::Braille)
                        .graph_type(GraphType::Line)
                        .data(&d.wave),
                    Dataset::default()
                        .name("dots")
                        .marker(Marker::Dot)
                        .graph_type(GraphType::Scatter)
                        .data(&d.scatter),
                ];
                Chart::new(datasets)
                    .x_axis(
                        Axis::default()
                            .title("x")
                            .bounds([0.0, 100.0])
                            .labels(["0", "50", "100"]),
                    )
                    .y_axis(
                        Axis::default()
                            .title("y")
                            .bounds([-1.0, 1.0])
                            .labels(["-1", "0", "1"]),
                    )
                    .render(area, &mut buf);
            }
            "scrollbar" => {
                let content = c.rows as usize * 10;
                let mut v = ScrollbarState::new(content)
                    .position((n * 7) % content)
                    .viewport_content_length(c.rows as usize);
                Scrollbar::new(ScrollbarOrientation::VerticalRight)
                    .begin_symbol(None)
                    .end_symbol(None)
                    .track_symbol(Some("│"))
                    .thumb_symbol("█")
                    .render(area, &mut buf, &mut v);
                let mut h = ScrollbarState::new(content)
                    .position((n * 7) % content)
                    .viewport_content_length(c.cols as usize);
                Scrollbar::new(ScrollbarOrientation::HorizontalBottom)
                    .begin_symbol(None)
                    .end_symbol(None)
                    .track_symbol(Some("│"))
                    .thumb_symbol("█")
                    .render(Rect::new(0, 0, c.cols - 1, c.rows), &mut buf, &mut h);
            }
            "canvas" => {
                Canvas::default()
                    .marker(Marker::Braille)
                    .x_bounds([0.0, 100.0])
                    .y_bounds([0.0, 100.0])
                    .paint(|ctx| {
                        for i in 0..32 {
                            let a = i as f64 * std::f64::consts::PI / 16.0;
                            ctx.draw(&CanvasLine::new(
                                50.0,
                                50.0,
                                50.0 + 45.0 * a.cos(),
                                50.0 + 45.0 * a.sin(),
                                Color::Reset,
                            ));
                        }
                        for i in 0..8 {
                            let dd = (i * 5) as f64;
                            ctx.draw(&Rectangle::new(
                                5.0 + dd,
                                5.0 + dd,
                                90.0 - 2.0 * dd,
                                90.0 - 2.0 * dd,
                                Color::Reset,
                            ));
                        }
                        for p in d.wave.windows(2) {
                            ctx.draw(&CanvasLine::new(
                                p[0].0,
                                p[0].1,
                                p[1].0,
                                p[1].1,
                                Color::Reset,
                            ));
                        }
                        let pts: Vec<(f64, f64)> = d
                            .scatter
                            .iter()
                            .map(|p| (p.0, (p.1 + 1.0) * 50.0))
                            .collect();
                        ctx.draw(&Points::new(&pts, Color::Reset));
                    })
                    .render(area, &mut buf);
            }
            "calendar" => {
                let events = CalendarEventStore::default();
                let mut month = 1u8;
                let mut year = 2026;
                let mut y = 0;
                while y + 8 <= c.rows {
                    let mut x = 0;
                    while x + 20 <= c.cols {
                        let date = time::Date::from_calendar_date(
                            year,
                            time::Month::try_from(month).unwrap(),
                            1,
                        )
                        .unwrap();
                        Monthly::new(date, &events)
                            .show_month_header(Style::new())
                            .show_weekdays_header(Style::new())
                            .render(Rect::new(x, y, 21, 8), &mut buf);
                        month += 1;
                        if month > 12 {
                            month = 1;
                            year += 1;
                        }
                        x += 22;
                    }
                    y += 9;
                }
            }
            _ => panic!("unknown widget {task}"),
        }
        c.count += 1;
    }
    c.clock.stop();
    if c.check {
        dump(&buf);
    }
}

fn main() -> io::Result<()> {
    ratatui::crossterm::style::force_color_output(true);
    let args: Vec<_> = std::env::args().collect();
    assert_eq!(args.len(), 6);
    let task = args[1].as_str();
    let mut c = Ctx {
        cols: args[3].parse().unwrap(),
        rows: args[4].parse().unwrap(),
        iterations: args[5].parse().unwrap(),
        check: args[2] == "check",
        clock: Clock {
            timed: args[2] == "full",
            total: 0,
            started: None,
        },
        corpus: std::env::var("VISOR_BENCH_CORPUS").expect("VISOR_BENCH_CORPUS"),
        count: 0,
        bytes: 0,
    };
    assert!(c.cols >= 8 && c.rows >= 4 && c.iterations > 0);
    match task {
        "cell_writes" => cell_writes(&mut c),
        "print_rows" => print_rows(&mut c, "ascii.txt"),
        "wide_print" => print_rows(&mut c, "wide.txt"),
        "wide_repaint" => wide_repaint(&mut c)?,
        "fill_clear" => fill_clear(&mut c),
        "scroll_repaint" => scroll_repaint(&mut c)?,
        "resize" => resize(&mut c),
        "copy_cells" => copy_cells(&mut c),
        "modes" => modes(&mut c)?,
        "text_width" => text_width(&mut c),
        "graphemes" => graphemes(&mut c),
        "text_wrap" => text_wrap(&mut c),
        "layout_split" => layout_split(&mut c),
        "markdown_parse" => markdown_parse(&mut c),
        "block" | "paragraph" | "list" | "table" | "tabs" | "gauge" | "line_gauge"
        | "sparkline" | "barchart" | "chart" | "scrollbar" | "canvas" | "calendar" => {
            widget(&mut c, task)
        }
        _ => panic!("unavailable: {task}"),
    }
    println!(
        "result\t{}\t{}\t{}\t{}",
        c.iterations, c.count, c.bytes, c.clock.total
    );
    Ok(())
}
