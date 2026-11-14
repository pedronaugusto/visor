//! Where bytes from outside enter visor: what the terminal sends (keys, mouse reports, replies to
//! its queries), which morse's parsers refine, and a terminal's shared-memory picture read back
//! in a test. Each read is made here, so the entry points are these few. glint's A009 seam is
//! this file alone (glint.json).
const std = @import("std");
const Io = std.Io;

/// One read of `file` into `buffers`, as `File.readStreaming`: whatever the terminal has sent.
pub fn readStreaming(file: Io.File, io: Io, buffers: []const []u8) Io.File.ReadStreamingError!usize {
    return file.readStreaming(io, buffers);
}

/// Reads `file` at `offset` into `buffer` until it is full or the file ends, as
/// `File.readPositionalAll`.
pub fn readPositionalAll(file: Io.File, io: Io, buffer: []u8, offset: u64) Io.File.ReadPositionalError!usize {
    return file.readPositionalAll(io, buffer, offset);
}
