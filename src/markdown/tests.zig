//! The Markdown widget's tests: the root of `visor.markdown`'s test build.
test {
    _ = @import("markdown.zig");
    _ = @import("markdown_test.zig");
    _ = @import("gfm_test.zig");
    _ = @import("hostile_text_test.zig");
}
