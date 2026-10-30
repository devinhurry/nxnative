"""Content-addressed cache for SPIRV-Cross and pure shader source analysis.

This cache is output-transparent: only successful JSON/source results are stored;
it does not cache compiled Metal libraries or alter translator/compiler behavior.
"""
import ast
import builtins
import copy
import hashlib
import json
import os
import subprocess
import symtable
import tempfile
import threading
import time

FORMAT = 'dmsh-codegen-cache-1'


def _json_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _strip_docstrings(node):
    """AST form that ignores comments, formatting and docstrings."""
    node = copy.deepcopy(node)
    for parent in ast.walk(node):
        body = getattr(parent, 'body', None)
        if isinstance(body, list) and body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant):
            value = getattr(body[0].value, 'value', None)
            if isinstance(value, str):
                body.pop(0)
    return ast.dump(node, include_attributes=False)


def _module_text(module):
    if isinstance(module, (str, os.PathLike)):
        module = os.fspath(module)
        if os.path.isfile(module):
            with open(module, encoding='utf-8') as f:
                return f.read()
        return module
    path = getattr(module, '__file__', None)
    if path:
        with open(path, encoding='utf-8') as f:
            return f.read()
    raise ValueError(f'cannot fingerprint module source: {module!r}')


def code_fingerprint(path, roots, runtime=(), modules=None):
    """Hash the semantic AST dependency closure of named definitions in a file.

    `roots` names functions/classes/constants in path. Same-file references are
    followed transitively. `runtime` names are deliberately treated as supplied
    inputs. Module sources in `modules` are included in full because their
    dependency boundaries are not inferred across Python module APIs.
    """
    with open(path, encoding='utf-8') as f:
        source = f.read()
    tree = ast.parse(source, filename=os.fspath(path))
    definitions = {}
    imported = set()
    for node in tree.body:
        if isinstance(node, ast.Import):
            imported.update(a.asname or a.name.split('.')[0] for a in node.names)
        elif isinstance(node, ast.ImportFrom):
            imported.update(a.asname or a.name for a in node.names)
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            definitions[node.name] = node
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for target in targets:
                if isinstance(target, ast.Name):
                    definitions[target.id] = node
                else:
                    for child in ast.walk(target):
                        if isinstance(child, ast.Name):
                            definitions[child.id] = node
    runtime = set(runtime)
    pending, selected = list(roots), set()
    unknown = set()

    def global_references(node):
        snippet = ast.unparse(node)
        scopes = symtable.symtable(snippet, os.fspath(path), 'exec')
        refs = set()
        comp_targets, loads_outside_comps = set(), set()
        class Comps(ast.NodeVisitor):
            def visit_ListComp(self, child): self._comp(child)
            def visit_SetComp(self, child): self._comp(child)
            def visit_DictComp(self, child): self._comp(child)
            def visit_GeneratorExp(self, child): self._comp(child)
            def _comp(self, child):
                if child.generators:
                    self.visit(child.generators[0].iter)
                for gen in child.generators:
                    comp_targets.update(n.id for n in ast.walk(gen.target) if isinstance(n, ast.Name))
            def visit_Name(self, child):
                if isinstance(child.ctx, ast.Load): loads_outside_comps.add(child.id)
        Comps().visit(node)
        def visit(table, module_scope=False):
            for symbol in table.get_symbols():
                if symbol.is_referenced() and (module_scope or symbol.is_global()):
                    refs.add(symbol.get_name())
                if not module_scope and symbol.is_declared_global() and symbol.is_assigned():
                    unknown.add(symbol.get_name())
            for child in table.get_children():
                visit(child)
        visit(scopes, module_scope=True)
        # Python 3.12 inlines comprehensions in module scope. Its symbol table
        # can then report the comprehension target as a referenced module
        # local; the AST identifies and removes those scoped names.
        refs.difference_update(comp_targets - loads_outside_comps)
        return refs

    references = set()
    while pending:
        name = pending.pop()
        if name in selected or name in runtime:
            continue
        node = definitions.get(name)
        if node is None:
            # Builtins/imports are stable external dependencies; unknown local
            # names cannot be safely fingerprinted.
            if name not in vars(builtins) and name not in imported and name not in definitions:
                unknown.add(name)
            continue
        selected.add(name)
        refs = global_references(node)
        references.update(refs)
        for ref in refs:
            if ref in definitions and ref not in runtime:
                pending.append(ref)
    for name in selected:
        node = definitions[name]
        refs = global_references(node)
        for ref in refs:
            if ref not in definitions and ref not in imported and ref not in runtime and ref not in vars(builtins):
                unknown.add(ref)
            references.add(ref)
    if unknown:
        raise ValueError('uncovered dynamic/local dependencies: ' + ', '.join(sorted(unknown)))
    pieces = [(name, _strip_docstrings(definitions[name])) for name in sorted(selected)]
    for name, module in sorted((modules or {}).items()):
        if name not in references and name.split('.')[-1] not in references:
            continue
        module_tree = ast.parse(_module_text(module))
        pieces.append(('module:' + name, _strip_docstrings(module_tree)))
    return _sha(_json_bytes({'python': list(__import__('sys').version_info[:2]), 'definitions': pieces}))


