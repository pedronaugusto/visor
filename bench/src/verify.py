"""Independent decoder for the deliberately small benchmark protocol subset.

ASCII grids, RGB/bold SGR, cursor addressing, erase, and kitty image/placement
commands only. Any unrecognized output fails rather than silently being ignored.
"""
import base64
import unicodedata
import hashlib
import json
import re

class Terminal:
    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.x = self.y = 0
        self.fg = self.bg = None
        self.bold = False
        self.grid = [(' ', None, False)] * (cols * rows)
        self.placements = {}
        self.images = {}
        self.commands = []
        self.upload = bytearray()
        self.upload_id = None
        self.saved = (0, 0)
        self.top, self.bottom = 0, rows - 1
        self.link = None
        self.links = set()
        self.last = None

    def scroll(self, n):
        span = list(range(self.top, self.bottom + 1))
        rows = [self.grid[r*self.cols:(r+1)*self.cols] for r in span]
        blank = [(' ', None, False)] * self.cols
        rows = (rows[n:] + [blank] * n) if n > 0 else ([blank] * -n + rows[:n])
        for r, content in zip(span, rows): self.grid[r*self.cols:(r+1)*self.cols] = content[:self.cols]

    def linefeed(self):
        # Line feed at the bottom margin scrolls the region, as a terminal does.
        if self.y == self.bottom: self.scroll(1)
        else: self.y += 1

    def autowrap(self, width):
        # Auto-margin with a pending wrap (am, xenl): a glyph that does not
        # fit starts the next line.
        if self.x + width > self.cols:
            self.x = 0
            self.linefeed()

    def put(self, x, y, ch):
        index = y * self.cols + x
        self.grid[index] = (ch, self.fg, self.bold) if self.link is None else (ch, self.fg, self.bold, self.link)
        if ch: self.last = index

    def text(self):
        rows = []
        for y in range(self.rows):
            rows.append(''.join(c[0] for c in self.grid[y*self.cols:(y+1)*self.cols]).rstrip(' '))
        return '\n'.join(rows)

    def feed(self, data):
        i = 0
        while i < len(data):
            if data[i:i+3] == b'\x1b_G':
                end = data.index(b'\x1b\\', i + 3)
                body = data[i+3:end]
                keys, sep, payload = body.partition(b';')
                fields = dict(part.decode().split('=', 1) for part in keys.split(b',') if part)
                action = fields.get('a', 't')
                self.commands.append(fields)
                if action == 'p':
                    assert int(fields.get('C', '0')) == 1, fields
                    image, placement = int(fields['i']), int(fields.get('p', '1'))
                    assert image in self.images, fields
                    self.placements[(image, placement)] = (self.x, self.y, int(fields.get('c', '0')), int(fields.get('r', '0')))
                elif action == 't':
                    if 'i' in fields: self.upload_id = int(fields['i'])
                    self.upload.extend(base64.b64decode(payload, validate=True))
                    if fields.get('m', '0') == '0':
                        assert self.upload_id == 7
                        assert bytes(self.upload) == bytes([31, 63, 127, 255]) * 256
                        self.images[self.upload_id] = hashlib.sha256(self.upload).hexdigest()
                        self.upload.clear()
                else:
                    raise AssertionError(('unexpected graphics action', fields))
                i = end + 2
            elif data[i:i+2] == b'\x1b]':
                # OSC 8 hyperlinks only; anything else fails.
                end = min(j for j in (data.find(b'\x1b\\', i), data.find(b'\x07', i)) if j >= 0)
                body = data[i+2:end].decode()
                assert body.startswith('8;'), body
                self.link = body.split(';', 2)[2] or None
                self.links.add(self.link) if self.link else None
                i = end + (2 if data[end] == 0x1b else 1)
            elif data[i:i+2] in (b'\x1b7', b'\x1b8'):
                if data[i+1] == ord('7'): self.saved = (self.x, self.y)
                else: self.x, self.y = self.saved
                i += 2
            elif data[i:i+2] == b'\x1b[':
                match = re.match(rb'\x1b\[([0-9;:?>]*)([A-Za-z])', data[i:])
                assert match, data[i:i+40]
                raw, final = match[1].decode(), match[2].decode()
                if raw.startswith(('?', '>')):
                    assert final in ('h', 'l', 'u'), (raw, final)
                else:
                    raw = re.sub(r'(38|48):2:(?:0)?:', r'\1;2;', raw)
                    nums = [int(n or '0') for n in raw.replace(':', ';').split(';')] if raw else [0]
                    n = nums[0] or 1
                    if final in ('H', 'f'):
                        # Terminals clamp an absolute position to the screen.
                        self.y = min(self.rows, nums[0] or 1) - 1
                        self.x = min(self.cols, (nums[1] or 1) if len(nums) > 1 else 1) - 1
                    elif final == 'G': self.x = min(self.cols, n) - 1
                    elif final == 'E': self.x, self.y = 0, min(self.rows - 1, self.y + n)
                    elif final == 'F': self.x, self.y = 0, max(0, self.y - n)
                    elif final == 'd': self.y = min(self.rows, n) - 1
                    elif final == 'A': self.y = max(0, self.y - n)
                    elif final == 'B': self.y = min(self.rows - 1, self.y + n)
                    elif final == 'C': self.x = min(self.cols - 1, self.x + n)
                    elif final == 'D': self.x = max(0, self.x - n)
                    elif final == 'm': self.sgr(nums)
                    elif final == 'J':
                        assert nums[0] in (0, 2), nums
                        start = 0 if nums[0] == 2 else self.y * self.cols + self.x
                        for k in range(start, len(self.grid)): self.grid[k] = (' ', self.fg, self.bold)
                    elif final == 'K':
                        end = self.cols if nums[0] == 0 else self.x + 1 if nums[0] == 1 else self.cols
                        start = self.x if nums[0] == 0 else 0
                        for x in range(start, end): self.grid[self.y * self.cols + x] = (' ', self.fg, self.bold)
                    elif final == 'X':
                        for x in range(self.x, min(self.cols, self.x + n)): self.put(x, self.y, ' ')
                    elif final == 'r':
                        self.top = (nums[0] or 1) - 1
                        self.bottom = (nums[1] if len(nums) > 1 and nums[1] else self.rows) - 1
                        self.x = self.y = 0
                    elif final in ('S', 'T'): self.scroll(n if final == 'S' else -n)
                    elif final == 's': self.saved = (self.x, self.y)
                    elif final == 'u': self.x, self.y = self.saved
                    else: raise AssertionError(('unrecognized CSI', raw, final))
                i += match.end()
            elif data[i] == 13:
                self.x = 0; i += 1
            elif data[i] == 10:
                self.linefeed(); i += 1
            elif 32 <= data[i] <= 126:
                self.autowrap(1)
                assert 0 <= self.x < self.cols and 0 <= self.y < self.rows, (self.x, self.y)
                assert self.bg is None
                self.put(self.x, self.y, chr(data[i]))
                self.x += 1
                i += 1
            elif data[i] >= 0xc0:
                # One UTF-8 codepoint: a mark joins the cluster before it,
                # East Asian Wide/Fullwidth takes two columns.
                size = 2 if data[i] < 0xe0 else 3 if data[i] < 0xf0 else 4
                ch = data[i:i+size].decode()
                i += size
                cp = ord(ch)
                if unicodedata.combining(ch) or unicodedata.category(ch) in ('Mn', 'Me', 'Cf') or 0x1F3FB <= cp <= 0x1F3FF or cp in (0xFE0E, 0xFE0F):
                    assert self.last is not None
                    c = self.grid[self.last]
                    self.grid[self.last] = (c[0] + ch,) + c[1:]
                    continue
                wide = unicodedata.east_asian_width(ch) in ('W', 'F')
                self.autowrap(1 + wide)
                assert 0 <= self.x + wide < self.cols and 0 <= self.y < self.rows, (self.x, self.y, ch)
                self.put(self.x, self.y, ch)
                if wide: self.put(self.x + 1, self.y, '')
                self.x += 1 + wide
            else:
                raise AssertionError(('unrecognized byte', data[i:i+40]))

    def sgr(self, nums):
        i = 0
        while i < len(nums):
            n = nums[i]
            if n == 0: self.fg = self.bg = None; self.bold = False
            elif n == 1: self.bold = True
            elif n == 22: self.bold = False
            elif n == 39: self.fg = None
            elif n == 49: self.bg = None
            elif n == 59: pass
            elif n in (38, 48):
                assert nums[i+1] == 2, nums
                # SGR 38:2::r:g:b permits an empty color-space field.
                offset = 2
                rgb = tuple(nums[i+offset:i+offset+3])
                assert len(rgb) == 3
                if n == 38: self.fg = rgb
                else: self.bg = rgb
                i += offset + 2
            else: raise AssertionError(('unrecognized SGR', nums))
            i += 1

