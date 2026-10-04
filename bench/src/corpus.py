"""Deterministic text inputs shared by every library; generated, never committed.

One directory per grid size. Widths are computed here by the same small
rule the verifier replays: East Asian Wide/Fullwidth is two columns, a
combining mark joins the cell before it, everything else is one. The `wide`
and `ascii` corpora hold only clusters every library measures alike; `emoji`
holds ZWJ sequences, flags, skin tones, keycaps and VS16 where they differ.
"""
import unicodedata
import struct
import zlib
from pathlib import Path

WORDS = ['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta', 'eta', 'theta', 'iota', 'kappa', 'lambda',
         'mu', 'omicron', 'rho', 'sigma', 'tau', 'upsilon', 'phi', 'chi', 'psi', 'omega', 'internationalization']
WIDE = ['漢字', '日本語', '中文字', '한국어', 'テスト', '😀', '🚀', '🎉', '🌍', '🔥', 'é', 'ñ', 'ä']
EMOJI = ['👨‍👩‍👧‍👦', '👩🏽‍💻', '🇯🇵', '🇧🇷', '👍🏻', '❤️', '1️⃣', '🏳️‍🌈',
         '漢字', 'é', 'x', 'ok', '😀', 'q̣̇']

def cols_of(text):
    width = 0
    for ch in text:
        if unicodedata.combining(ch) or unicodedata.category(ch) in ('Mn', 'Me'):
            continue
        width += 2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1
    return width

def fill_line(pieces, cols, seed):
    out, used, k = [], 0, seed
    while True:
        piece = pieces[k % len(pieces)]
        k += 3
        need = cols_of(piece) + (1 if out else 0)
        if used + need > cols:
            break
        out.append(piece)
        used += need
    return ' '.join(out)

def ascii_line(cols, seed):
    text = fill_line(WORDS, cols, seed)
    return (text + ' ' + 'x' * cols)[:cols]

def generate(root, cols, rows):
    d = Path(root) / f'{cols}x{rows}'
    d.mkdir(parents=True, exist_ok=True)
    (d / 'ascii.txt').write_text('\n'.join(ascii_line(cols, i) for i in range(rows * 2)) + '\n')
    (d / 'wide.txt').write_text('\n'.join(fill_line(WIDE + WORDS[:6], cols, i) for i in range(rows * 2)) + '\n')
    (d / 'emoji.txt').write_text('\n'.join(fill_line(EMOJI, cols * 2, i) for i in range(rows)) + '\n')
    log = [f'2026-10-03T12:{i // 60 % 60:02d}:{i % 60:02d}.{i % 1000:03d}Z INFO worker-{i % 8} request {i * 7919 % 100000} handled in {i % 97} ms' for i in range(rows * 3)]
    (d / 'log.txt').write_text('\n'.join(l[:cols] for l in log) + '\n')
    prose, used, i = [], 0, 0
    while used < cols * rows * 7 // 10:
        word = WORDS[(i * 7) % len(WORDS)]
        prose.append(word)
        used += len(word) + 1
        i += 1
    (d / 'prose.txt').write_text(' '.join(prose))
    sections = []
    for s in range(max(1, rows // 4)):
        sections.append(f'## Section {s}\n\nA paragraph with **strong {s}**, *emphasis*, `code {s}` and '
                        f'[a link](https://example.com/{s}) that runs long enough to wrap at most widths. '
                        + ' '.join(WORDS[(s + k) % len(WORDS)] for k in range(24)) + '\n\n'
                        f'- first item {s}\n- second item with _more_ words\n  - nested item\n1. numbered\n\n'
                        f'> quoted text {s}\n> > nested quote\n\n```zig\nconst x = {s};\nconst y = x + 1;\n```\n\n---\n')
    (d / 'doc.md').write_text('# Document\n\n' + '\n'.join(sections))
    # GFM tables and task lists: one table a section, as many rows as the
    # grid, every alignment, inline markup, a wide word and an escaped pipe.
    tables = []
    for s in range(max(1, rows // 4)):
        body = '\n'.join(f'| row {r} **{WORDS[r % len(WORDS)]}** | {r * 7919 % 1000} | 漢字 `{r}` | a \\| pipe and [link](https://example.com/{r}) |'
                         for r in range(rows))
        tables.append(f'## Tables {s}\n\n- [x] done task {s}\n- [ ] open task with `code`\n\n'
                      f'| name | size | kind | note |\n| :--- | ---: | :--: | ---- |\n{body}\n')
    (d / 'tables.md').write_text('\n'.join(tables))
    tones = ['', '🏻', '🏼', '🏽', '🏾', '🏿']
    jobs = ['💻', '🔬', '🎨', '🚀', '🍳', '🌾', '🏫', '🏭', '🔧', '🎤']
    pool = [base + tone + '‍' + job for base in ('👩', '👨') for tone in tones for job in jobs]
    pool += [chr(0x1F1E6 + a) + chr(0x1F1E6 + b) for a in range(26) for b in range(0, 26, 3)]
    (d / 'pool.txt').write_text('\n'.join(pool) + '\n')
    events = [b'a', b'Z', b'\x1b[A', b'\x1b[97;5u', b'\x1b[<0;10;5M', b'\x1b[<0;10;5m', b'\x1b[I', b'\x1b[O',
              b'\x1b[200~hello world\x1b[201~', b'\x1b[15~', 'é'.encode(), b'\x1b[1;5C']
    (d / 'input.bin').write_bytes(b''.join(events[i % len(events)] for i in range(cols * rows // 4)) + b'.')
    # One opaque red image; generation/PNG compression are outside samples.
    width, height = (cols - 1) * 8, (rows - 1) * 16
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress((b'\0' + bytes((255, 0, 0, 255)) * width) * height)) + chunk(b'IEND', b'')
    (d / 'picture.png').write_bytes(png)
    return d

def generate_all(root, sizes):
    for cols, rows in sizes:
        generate(root, cols, rows)
    return Path(root)
