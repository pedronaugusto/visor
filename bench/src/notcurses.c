// Fixed in-memory text frames. No application terminal is opened by this
// process: the runner starts a new session and supplies a null input stream.
#include <notcurses/notcurses.h>
#include <assert.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <dlfcn.h>
#include <errno.h>

// Notcurses 3.0.17's render_to_buffer omits postpaint and returns an
// empty frame. Keep the library unchanged: use its working public rasterize
// API and replace writes to the dedicated sink with a reusable memory writer.
// All other writes retain libc behavior. The full renderer's signal masking
// and intrinsic statistics remain part of the job.
static int sink_fd = -1;
static int capturing = 0;
static char *output = NULL;
static size_t output_len = 0, output_capacity = 0;
static ssize_t (*real_write)(int, const void *, size_t) = NULL;
ssize_t write(int fd, const void *data, size_t len) {
    if (capturing && fd == sink_fd) {
        if (output_len + len > output_capacity) {
            size_t capacity = (output_len + len) * 2 + 8192;
            char *next = realloc(output, capacity);
            if (!next) { errno = ENOMEM; return -1; }
            output = next; output_capacity = capacity;
        }
        memcpy(output + output_len, data, len);
        output_len += len;
        return (ssize_t)len;
    }
    if (!real_write) real_write = (ssize_t (*)(int, const void *, size_t))dlsym(RTLD_NEXT, "write");
    assert(real_write);
    return real_write(fd, data, len);
}
static unsigned long long nanos(void) {
    struct timespec t;
    assert(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return (unsigned long long)t.tv_sec * 1000000000ull + t.tv_nsec;
}
static void hex(const char *data, size_t len) {
    for (size_t i = 0; i < len; ++i) printf("%02x", (unsigned char)data[i]);
    putchar('\n');
}
static void paint(struct ncplane *p, unsigned cols, unsigned rows, unsigned salt, int heavy) {
    const char *alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    for (unsigned y = 0; y < rows; ++y) {
        for (unsigned x = 0; x < cols; ++x) {
            unsigned i = y * cols + x;
            ncplane_set_styles(p, heavy && (i + salt) % 2 == 0 ? NCSTYLE_BOLD : 0);
            if (heavy) {
                assert(ncplane_set_fg_rgb8(p, (i * 13 + salt * 17) % 256, (i * 7 + 31) % 256, (i * 3 + 53) % 256) == 0);
            } else ncplane_set_fg_default(p);
            char s[2] = {alphabet[(i + (heavy ? 0 : salt)) % 36], 0};
            // Writing the bottom-right cell can report a cursor advance
            // failure after the cell was written; inspect content via the oracle.
            (void)ncplane_putstr_yx(p, y, x, s);
        }
    }
}
static size_t render(struct ncplane *p, int check) {
    output_len = 0;
    capturing = 1;
    assert(ncpile_render(p) == 0);
    assert(ncpile_rasterize(p) == 0);
    capturing = 0;
    if (check) hex(output, output_len);
    return output_len;
}
int main(int argc, char **argv) {
    assert(argc == 6);
    const char *task = argv[1];
    int check = strcmp(argv[2], "check") == 0;
    int timed = strcmp(argv[2], "full") == 0;
    unsigned cols = (unsigned)strtoul(argv[3], NULL, 10);
    unsigned rows = (unsigned)strtoul(argv[4], NULL, 10);
    unsigned iterations = (unsigned)strtoul(argv[5], NULL, 10);
    assert(cols >= 4 && rows >= 4 && iterations > 0);
    assert(strcmp(task, "full_repaint") == 0 || strcmp(task, "style_heavy") == 0 || strcmp(task, "unchanged_diff") == 0);
    setlocale(LC_ALL, "");
    struct notcurses_options opts = {
        .termtype = "xterm-direct", .loglevel = NCLOGLEVEL_SILENT,
        .flags = NCOPTION_SUPPRESS_BANNERS | NCOPTION_NO_ALTERNATE_SCREEN |
                 NCOPTION_NO_WINCH_SIGHANDLER | NCOPTION_NO_QUIT_SIGHANDLERS |
                 NCOPTION_NO_FONT_CHANGES | NCOPTION_NO_CLEAR_BITMAPS,
    };
    FILE *sink = fopen("/dev/null", "w");
    assert(sink);
    sink_fd = fileno(sink);
    struct notcurses *nc = notcurses_core_init(&opts, sink);
    assert(nc);
    struct ncplane *p = notcurses_stdplane(nc);
    unsigned got_rows, got_cols;
    ncplane_dim_yx(p, &got_rows, &got_cols);
    assert(got_rows == rows && got_cols == cols);
    int heavy = strcmp(task, "style_heavy") == 0;
    output_capacity = (size_t)cols * rows * 64 + 8192;
    output = malloc(output_capacity);
    assert(output);
    paint(p, cols, rows, 0, heavy);
    render(p, check);
    unsigned long long elapsed = 0;
    size_t bytes = 0;
    int per_frame_clock = heavy || strcmp(task, "full_repaint") == 0;
    unsigned long long batch_start = timed && !per_frame_clock ? nanos() : 0;
    for (unsigned n = 0; n < iterations; ++n) {
        if (strcmp(task, "full_repaint") == 0) {
            // Establish an entirely different baseline outside the interval,
            // then emit every requested cell. No private renderer state changed.
            paint(p, cols, rows, 1, 0);
            render(p, 0);
            paint(p, cols, rows, 0, 0);
        } else if (heavy) paint(p, cols, rows, (n + 1) % 2, 1);
        unsigned long long start = timed && per_frame_clock ? nanos() : 0;
        size_t len = render(p, check);
        if (timed && per_frame_clock) elapsed += nanos() - start;
        bytes += len;
    }
    if (timed && !per_frame_clock) elapsed = nanos() - batch_start;
    printf("result\t%u\t%d\t%zu\t%llu\n", iterations, strcmp(task, "unchanged_diff") == 0 ? 0 : -1, bytes, elapsed);
    assert(notcurses_stop(nc) == 0);
    fclose(sink);
    free(output);
    return 0;
}
