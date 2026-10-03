// The notcurses side of every operation it has, on the same corpus and
// protocol as the visor ops program. Headless like notcurses.c: a fixed
// RGB terminfo profile, no controlling terminal, frames captured from the
// dedicated sink into memory. Fixtures are built before any clock.
#include <notcurses/notcurses.h>
#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int sink_fd = -1, capturing = 0;
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
static int timed = 0, check = 0;
static unsigned long long elapsed = 0, started = 0;
static void start(void) { if (timed) started = nanos(); }
static void stop(void) { if (timed) elapsed += nanos() - started; }

static void hex(const char *tag, const char *data, size_t len) {
    printf("%s\t", tag);
    for (size_t i = 0; i < len; ++i) printf("%02x", (unsigned char)data[i]);
    putchar('\n');
}

static unsigned cols, rows;
static const char *corpus;
static char *slurp(const char *name, size_t *len) {
    char path[4096];
    snprintf(path, sizeof path, "%s/%ux%u/%s", corpus, cols, rows, name);
    FILE *f = fopen(path, "rb");
    assert(f);
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)n + 1);
    assert(buf && fread(buf, 1, (size_t)n, f) == (size_t)n);
    buf[n] = 0;
    fclose(f);
    if (len) *len = (size_t)n;
    return buf;
}
static char **lines(const char *name, size_t *count) {
    char *data = slurp(name, NULL);
    size_t cap = 64, n = 0;
    char **out = malloc(cap * sizeof *out);
    for (char *p = data; *p;) {
        char *nl = strchr(p, '\n');
        if (nl) *nl = 0;
        if (n == cap) out = realloc(out, (cap *= 2) * sizeof *out);
        out[n++] = p;
        if (!nl) break;
        p = nl + 1;
    }
    *count = n;
    return out;
}

// Rows as text: each head cell's cluster, covered columns skipped, rows
// right-trimmed, joined by newlines; the canonical grid every library prints.
static void dump(struct ncplane *p) {
    unsigned h, w;
    ncplane_dim_yx(p, &h, &w);
    size_t cap = (size_t)h * w * 16 + 16, len = 0;
    char *text = malloc(cap);
    for (unsigned y = 0; y < h; ++y) {
        size_t row = len;
        for (unsigned x = 0; x < w; ++x) {
            uint16_t style; uint64_t channels;
            char *egc = ncplane_at_yx(p, (int)y, (int)x, &style, &channels);
            const char *g = egc && *egc ? egc : " ";
            size_t gl = strlen(g);
            memcpy(text + len, g, gl);
            len += gl;
            int width = ncstrwidth(g, NULL, NULL);
            free(egc);
            if (width > 1) x += (unsigned)width - 1;
        }
        while (len > row && text[len - 1] == ' ') --len;
        if (y + 1 < h) text[len++] = '\n';
    }
    hex("grid", text, len);
    free(text);
}

static uint64_t fg_rgb(unsigned i, unsigned salt) {
    uint64_t ch = 0;
    ncchannels_set_fg_rgb8(&ch, (i * 13 + salt * 17) % 256, (i * 7 + 31) % 256, (i * 3 + 53) % 256);
    return ch;
}

static struct notcurses *nc;
static struct ncplane *std_plane;
static size_t count = 0, bytes = 0;

// Everything written to the sink since the last frame is that frame: the
// standard plane renders on its own when it scrolls, and those bytes belong
// to the frame that scrolled.
static size_t render(int show) {
    assert(ncpile_render(std_plane) == 0);
    assert(ncpile_rasterize(std_plane) == 0);
    size_t len = output_len;
    if (show) hex("wire", output, len);
    output_len = 0;
    return len;
}

static void put_rows(char **src, size_t n, unsigned first) {
    for (unsigned y = 0; y < rows; ++y) {
        ncplane_set_fg_default(std_plane);
        (void)ncplane_putstr_yx(std_plane, (int)y, 0, src[(first + y) % n]);
    }
}

