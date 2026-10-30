#!/usr/bin/env python3
# Compiled-shader cache keyed by the Metal source (dmsh_build.py): a library is compiled once per (MSL text, compile convention, compiler), so a chain change
# that leaves a shader's MSL as it was (a translator fix, a new rule for other shaders) costs that shader no Metal compile. The Metal compiler is deterministic:
# the same MSL with the same flags gives a byte-identical metallib (checked for macOS and iOS), which is what makes reuse safe.
# Layout: <cache>/<target>/<2 hex>/<digest>.metallib, digest = sha256 over FORMAT, the target's compile convention (the record written into json chain_metal),
# the compiler's identity (metal / metallib --version without the install path, the SDK version and build) and the MSL bytes. Metal embeds the input basename
# in its output, so _compile gives every source a fixed basename in a private temporary directory before invoking the tool.
# Filling from earlier builds: every imported library must record the current compiler identity and flags in its reflection. Legacy libraries without that identity are not imported.
# A fresh compile of two shaders per stage also checks their bytes. Each folder is read once per compiler identity (filled.json remembers its number of libraries).
# This file is part of the chain version (dmsh_chain.py): Metal output depends on its canonical input basename, so changing this compile convention can change library bytes.
# Bump FORMAT when the cache identity or stored artifact policy changes.
import os, re, json, shutil, ctypes, hashlib, threading, subprocess, collections, tempfile

FORMAT = b'dmsh_mtlcache 4'   # canonical compile input basename; earlier cache entries used caller basenames
CHOICE_FORMAT = b'dmsh_mtlcache candidate choice 1'
OUTPUT = re.compile(r'[0-9a-f]{16}_b\.metal')   # a shader's MSL in dmsh_build.py's outputs: <key>_b.metal
_clonefile = getattr(ctypes.CDLL(None, use_errno=True), 'clonefile', None)   # APFS copy-on-write copy (no data written); elsewhere a plain copy


def clone(src, dst):
    tmp = f'{dst}.tmp-{os.getpid()}-{threading.get_ident()}'
    if _clonefile is None or _clonefile(os.fsencode(src), os.fsencode(tmp), 0) != 0: shutil.copyfile(src, tmp)
    os.replace(tmp, dst)


def compiler_id(sdk):
    def run(*a): return subprocess.run(['xcrun', '-sdk', sdk, *a], capture_output=True, text=True).stdout
    tools = ''.join(run(t, '--version') for t in ('metal', 'metallib'))
    return re.sub(r'(?m)^InstalledDir:.*\n?', '', tools) + run('--show-sdk-version') + run('--show-sdk-build-version')   # the install path changes with each toolchain mount


