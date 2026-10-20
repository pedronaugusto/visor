test {
    _ = @import("visor.zig");
    // The widgets' tests, in the same binary: a binary of their own would
    // hold every base test they reach a second time.
    _ = @import("widgets_test.zig");
}