def _callable_fingerprint(fn):
    code = getattr(fn, '__code__', None)
    if code is None:
        return None
    if getattr(fn, '__closure__', None) or getattr(fn, '__name__', '') == '<lambda>':
        return None
    path = code.co_filename
    name = getattr(fn, '__name__', None)
    if not name:
        return None
    try:
        return code_fingerprint(path, [name])
    except (OSError, ValueError, SyntaxError):
        if '<locals>' in getattr(fn, '__qualname__', ''):
            return None
        with open(path, encoding='utf-8') as f:
            semantic = _strip_docstrings(ast.parse(f.read()))
        defaults = _json_bytes([getattr(fn, '__defaults__', None), getattr(fn, '__kwdefaults__', None)])
        qualname = getattr(fn, '__qualname__', None) or name
        return _sha((qualname + '\0' + semantic).encode() + defaults)


class Cache:
    def __init__(self, root, cross):
        self.root, self.cross = os.fspath(root), os.path.realpath(os.fspath(cross))
        self._watched = {}
        self.watch_sources([self.cross])
        before = self._signature(self.cross)
        with open(self.cross, 'rb') as f:
            binary = f.read()
        if before != self._signature(self.cross):
            raise RuntimeError(f'codegen source changed during build; restart required: {self.cross}')
        self.identity = _sha(FORMAT.encode() + b'\0spirv-cross\0' + binary)
        self.enabled = os.environ.get('DMSH_CODEGEN_CACHE', '1') != '0'
        self._stats = {k: {'calls': 0, 'hits': 0, 'seconds': 0.0} for k in ('converter', 'analysis', 'memo')}
        self._lock = threading.Lock()
        self._callable_fingerprints = {}

    @staticmethod
    def _signature(path):
        stat = os.stat(path)
        return (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)

    def watch_sources(self, paths):
        """Snapshot watched build inputs; edits during this process require a restart."""
        for path in paths:
            path = os.path.realpath(os.fspath(path))
            signature = self._signature(path)
            previous = self._watched.setdefault(path, signature)
            if previous != signature:
                raise RuntimeError(f'codegen source changed during build; restart required: {path}')

    def _check_sources(self):
        for path, previous in self._watched.items():
            try:
                current = self._signature(path)
            except OSError as exc:
                raise RuntimeError(f'codegen source changed during build; restart required: {path}') from exc
            if current != previous:
                raise RuntimeError(f'codegen source changed during build; restart required: {path}')

    def _count(self, kind, *, hit=False, elapsed=0.0):
        with self._lock:
            row = self._stats[kind]
            row['calls'] += 1
            row['hits'] += int(hit)
            row['seconds'] += elapsed

    def _artifact_path(self, digest):
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
            raise ValueError('cache digest must be a lowercase SHA-256 hex string')
        return os.path.join(self.root, 'artifacts', digest[:2], digest + '.json')

    def _load(self, digest):
        self._check_sources()
        hit, result = False, None
        if self.enabled:
            try:
                with open(self._artifact_path(digest), encoding='utf-8') as f:
                    record = json.load(f)
                payload = record['payload']
                hit = (record.get('format') == FORMAT and record.get('digest') == digest and
                       record.get('payload_sha256') == _sha(_json_bytes(payload)))
                if hit:
                    self._check_sources()
                    result = copy.deepcopy(payload)
            except (OSError, ValueError, TypeError, KeyError):
                pass
        return result

    def load(self, digest):
        start = time.monotonic()
        result = self._load(digest)
        self._count('analysis', hit=result is not None, elapsed=time.monotonic() - start)
        return result

    def store(self, digest, payload):
        self._check_sources()
        # Validate JSON before touching disk and snapshot caller-owned objects.
        payload = copy.deepcopy(payload)
        data = _json_bytes(payload)
        if not self.enabled:
            return
        record = {'format': FORMAT, 'digest': digest, 'payload_sha256': _sha(data), 'payload': payload}
        path = self._artifact_path(digest)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix='.tmp-', dir=os.path.dirname(path))
        try:
            with os.fdopen(fd, 'wb') as f:
                f.write(_json_bytes(record))
                f.flush()
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    def convert(self, spv_path, args, *, phase=''):
        start = time.monotonic()
        self._check_sources()
        with open(spv_path, 'rb') as f:
            spv = f.read()
        normalized = [str(a) for a in args]
        digest = _sha(_json_bytes([FORMAT, self.identity, normalized, _sha(spv)]))
        result = self._load(digest) if self.enabled else None
        if result is not None:
            self._count('converter', hit=True, elapsed=time.monotonic() - start)
            return subprocess.CompletedProcess([self.cross, *normalized, os.fspath(spv_path)], 0, result['stdout'], result['stderr'])
        fd, snapshot = tempfile.mkstemp(prefix='dmsh-spv-', dir=os.path.dirname(os.path.abspath(spv_path)))
        try:
            with os.fdopen(fd, 'wb') as f:
                f.write(spv)
            proc = subprocess.run([self.cross, *normalized, snapshot], capture_output=True, text=True)
        finally:
            if os.path.exists(snapshot):
                os.unlink(snapshot)
        self._check_sources()
        if proc.returncode == 0:
            self.store(digest, {'stdout': proc.stdout, 'stderr': proc.stderr})
        self._count('converter', hit=False, elapsed=time.monotonic() - start)
        return proc

    def memo(self, label, fn, *args, dependencies=None, **kwargs):
        start = time.monotonic()
        self._check_sources()
        code = getattr(fn, '__code__', None)
        path = os.path.realpath(code.co_filename) if code is not None else None
        defaults = _json_bytes([getattr(fn, '__defaults__', None), getattr(fn, '__kwdefaults__', None)]).hex()
        callable_key = (path, getattr(fn, '__qualname__', None), getattr(code, 'co_firstlineno', None), defaults)
        if path in self._watched and callable_key not in self._callable_fingerprints:
            self._callable_fingerprints[callable_key] = _callable_fingerprint(fn)
        fingerprint = self._callable_fingerprints.get(callable_key) if path in self._watched else _callable_fingerprint(fn)
        key = (_sha(_json_bytes([FORMAT, 'memo', label, fingerprint, args, kwargs, dependencies]))
               if fingerprint is not None else None)
        result = self._load(key) if self.enabled and key else None
        if result is not None:
            self._count('memo', hit=True, elapsed=time.monotonic() - start)
            return result['memo_value']
        result = fn(*args, **kwargs)
        self._check_sources()
        # A None result is valid, so memo entries wrap the value explicitly.
        normalized = json.loads(_json_bytes(result))
        if key is not None:
            self.store(key, {'memo_value': normalized})
        self._count('memo', hit=False, elapsed=time.monotonic() - start)
        return copy.deepcopy(normalized)

    def metrics(self):
        with self._lock:
            return copy.deepcopy(self._stats)

    def summary(self):
        stats = self.metrics()
        return '; '.join(f'{kind}: {v["hits"]}/{v["calls"]} hits, {v["seconds"]:.3f}s' for kind, v in stats.items())