def expected(cols, rows, heavy, salt):
    alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789'
    return [(alphabet[i % len(alphabet)], ((i*13 + salt*17) % 256, (i*7+31) % 256, (i*3+53) % 256) if heavy else None,
             (i+salt) % 2 == 0 if heavy else False) for i in range(cols * rows)]

def verify(task, cols, rows, frames, result):
    if task in ('buffer_diff', 'cell_reads'):
        assert not frames
        assert result['native_count'] == 3 * ((cols * rows + 96) // 97), result
        return {'status':'passed', 'changed_cells_per_pass':(cols * rows + 96) // 97}
    t = Terminal(cols, rows)
    picture = task.startswith('picture_')
    if picture:
        t.feed(bytes.fromhex(frames[0]))
        assert not t.placements and len(t.images) == 1
        frames = frames[1:]
    assert len(frames) == 4, (task, len(frames))
    digests = []
    for index, frame in enumerate(frames):
        previous_commands = len(t.commands)
        t.feed(bytes.fromhex(frame))
        want = expected(cols, rows, task == 'style_heavy', index % 2)
        if t.grid != want:
            j = next(j for j in range(len(want)) if t.grid[j] != want[j])
            raise AssertionError((task, index, j, t.grid[j], want[j]))
        if task.startswith('unchanged') and index > 0:
            # The backend may emit SGR reset on an empty diff, but no cells.
            assert result['native_count'] == 0, result
        if picture:
            x = index % 2 if task == 'picture_layers' else 0
            assert t.placements == {(7, 1):(x, 0, 2, 2)}, (task, index, t.placements)
            if task == 'picture_unchanged' and index > 0:
                assert len(t.commands) == previous_commands, (task, index)
        digests.append(hashlib.sha256(json.dumps(t.grid).encode()).hexdigest())
    return {'status':'passed', 'frame_sha256':digests, 'picture_placements':len(t.placements), 'images':t.images}
