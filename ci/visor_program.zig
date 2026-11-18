//! What a project that draws with visor and reads no Markdown writes:
//! `visor` alone, whose module graph holds nothing of datapad. Built by
//! `zig build check-markdown-consumer`.
const std = @import("std");
const visor = @import("visor");

pub fn main() void {
    _ = &visor.Screen.init;
    _ = &visor.Renderer.draw;
    _ = &visor.widgets.Paragraph.draw;
    _ = std;
}