static void cell_writes(unsigned iterations) {
    const char *alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    start();
    for (unsigned n = 0; n < iterations; ++n) {
        for (unsigned y = 0; y < rows; ++y) for (unsigned x = 0; x < cols; ++x) {
            unsigned i = y * cols + x;
            char s[2] = {alphabet[(i + n) % 36], 0};
            ncplane_set_styles(std_plane, (i + n) % 2 == 0 ? NCSTYLE_BOLD : 0);
            ncplane_set_channels(std_plane, fg_rgb(i, n % 2));
            (void)ncplane_putegc_yx(std_plane, (int)y, (int)x, s, NULL);
        }
        count += (size_t)cols * rows;
    }
    stop();
    if (check) dump(std_plane);
}

static void print_rows(const char *name, unsigned iterations) {
    size_t n;
    char **src = lines(name, &n);
    start();
    for (unsigned k = 0; k < iterations; ++k) {
        for (unsigned y = 0; y < rows; ++y) {
            ncplane_set_channels(std_plane, fg_rgb(y, k % 2));
            (void)ncplane_putstr_yx(std_plane, (int)y, 0, src[(y + k) % n]);
        }
        count += rows;
    }
    stop();
    if (check) dump(std_plane);
}

static void wide_repaint(unsigned iterations) {
    size_t n, an;
    char **src = lines("wide.txt", &n);
    char **base = lines("ascii.txt", &an);
    for (unsigned k = 0; k < iterations; ++k) {
        // A different complete baseline outside the interval, then the
        // wide frame, exactly as full_repaint does.
        ncplane_erase(std_plane);
        put_rows(base, an, 0);
        render(check);
        ncplane_erase(std_plane);
        put_rows(src, n, 0);
        start();
        bytes += render(check);
        stop();
        count += 1;
    }
    if (check) dump(std_plane);
}

static void fill_clear(unsigned iterations) {
    start();
    for (unsigned k = 0; k < iterations; ++k) {
        uint64_t ch = 0;
        ncchannels_set_bg_rgb8(&ch, (k * 13 + 17) % 256, (k * 7 + 31) % 256, (k * 3 + 53) % 256);
        ncplane_set_base(std_plane, " ", 0, ch);
        ncplane_erase(std_plane);
        ncplane_set_base(std_plane, " ", 0, 0);
        ncplane_erase(std_plane);
        count += 2 * (size_t)cols * rows;
    }
    stop();
    if (check) dump(std_plane);
}

static void scroll_rows(unsigned iterations, int repaint) {
    size_t n;
    char **src = lines("log.txt", &n);
    // A full-size scrolling child plane. Scrolling the standard plane
    // instead renders on its own and scrolls the terminal physically, but
    // in 3.0.17 that frame writes a blank at column 1 of the old last row
    // before the scroll, so it does not decode to the plane (see README).
    struct ncplane_options o = {.rows = rows, .cols = cols};
    struct ncplane *p = ncplane_create(std_plane, &o);
    assert(p);
    ncplane_set_scrolling(p, 1);
    for (unsigned y = 0; y < rows; ++y) (void)ncplane_putstr_yx(p, (int)y, 0, src[y % n]);
    if (repaint) render(check);
    // A newline on the last row scrolls the plane; the whole frame (scroll,
    // new row, render) is clocked, as on every side.
    start();
    for (unsigned k = 0; k < iterations; ++k) {
        assert(ncplane_cursor_move_yx(p, (int)rows - 1, (int)cols - 1) == 0);
        assert(ncplane_putchar(p, '\n') >= 0);
        (void)ncplane_putstr_yx(p, (int)rows - 1, 0, src[(rows + k) % n]);
        count += 1;
        if (repaint) bytes += render(check);
    }
    stop();
    if (check) dump(p);
}

static void resize(unsigned iterations) {
    size_t n;
    char **src = lines("ascii.txt", &n);
    struct ncplane_options o = {.rows = rows, .cols = cols};
    struct ncplane *p = ncplane_create(std_plane, &o);
    assert(p);
    for (unsigned y = 0; y < rows; ++y) (void)ncplane_putstr_yx(p, (int)y, 0, src[y % n]);
    start();
    for (unsigned k = 0; k < iterations; ++k) {
        assert(ncplane_resize_simple(p, rows - 2, cols - 3) == 0);
        assert(ncplane_resize_simple(p, rows, cols) == 0);
        count += 2;
    }
    stop();
    if (check) dump(p);
}

