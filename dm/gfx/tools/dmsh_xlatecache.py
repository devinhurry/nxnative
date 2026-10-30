#!/usr/bin/env python3
"""Output-transparent cache for complete dmsh_xlate jobs (independent of DMSH_CHAIN)."""
import hashlib, json, os, pathlib, shutil, subprocess, tempfile, threading, time
import platform

import dmsh_mtlcache

FORMAT = b'dmsh_xlatecache 1'
OUTPUTS = ('.spv', '.res.json')
RUNTIME_ENV = ('PATH', 'DMSH_XLATE_CACHE', 'DOTNET_ROOT', 'DOTNET_ROOT_ARM64', 'DOTNET_ROOT_X64', 'DOTNET_ROLL_FORWARD',
               'DOTNET_ROLL_FORWARD_TO_PRERELEASE', 'DOTNET_MULTILEVEL_LOOKUP', 'DOTNET_SHARED_STORE',
               'DOTNET_ADDITIONAL_DEPS', 'DOTNET_STARTUP_HOOKS')


def _sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()


def _dotnet_path():
    arch_root = {'arm64': 'DOTNET_ROOT_ARM64', 'aarch64': 'DOTNET_ROOT_ARM64', 'x86_64': 'DOTNET_ROOT_X64'}.get(platform.machine().lower())
    host = os.environ.get(arch_root) if arch_root else None
    host = host or os.environ.get('DOTNET_ROOT')
    return os.path.join(host, 'dotnet') if host and os.path.isfile(os.path.join(host, 'dotnet')) else shutil.which('dotnet')


def _toolchain_paths(executable):
    exe = pathlib.Path(executable).resolve(); root = exe.parent
    paths = {root, exe}
    for p in root.rglob('*'):
        if p.is_dir() or p.is_file() and p.suffix.lower() in ('.dll', '.json'): paths.add(p.resolve())
    dotnet = _dotnet_path()
    if dotnet:
        dotnet = pathlib.Path(dotnet).resolve(); paths.add(dotnet)
        runtime_root = dotnet.parent
        for directory in (runtime_root / 'host' / 'fxr', runtime_root / 'shared' / 'Microsoft.NETCore.App'):
            if directory.is_dir():
                paths.add(directory)
                for p in directory.rglob('*'):
                    if p.is_dir() or p.is_file() and p.suffix.lower() in ('.dll', '.json', '.dylib', '.so'): paths.add(p.resolve())
    return tuple(sorted(paths))


def _toolchain_signature(paths):
    files = []
    for p in sorted(paths):
        try:
            s = p.stat(); files.append((str(p), s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_ino))
        except OSError: files.append((str(p), None))
    return files, tuple((k, os.environ.get(k)) for k in RUNTIME_ENV), platform.system(), platform.machine()


def _identity(executable):
    exe = pathlib.Path(executable).resolve()
    root = exe.parent
    files = []
    # The published translator's local managed assemblies, deps/runtime config, and apphost all affect output.
    for p in sorted(root.rglob('*')):
        if p.is_file() and (p == exe or p.suffix.lower() in ('.dll', '.json')):
            try: files.append((str(p.relative_to(root)), _sha(p)))
            except OSError: files.append((str(p.relative_to(root)), 'unreadable'))
    dotnet = _dotnet_path()
    runtimes = ''
    if dotnet:
        try:
            r = subprocess.run([dotnet, '--list-runtimes'], capture_output=True, text=True, timeout=20)
            runtimes = f'{os.path.realpath(dotnet)}\n{r.stdout}\n{r.stderr}\n{r.returncode}'
        except (OSError, subprocess.SubprocessError) as e: runtimes = f'{dotnet}: {e}'
    env = {k: os.environ.get(k) for k in RUNTIME_ENV}
    return hashlib.sha256(FORMAT + json.dumps([files, runtimes, env, platform.system(), platform.machine()], sort_keys=True, separators=(',', ':')).encode()).hexdigest()