class Cache:
    def __init__(self, root, targets, work):
        """targets: {name: (sdk, record, compile)}, compile(msl, air, lib) as ios_metal.compile; work: a folder for temporary .air files"""
        self.root, self.targets, self.work = root, targets, work
        self.ident = {t: hashlib.sha256(FORMAT + b'\0' + rec.encode() + b'\0' + compiler_id(sdk).encode()).digest() for t, (sdk, rec, _) in targets.items()}
        self.stats, self.lock = collections.Counter(), threading.Lock()
        self.choice_locks, self.choice_locks_guard = {}, threading.Lock()
        self.compile_locks, self.compile_locks_guard = {}, threading.Lock()

    def path(self, target, src):
        d = hashlib.sha256(self.ident[target] + b'\0' + src).hexdigest()
        return os.path.join(self.root, target, d[:2], d + '.metallib')

    def with_compiler(self, target, refl):
        return dict(refl, chain_metal=self.targets[target][1], chain_compiler=self.ident[target].hex())

    def count(self, what, n=1):
        with self.lock: self.stats[what] += n

    def _compile(self, target, msl, lib):
        directory = tempfile.mkdtemp(prefix=f'mtlcache-{target}-', dir=self.work)
        canonical = os.path.join(directory, 'shader.metal')
        air = os.path.join(directory, 'shader.air')
        try:
            shutil.copyfile(msl, canonical)
            self.targets[target][2](canonical, air, lib)
        finally: shutil.rmtree(directory, ignore_errors=True)

    def compile(self, target, msl, lib):
        """msl → lib for target: a clone of the library that the same source compiled to before, or a compile (then kept). Raises CalledProcessError as the compile does"""
        with open(msl, 'rb') as f: source = f.read()
        p = self.path(target, source)
        with self.compile_locks_guard: lock = self.compile_locks.setdefault((target, p), threading.Lock())
        with lock:
            if os.path.exists(p):
                clone(p, lib); self.count((target, 'reused')); return
            tmp = f'{lib}.tmp-{os.getpid()}-{threading.get_ident()}'
            self._compile(target, msl, tmp)
            os.replace(tmp, lib)
            os.makedirs(os.path.dirname(p), exist_ok=True); clone(lib, p); self.count((target, 'compiled'))

    def _choice_path(self, target, digest):
        return os.path.join(self.root, 'candidate-selections', target, digest[:2], digest + '.json')

    @staticmethod
    def _choice_digest(target_id, contents):
        h = hashlib.sha256(CHOICE_FORMAT + b'\0' + target_id + b'\0ordered-candidates-v1\0')
        for source in contents: h.update(len(source).to_bytes(8, 'little') + source)
        return h.hexdigest()

    def _load_choice(self, target, digest, count):
        try:
            record = json.load(open(self._choice_path(target, digest)))
            payload = {'format': CHOICE_FORMAT.decode(), 'digest': digest, 'selected': record['selected']}
            checksum = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            index = record['selected']
            return index if record.get('format') == payload['format'] and record.get('digest') == digest and record.get('sha256') == checksum and type(index) is int and 0 <= index < count else None
        except (OSError, ValueError, TypeError, KeyError): return None

    def _store_choice(self, target, digest, selected):
        payload = {'format': CHOICE_FORMAT.decode(), 'digest': digest, 'selected': selected}
        record = dict(payload, sha256=hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()).hexdigest())
        path = self._choice_path(target, digest); os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f'{path}.tmp-{os.getpid()}-{threading.get_ident()}'
        try:
            with open(tmp, 'w') as f: json.dump(record, f, sort_keys=True, separators=(',', ':'))
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp): os.unlink(tmp)

    def compile_candidates(self, target, candidates, lib):
        """Compile the first successful ordered MSL candidate for this target; return its index.

        The successful index is keyed by this target's compiler and every candidate's
        bytes and order. A hit still calls compile() so the requested output is restored
        from the target-specific compiled-library cache. No all-failed result is stored.
        """
        candidates = tuple(os.fspath(p) for p in candidates)
        if not candidates: raise ValueError('compile_candidates requires at least one MSL source')
        contents = tuple(open(p, 'rb').read() for p in candidates)
        digest = self._choice_digest(self.ident[target], contents)
        path = self._choice_path(target, digest)
        with self.choice_locks_guard: lock = self.choice_locks.setdefault((target, digest), threading.Lock())
        with lock:
            selected = self._load_choice(target, digest, len(candidates))
            if selected is not None:
                try:
                    self.compile(target, candidates[selected], lib)
                    self.count((target, 'candidate reused')); return selected
                except subprocess.CalledProcessError:
                    try: os.unlink(path)
                    except FileNotFoundError: pass
            last = None
            for index, source in enumerate(candidates):
                try:
                    self.compile(target, source, lib)
                    self._store_choice(target, digest, index)
                    self.count((target, 'candidate selected')); return index
                except subprocess.CalledProcessError as e: last = e
            self.count((target, 'candidate failed'))
            if last is not None: raise last
            raise RuntimeError('no Metal candidate compiled')

    def _check(self, target, d, stems, source_dir):
        """None if folder d was built with the current convention and compiler, else why not"""
        rec, picks = self.targets[target][1], collections.defaultdict(list)
        for stem in stems:
            try: j = json.load(open(os.path.join(d, stem + '.json')))
            except (OSError, ValueError): return f'no readable {stem}.json'
            if j.get('chain_metal') != rec: return f'built with "{j.get("chain_metal")}"'
            if j.get('chain_compiler') != self.ident[target].hex(): return f'{stem} has a different or unrecorded Metal compiler'
            if len(picks[j.get('stage')]) < 2: picks[j.get('stage')].append(stem)
        for stem in (s for v in picks.values() for s in v):
            tmp = os.path.join(self.work, f'mtlcache-check-{target}.metallib')
            src = os.path.join(source_dir, stem + '.metal')
            if not os.path.isfile(src): return f'no verifiable {target} MSL source for {stem}'
            try: self._compile(target, src, tmp)
            except subprocess.CalledProcessError: return f'{stem}.metal does not compile now'
            same = open(tmp, 'rb').read() == open(os.path.join(d, stem + '.metallib'), 'rb').read(); os.unlink(tmp)
            if not same: return f'a fresh compile of {stem}.metal differs from its library'
        return None

    def fill(self, mac_dir, ios_dir=None, targets=None):
        """Takes the libraries of an earlier build: mac_dir = its Mac b-<chain>/ folder, ios_dir = the iOS folder of the same chain (or None). Returns the lines to print"""
        stamp_file = os.path.join(self.root, 'filled.json')
        try: stamps = json.load(open(stamp_file))
        except (OSError, ValueError): stamps = {}
        names = set(os.listdir(mac_dir)); stems = sorted(n[:-6] for n in names if OUTPUT.fullmatch(n))   # not an AppleDouble ._<name> (exFAT / FAT drives)
        todo, notes = {}, []
        for target, d in (('mac', mac_dir), ('ios', ios_dir)):
            if targets is not None and target not in targets: continue   # checking an earlier build compiles samples too
            if target not in self.targets or not d or not os.path.isdir(d): continue
            libs = names if d == mac_dir else set(os.listdir(d))
            have = [s for s in stems if s + '.metallib' in libs]; key = self.ident[target].hex() + ':' + os.path.realpath(d)
            if not have or stamps.get(key) == len(have): continue
            source_dir = mac_dir if target == 'mac' else d
            why = self._check(target, d, have, source_dir)
            if why: notes.append(f'Metal cache: not filled from {d}: {why}')
            else: todo[target] = (d, set(have))
            stamps[key] = len(have)
        added = collections.Counter()
        for stem in stems:
            ts = [t for t, (d, have) in todo.items() if stem in have]
            if not ts: continue
            for t in ts:
                source_dir = mac_dir if t == 'mac' else todo[t][0]
                src = open(os.path.join(source_dir, stem + '.metal'), 'rb').read()
                p = self.path(t, src)
                if os.path.exists(p): continue
                os.makedirs(os.path.dirname(p), exist_ok=True); clone(os.path.join(todo[t][0], stem + '.metallib'), p); added[t] += 1
        for t, (d, have) in todo.items():
            self.count((t, 'filled'), added[t]); notes.append(f'Metal cache: {added[t]} {t} libraries added from {d} ({len(have)} there)')
        os.makedirs(self.root, exist_ok=True)
        tmp = f'{stamp_file}.tmp-{os.getpid()}'; json.dump(stamps, open(tmp, 'w'), indent=1); os.replace(tmp, stamp_file)
        return notes

    def summary(self):
        s = self.stats
        return 'Metal cache: ' + '; '.join(f'{t} {s[t, "reused"]} reused, {s[t, "compiled"]} compiled' + (f', {s[t, "filled"]} filled from earlier builds' if s[t, 'filled'] else '')
                                          for t in self.targets)