static void copy_cells(unsigned iterations) {
    size_t n;
    char **src = lines("wide.txt", &n);
    struct ncplane_options o = {.rows = rows, .cols = cols};
    struct ncplane *from = ncplane_create(std_plane, &o);
    struct ncplane *to = ncplane_create(std_plane, &o);
    assert(from && to);
    for (unsigned y = 0; y < rows; ++y) (void)ncplane_putstr_yx(from, (int)y, 0, src[y % n]);
    start();
    for (unsigned k = 0; k < iterations; ++k) {
        assert(ncplane_mergedown_simple(from, to) == 0);
        count += (size_t)cols * rows;
    }
    stop();
    if (check) dump(to);
}

static void copy_text(unsigned iterations) {
    size_t n;
    char **src = lines("wide.txt", &n);
    put_rows(src, n, 0);
    char *text = NULL;
    start();
    for (unsigned k = 0; k < iterations; ++k) {
        free(text);
        text = ncplane_contents(std_plane, 0, 0, 0, 0);
        assert(text);
        bytes += strlen(text);
        count += rows;
    }
    stop();
    if (check) hex("text", text, strlen(text));
    free(text);
}

static void text_width(unsigned iterations) {
    size_t n;
    char **src = lines("wide.txt", &n);
    long total = 0;
    start();
    for (unsigned k = 0; k < iterations; ++k) {
        total = 0;
        for (size_t i = 0; i < n; ++i) total += ncstrwidth(src[i], NULL, NULL);
        count += n;
    }
    stop();
    if (check) printf("value\twidth=%ld\n", total);
}

static void paragraph(unsigned iterations) {
    char *text = slurp("prose.txt", NULL);
    start();
    for (unsigned k = 0; k < iterations; ++k) {
        size_t written = 0;
        // puttext continues from the cursor's column; a redraw starts home.
        ncplane_home(std_plane);
        (void)ncplane_puttext(std_plane, 0, NCALIGN_LEFT, text, &written);
        count += 1;
    }
    stop();
    if (check) dump(std_plane);
}

static void block(unsigned iterations) {
    nccell ul = NCCELL_TRIVIAL_INITIALIZER, ur = NCCELL_TRIVIAL_INITIALIZER, ll = NCCELL_TRIVIAL_INITIALIZER,
           lr = NCCELL_TRIVIAL_INITIALIZER, hl = NCCELL_TRIVIAL_INITIALIZER, vl = NCCELL_TRIVIAL_INITIALIZER;
    assert(nccells_load_box(std_plane, 0, 0, &ul, &ur, &ll, &lr, &hl, &vl, "┌┐└┘─│") == 0);
    start();
    for (unsigned k = 0; k < iterations; ++k) {
        for (unsigned y = 0; y + 6 <= rows; y += 6) for (unsigned x = 0; x + 20 <= cols; x += 20) {
            assert(ncplane_cursor_move_yx(std_plane, (int)y, (int)x) == 0);
            assert(ncplane_box(std_plane, &ul, &ur, &ll, &lr, &hl, &vl, y + 5, x + 19, 0) == 0);
            (void)ncplane_putstr_yx(std_plane, (int)y, (int)x + 1, "title");
        }
        count += 1;
    }
    stop();
    if (check) dump(std_plane);
}

static void gauge(unsigned iterations) {
    struct ncplane_options o = {.rows = rows, .cols = cols};
    struct ncplane *p = ncplane_create(std_plane, &o);
    ncprogbar_options po = {0};
    struct ncprogbar *bar = ncprogbar_create(p, &po);
    assert(bar);
    start();
    for (unsigned k = 0; k < iterations; ++k) {
        assert(ncprogbar_set_progress(bar, 0.6180339887) == 0);
        count += 1;
    }
    stop();
    if (check) dump(ncprogbar_plane(bar));
}