class Cache:
    """Cache complete translator jobs; a translator/toolchain change during one instance requires a build restart."""
    def __init__(self, root, translator, *, enabled=True):
        self.root = pathlib.Path(root)
        self.translator = os.path.realpath(shutil.which(os.fspath(translator)) or os.fspath(translator))
        self.enabled = enabled and os.environ.get('DMSH_XLATE_CACHE', '1') != '0'
        self.identity = ''
        self._toolchain = None
        if self.enabled:
            self._toolchain_paths = _toolchain_paths(self.translator)
            before = _toolchain_signature(self._toolchain_paths)
            self.identity = _identity(self.translator)
            self._toolchain = _toolchain_signature(self._toolchain_paths)
            if before != self._toolchain: raise RuntimeError('translator, dependency, or .NET runtime changed during the build; restart the build')
        self._stats: dict[tuple[str, str], float] = {}
        self._lock = threading.Lock()

    def _check_toolchain(self):
        if self.enabled and _toolchain_signature(self._toolchain_paths) != self._toolchain:
            raise RuntimeError('translator, dependency, or .NET runtime changed during the build; restart the build')

    def _key(self, job, code):
        spec = dict(job, code={'sha256': hashlib.sha256(code).hexdigest()})
        raw = json.dumps([self.identity, spec], sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()
        return hashlib.sha256(raw).hexdigest()

    @staticmethod
    def _outputs(job):
        suffixes = OUTPUTS + (('.reader.spv',) if job.get('geometry_topology') is not None else ())
        return [str(job['key']) + suffix for suffix in suffixes]

    def _count(self, phase, name, n: float = 1):
        key = (phase or 'unspecified', name)
        with self._lock: self._stats[key] = self._stats.get(key, 0) + n

    def _entry(self, key): return self.root / key[:2] / key

    @staticmethod
    def _complete(directory, job, names, expected_hashes=None):
        try:
            for name in names:
                path = directory / name
                if not path.is_file(): return False
                if name.endswith('.spv'):
                    with open(path, 'rb') as f: header = f.read(20)
                    if len(header) != 20 or header[:4] != b'\x03\x02\x23\x07': return False
                if expected_hashes is not None and _sha(path) != expected_hashes[name]: return False
            res = json.loads((directory / (str(job['key']) + '.res.json')).read_text())
            return res.get('key') == job['key'] and res.get('stage') == job['stage']
        except (OSError, ValueError, TypeError, AttributeError, KeyError): return False

    def _valid(self, entry, job, names):
        try:
            manifest = json.loads((entry / 'manifest.json').read_text())
            if manifest.get('format') != FORMAT.decode() or manifest.get('files', {}).keys() != set(names): return False
            return self._complete(entry, job, names, manifest['files'])
        except (OSError, ValueError, TypeError, AttributeError, KeyError): return False

    def _restore(self, entry, outdir, job, names):
        try: manifest = json.loads((entry / 'manifest.json').read_text())
        except (OSError, ValueError, TypeError, AttributeError, KeyError): return False
        tmp = pathlib.Path(tempfile.mkdtemp(prefix='xlate-restore-', dir=outdir))
        try:
            for name in names: dmsh_mtlcache.clone(str(entry / name), str(tmp / name))
            if not self._complete(tmp, job, names, manifest.get('files', {})): return False
            for name in names: os.replace(tmp / name, pathlib.Path(outdir) / name)
            return True
        except OSError: return False
        finally: shutil.rmtree(tmp, ignore_errors=True)

    def _publish(self, entry, outdir, job, names):
        entry.parent.mkdir(parents=True, exist_ok=True)
        tmp = pathlib.Path(tempfile.mkdtemp(prefix=entry.name + '.tmp-', dir=entry.parent))
        try:
            source = pathlib.Path(outdir)
            if not self._complete(source, job, names): return
            files = {}
            for name in names:
                src = source / name
                shutil.copyfile(src, tmp / name)
                files[name] = _sha(tmp / name)
            if not self._complete(tmp, job, names, files): return
            (tmp / 'manifest.json').write_text(json.dumps({'format': FORMAT.decode(), 'files': files}, sort_keys=True))
            try: os.rename(tmp, entry)
            except OSError:
                if self._valid(entry, job, names): return
                if not entry.exists(): raise
                shutil.rmtree(entry, ignore_errors=True)
                try: os.rename(tmp, entry)
                except OSError:
                    if not self._valid(entry, job, names): raise
        finally:
            if tmp.exists(): shutil.rmtree(tmp, ignore_errors=True)

    def translate(self, jobs, outdir, *, phase=''):
        start = time.perf_counter()
        try: return self._translate(jobs, outdir, phase)
        finally: self._count(phase, 'total_seconds', time.perf_counter() - start)

    def _translate(self, jobs, outdir, phase):
        self._check_toolchain()
        jobs = list(jobs)
        if not jobs: return subprocess.CompletedProcess([self.translator], 0, '', '')
        outdir = os.fspath(outdir)
        os.makedirs(outdir, exist_ok=True)
        snapshots = [(json.loads(json.dumps(job)), pathlib.Path(job['code']).read_bytes()) for job in jobs]
        if not self.enabled:
            for job, _ in snapshots:
                for name in self._outputs(job):
                    try: os.unlink(os.path.join(outdir, name))
                    except FileNotFoundError: pass
            t = time.perf_counter(); result = self._run(snapshots, outdir); self._count(phase, 'translator_seconds', time.perf_counter() - t)
            self._count(phase, 'translated_jobs', len(snapshots)); self._count(phase, 'subprocess_calls')
            return result
        lookup = time.perf_counter(); pending, hits = [], []
        for job, code in snapshots:
            key, names = self._key(job, code), self._outputs(job)
            entry = self._entry(key)
            if self._valid(entry, job, names): hits.append((job, code, entry, names))
            else: pending.append((job, code, entry, names))
        self._count(phase, 'lookup_seconds', time.perf_counter() - lookup)
        self._count(phase, 'hits', len(hits)); self._count(phase, 'misses', len(pending))
        restore = time.perf_counter()
        for hit in hits:
            job, code, entry, names = hit
            if not self._restore(entry, outdir, job, names): pending.append((job, code, entry, names))
        self._count(phase, 'restore_seconds', time.perf_counter() - restore)
        if len(pending) != len(snapshots) - len(hits):
            self._count(phase, 'hits', -(len(pending) - (len(snapshots) - len(hits))))
            self._count(phase, 'misses', len(pending) - (len(snapshots) - len(hits)))
        if not pending:
            self._check_toolchain()
            return subprocess.CompletedProcess([self.translator], 0, '', '')
        for job, _, _, names in pending:
            for name in names:
                try: os.unlink(os.path.join(outdir, name))
                except FileNotFoundError: pass
        translated = time.perf_counter()
        result = self._run([(job, code) for job, code, _, _ in pending], outdir)
        self._count(phase, 'translator_seconds', time.perf_counter() - translated)
        self._count(phase, 'subprocess_calls'); self._count(phase, 'translated_jobs', len(pending))
        self._check_toolchain()
        # A failed batch may have produced arbitrary partial files; none of it is trusted.
        if result.returncode == 0:
            write = time.perf_counter()
            for job, _, entry, names in pending: self._publish(entry, outdir, job, names)
            self._count(phase, 'write_seconds', time.perf_counter() - write)
        return result

    def _run(self, snapshots, outdir):
        os.makedirs(outdir, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='dmsh_xlatecache-', dir=outdir) as work:
            jobs = []
            for i, (job, code) in enumerate(snapshots):
                path = os.path.join(work, f'code-{i}.bin')
                pathlib.Path(path).write_bytes(code)
                jobs.append(dict(job, code=path))
            jp = os.path.join(work, 'jobs.json'); pathlib.Path(jp).write_text(json.dumps(jobs))
            return subprocess.run([self.translator, jp, outdir], capture_output=True, text=True)

    def metrics(self):
        with self._lock:
            values = dict(self._stats)
        phases = sorted({phase for phase, _ in values})
        return {'enabled': self.enabled, **{name: sum(v for (p, n), v in values.items() if n == name)
                for name in ('hits', 'misses', 'translated_jobs', 'subprocess_calls')},
                'seconds': {name: sum(v for (p, n), v in values.items() if n == name)
                            for name in ('lookup_seconds', 'restore_seconds', 'write_seconds', 'translator_seconds', 'total_seconds')},
                'phases': {p: {n: values.get((p, n), 0) for n in ('hits', 'misses', 'translated_jobs', 'subprocess_calls', 'lookup_seconds', 'restore_seconds', 'write_seconds', 'translator_seconds', 'total_seconds')}
                           for p in phases}}

    def summary(self):
        m = self.metrics()
        s = m['seconds']
        return (f"translator cache: {m['hits']} hit, {m['misses']} miss, {m['translated_jobs']} translated jobs, "
                f"{m['subprocess_calls']} subprocesses; lookup {s['lookup_seconds']:.2f}s, restore {s['restore_seconds']:.2f}s, "
                f"write {s['write_seconds']:.2f}s, translator {s['translator_seconds']:.2f}s, cumulative {s['total_seconds']:.2f}s")
