"""Build pinned notcurses core and ncurses locally; install no global files."""
import hashlib
import io
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tarfile
import urllib.request
from quiet_support import ROOT, BUILD, run, capture

V = json.loads((ROOT / 'versions.json').read_text())
DEPS = BUILD / 'deps'
DEPS.mkdir(parents=True, exist_ok=True)

def source(name, url, checksum):
    archive = BUILD / (name + '.tar.gz')
    if not archive.exists():
        archive.write_bytes(urllib.request.urlopen(url).read())
    data = archive.read_bytes()
    if hashlib.sha256(data).hexdigest() != checksum:
        raise SystemExit(name + ' archive checksum mismatch')
    dest = DEPS / name
    if not dest.exists():
        with tarfile.open(fileobj=io.BytesIO(data)) as t:
            t.extractall(DEPS, filter='data')
    return dest

ncurses = source('ncurses-' + V['ncurses'], V['ncurses_url'], V['ncurses_sha256'])
notcurses = source('notcurses-' + V['notcurses'], V['notcurses_url'], V['notcurses_sha256'])
prefix = BUILD / 'ncurses-prefix'
obj = BUILD / 'ncurses-cmake'
obj.mkdir(exist_ok=True)
env = os.environ.copy()
# Neither inherited TERMINFO nor a library's default directories may decide
# where a dependency installs its files. Never install a terminal database.
env.update(TERMINFO=str(BUILD / 'terminfo'), TERMINFO_DIRS=str(BUILD / 'terminfo'))
marker = prefix / '.bench-built'
if not marker.exists():
    configure = [str(ncurses / 'configure'), '--prefix=' + str(prefix), '--enable-widec', '--with-termlib',
                 '--without-cxx', '--without-cxx-binding', '--without-ada', '--without-tests', '--without-progs',
                 '--without-shared', '--disable-db-install', '--disable-home-terminfo',
                 '--with-default-terminfo-dir=' + str(BUILD / 'terminfo'),
                 '--with-terminfo-dirs=' + str(BUILD / 'terminfo'),
                 '--with-pkg-config-libdir=' + str(prefix / 'lib/pkgconfig'), '--enable-pc-files']
    with (BUILD / 'ncurses-build.log').open('w') as log:
        subprocess.run(configure, cwd=obj, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run(['make', '-j1'], cwd=obj, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run(['make', 'install.libs', 'install.includes'], cwd=obj, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    marker.write_text(V['ncurses'] + '\n')
cmake = BUILD / 'notcurses-cmake'
host_prefix = capture(['brew', '--prefix']) if sys.platform == 'darwin' else '/usr'
env['PKG_CONFIG_PATH'] = str(prefix / 'lib/pkgconfig') + os.pathsep + env.get('PKG_CONFIG_PATH', '')
with (BUILD / 'notcurses-build.log').open('w') as log:
    run(['cmake', '-S', notcurses, '-B', cmake, '-DCMAKE_BUILD_TYPE=Release',
         '-DUSE_MULTIMEDIA=none', '-DUSE_DEFLATE=OFF', '-DUSE_CXX=OFF', '-DUSE_DOCTEST=OFF',
         '-DUSE_PANDOC=OFF', '-DBUILD_TESTING=OFF', '-DBUILD_EXECUTABLES=OFF',
         '-DBUILD_FFI_LIBRARY=OFF', '-DUSE_POC=OFF', '-DUSE_STATIC=ON',
         '-DCMAKE_PREFIX_PATH=' + host_prefix], env=env, stdout=log, stderr=subprocess.STDOUT)
    run(['cmake', '--build', cmake, '--target', 'notcurses-core-static', '-j1'], env=env, stdout=log, stderr=subprocess.STDOUT)
(BUILD / 'terminfo').mkdir(exist_ok=True)
run(['tic', '-x', '-o', BUILD / 'terminfo', ROOT / 'src/notcurses.terminfo'], env=env)
cc = shlex.split(os.environ.get('CC', 'cc'))
link = ['-ldl'] if sys.platform.startswith('linux') else []
run(cc + ['-O3', '-std=gnu17', '-UNDEBUG', '-I' + str(notcurses / 'include'), '-I' + str(cmake / 'include'),
          '-I' + host_prefix + '/include', ROOT / 'src/notcurses.c', cmake / 'libnotcurses-core.a',
          '-L' + str(prefix / 'lib'), '-L' + host_prefix + '/lib', '-ltinfow', '-lunistring', '-lz',
          '-lpthread', '-lm'] + link + ['-o', BUILD / 'notcurses-bench'])
