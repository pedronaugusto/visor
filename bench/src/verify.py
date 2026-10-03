"""Independent decoder for the deliberately small benchmark protocol subset.

ASCII grids, RGB/bold SGR, cursor addressing, erase, and kitty image/placement
commands only. Any unrecognized output fails rather than silently being ignored.
"""
import base64
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
                        self.y = (nums[0] or 1) - 1
                        self.x = (nums[1] or 1) - 1 if len(nums) > 1 else 0
                    elif final == 'G': self.x = n - 1
                    elif final == 'd': self.y = n - 1
                    elif final == 'A': self.y = max(0, self.y - n)
                    elif final == 'B': self.y = min(self.rows - 1, self.y + n)
                    elif final == 'C': self.x = min(self.cols - 1, self.x + n)
                    elif final == 'D': self.x = max(0, self.x - n)
                    elif final == 'm': self.sgr(nums)
                    elif final == 'J':
                        assert nums[0] == 2, nums
                        self.grid = [(' ', self.fg, self.bold)] * len(self.grid)
                    elif final == 'K':
                        end = self.cols if nums[0] == 0 else self.x + 1 if nums[0] == 1 else self.cols
                        start = self.x if nums[0] == 0 else 0
                        for x in range(start, end): self.grid[self.y * self.cols + x] = (' ', self.fg, self.bold)
                    elif final == 's': self.saved = (self.x, self.y)
                    elif final == 'u': self.x, self.y = self.saved
                    else: raise AssertionError(('unrecognized CSI', raw, final))
                i += match.end()
            elif data[i] == 13:
                self.x = 0; i += 1
            elif data[i] == 10:
                self.y += 1; i += 1
            elif 32 <= data[i] <= 126:
                assert 0 <= self.x < self.cols and 0 <= self.y < self.rows, (self.x, self.y)
                assert self.bg is None
                self.grid[self.y * self.cols + self.x] = (chr(data[i]), self.fg, self.bold)
                self.x += 1
                i += 1
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
