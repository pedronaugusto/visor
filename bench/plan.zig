//! Which workloads a pass runs: the drawing core of `draw.zig` and every
//! operation of `ops.zig`.

const std = @import("std");

/// The drawing-core workloads of `draw.zig`.
pub const core = [_][]const u8{
    "cell_reads",
    "buffer_diff",
    "full_repaint",
    "unchanged_diff",
    "style_heavy",
    "unchanged_idle",
    "picture_layers",
    "picture_unchanged",
};

/// Every operation workload of `ops.zig`.
pub const ops = [_][]const u8{
    "cell_writes",
    "print_rows",
    "wide_print",
    "wide_repaint",
    "fill_clear",
    "scroll_rows",
    "scroll_repaint",
    "resize",
    "copy_cells",
    "copy_text",
    "links",
    "grapheme_pool",
    "modes",
    "text_width",
    "graphemes",
    "width_models",
    "text_wrap",
    "text_fit",
    "text_fit_end",
    "layout_split",
    "layout_repeat",
    "block",
    "paragraph",
    "markdown_parse",
    "markdown_draw",
    "markdown_table_parse",
    "markdown_table_draw",
    "tree",
    "print_above",
    "text_edit",
    "list",
    "table",
    "tabs",
    "gauge",
    "line_gauge",
    "sparkline",
    "barchart",
    "chart",
    "scrollbar",
    "canvas",
    "canvas_raster",
    "calendar",
    "text_input",
    "keys",
    "rule",
    "edges",
    "sextants",
    "input_events",
    "term_feed",
    "picture_frame_kitty",
    "picture_frame_sixel",
    "picture_frame_iterm",
    "picture_frame_cells",
    "picture_transmit",
    "picture_replace",
};

/// Fewer frames a sample where one frame is slow (a full-window pixel
/// raster is ~10 ms at 200x60); units stay per frame.
pub fn iterations(task: []const u8, default: usize) usize {
    for ([_][]const u8{ "canvas_raster", "picture_frame_sixel" }) |slow| {
        if (std.mem.eql(u8, task, slow)) return @min(default, 100);
    }
    return default;
}

test "the plan's counts: 55 operations, 8 drawing-core workloads" {
    try std.testing.expectEqual(@as(usize, 55), ops.len);
    try std.testing.expectEqual(@as(usize, 8), core.len);
}