static void sparkline(unsigned iterations) {
    struct ncplane_options o = {.rows = rows, .cols = cols};
    struct ncplane *p = ncplane_create(std_plane, &o);
    ncplot_options po = {.gridtype = NCBLIT_8x1, .rangex = (int)cols};
    struct ncuplot *plot = ncuplot_create(p, &po, 0, 100);
    assert(plot);
    unsigned total = cols * 2;
    for (unsigned i = 0; i < total; ++i) assert(ncuplot_add_sample(plot, i, (i * 37) % 101) == 0);
    start();
    for (unsigned k = 0; k < iterations; ++k) {
        // Setting the newest sample redraws the whole plot.
        assert(ncuplot_set_sample(plot, total - 1, ((total - 1) * 37) % 101) == 0);
        count += 1;
    }
    stop();
    if (check) dump(ncuplot_plane(plot));
}

static void rule(unsigned iterations) {
    nccell c = NCCELL_TRIVIAL_INITIALIZER;
    assert(nccell_load(std_plane, &c, "─") > 0);
    start();
    for (unsigned k = 0; k < iterations; ++k) {
        for (unsigned y = 0; y < rows; ++y) {
            assert(ncplane_cursor_move_yx(std_plane, (int)y, 0) == 0);
            (void)ncplane_hline(std_plane, &c, cols);
        }
        count += 1;
    }
    stop();
    if (check) dump(std_plane);
}

int main(int argc, char **argv) {
    assert(argc == 6);
    const char *task = argv[1];
    check = strcmp(argv[2], "check") == 0;
    timed = strcmp(argv[2], "full") == 0;
    cols = (unsigned)strtoul(argv[3], NULL, 10);
    rows = (unsigned)strtoul(argv[4], NULL, 10);
    unsigned iterations = (unsigned)strtoul(argv[5], NULL, 10);
    corpus = getenv("VISOR_BENCH_CORPUS");
    assert(corpus && cols >= 8 && rows >= 4 && iterations > 0);
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
    nc = notcurses_core_init(&opts, sink);
    assert(nc && notcurses_canutf8(nc));
    std_plane = notcurses_stdplane(nc);
    unsigned got_rows, got_cols;
    ncplane_dim_yx(std_plane, &got_rows, &got_cols);
    assert(got_rows == rows && got_cols == cols);
    output_capacity = (size_t)cols * rows * 64 + 8192;
    output = malloc(output_capacity);
    capturing = 1;
    if (!strcmp(task, "cell_writes")) cell_writes(iterations);
    else if (!strcmp(task, "print_rows")) print_rows("ascii.txt", iterations);
    else if (!strcmp(task, "wide_print")) print_rows("wide.txt", iterations);
    else if (!strcmp(task, "wide_repaint")) wide_repaint(iterations);
    else if (!strcmp(task, "fill_clear")) fill_clear(iterations);
    else if (!strcmp(task, "scroll_rows")) scroll_rows(iterations, 0);
    else if (!strcmp(task, "scroll_repaint")) scroll_rows(iterations, 1);
    else if (!strcmp(task, "resize")) resize(iterations);
    else if (!strcmp(task, "copy_cells")) copy_cells(iterations);
    else if (!strcmp(task, "copy_text")) copy_text(iterations);
    else if (!strcmp(task, "text_width")) text_width(iterations);
    else if (!strcmp(task, "paragraph")) paragraph(iterations);
    else if (!strcmp(task, "block")) block(iterations);
    else if (!strcmp(task, "gauge")) gauge(iterations);
    else if (!strcmp(task, "sparkline")) sparkline(iterations);
    else if (!strcmp(task, "rule")) rule(iterations);
    else { fprintf(stderr, "unavailable: %s\n", task); return 2; }
    printf("result\t%u\t%zu\t%zu\t%llu\n", iterations, count, bytes, elapsed);
    fflush(stdout);
    capturing = 0;
    assert(notcurses_stop(nc) == 0);
    fclose(sink);
    return 0;
}
