#!/usr/bin/env python3
"""Inventory BOTW UI resources, report touch gaps, and replay semantic assertions.

No game assets are written to the repository. Resource presence, routing policy,
runtime observations and successful touch assertions are separate evidence.
"""
import argparse
from collections import Counter
import functools
import hashlib
import io
import json
import math
from pathlib import Path
import re
import struct
import sys
import time

import romfs

REPO = Path(__file__).resolve().parents[2]
POLICY = REPO / 'dm/host/botw_touch_screens.inc'
BUILD = 'cd57b23fa4bbad65803d9788c01821ee'
MAX_ARCHIVE = 512 * 1024 * 1024
PANE_TAGS = {'pan1', 'pic1', 'txt1', 'wnd1', 'bnd1', 'prt1'}


def digest(data): return hashlib.sha256(data).hexdigest()


def adapter_digest():
    names = ('hle_botw_touch_menu.c', 'botw_touch_menu.h', 'botw_ui_audit.inc', 'botw_touch_screens.inc')
    return digest(b'\0'.join(name.encode() + b'\0' + (REPO / 'dm/host' / name).read_bytes() for name in names))


@functools.cache
def policy():
    text = POLICY.read_text()
    rows = re.findall(r'^BOTW_UI_SCREEN\((EXACT|PREFIX), "([^"]+)", ([A-Z]+)\)$', text, re.M)
    if not rows or len(rows) != sum(line.startswith('BOTW_UI_SCREEN') for line in text.splitlines()):
        raise ValueError('unreadable shared native screen policy')
    return rows


@functools.cache
def policy_fingerprint():
    value = 14695981039346656037
    for byte in ''.join(':'.join(row) + '\n' for row in policy()).encode(): value = ((value ^ byte) * 1099511628211) & ((1 << 64) - 1)
    return f'{value:016x}'


def role(name):
    for match, pattern, value in policy():
        if name == pattern or match == 'PREFIX' and name.startswith(pattern): return value
    return 'UNKNOWN'


def string(data, off, size=None):
    if not 0 <= off < len(data): raise ValueError('string offset outside section')
    end = data.find(b'\0', off, min(len(data), off + size) if size else len(data))
    if end < 0 and size is not None:
        if off + size > len(data): raise ValueError('fixed string outside section')
        end = off + size
    if end < 0: raise ValueError('unterminated layout string')
    return data[off:end].decode('utf-8', 'strict')


def yaz0(data, prefix=None):
    """Bounded Yaz0 reader; same token format as shader_split.py's reader."""
    if len(data) < 16: raise ValueError('short Yaz0 header')
    size = int.from_bytes(data[4:8], 'big')
    wanted = min(size, prefix) if prefix is not None else size
    if wanted > MAX_ARCHIVE: raise ValueError(f'Yaz0 expansion exceeds {MAX_ARCHIVE} bytes')
    out = bytearray(); pos = 16
    while len(out) < wanted:
        if pos >= len(data): raise ValueError('truncated Yaz0 group')
        flags = data[pos]; pos += 1
        for bit in range(7, -1, -1):
            if len(out) >= wanted: break
            if pos >= len(data): raise ValueError('truncated Yaz0 token')
            if flags & (1 << bit): out.append(data[pos]); pos += 1
            else:
                if pos + 2 > len(data): raise ValueError('truncated Yaz0 reference')
                a, b = data[pos:pos + 2]; pos += 2
                distance, count = ((a & 15) << 8 | b) + 1, a >> 4
                if count: count += 2
                else:
                    if pos >= len(data): raise ValueError('truncated Yaz0 length')
                    count = data[pos] + 0x12; pos += 1
                if distance > len(out) or len(out) + count > size: raise ValueError('invalid Yaz0 reference')
                count = min(count, wanted - len(out)); start = len(out) - distance
                out += (out[start:] * (count // distance + 1))[:count]
    return bytes(out)


def sections(data, magic):
    if len(data) < 20 or data[:4] != magic or data[4:6] not in (b'\xff\xfe', b'\xfe\xff'):
        raise ValueError('invalid layout header')
    endian = '<' if data[4:6] == b'\xff\xfe' else '>'
    header, version, size, count = struct.unpack_from(endian + 'HIIH', data, 6)
    if size != len(data) or not 20 <= header <= size: raise ValueError('invalid layout size')
    offset = header
    for _ in range(count):
        if offset + 8 > size: raise ValueError('truncated layout section')
        tag = data[offset:offset + 4].decode('ascii')
        length = struct.unpack_from(endian + 'I', data, offset + 4)[0]
        if length < 8 or offset + length > size: raise ValueError('layout section outside file')
        yield tag, data[offset:offset + length], endian, version
        offset += length
    if offset != size: raise ValueError('unaccounted layout bytes')


def layout(data):
    """Pane tree and part/control metadata, not static pixel hit testing.

    Pane/part formats follow SwitchThemeInjector's Pan1Pane/Prt1Pane readers.
    cnt1 names/counts are kept as declarations, never inferred action bindings.
    """
    panes, controls, parents, previous = [], [], [], None
    for tag, block, endian, version in sections(data, b'FLYT'):
        if tag in PANE_TAGS:
            if len(block) < 84: raise ValueError('short pane')
            name = string(block, 12, 24)
            path = '/'.join([*parents, name])
            pane = {'name': name, 'path': path, 'type': tag}
            if tag == 'prt1':
                if version < 0x08000000: raise ValueError(f'unsupported part version {version:#x}')
                count = struct.unpack_from(endian + 'I', block, 84)[0]
                # The instance pane name is fixed-width; the referenced layout
                # filename is a terminated string and can exceed 24 bytes.
                pane['part'] = string(block, 96 + count * 40)
            if name in ('B_Hit_00', 'B_Btn_00', 'B_Area_00'): pane['candidate'] = 'native-hit'
            elif name.startswith(('P_Text_', 'P_Sh_')) and any(p.startswith('N_TextOut_') for p in parents):
                pane['candidate'] = 'dialogue-body'
            elif any(word in name for word in ('Guide', 'KeyIcon')): pane['candidate'] = 'key-hint'
            panes.append(pane); previous = name
        elif tag == 'pas1':
            if previous is None: raise ValueError('pane push without pane')
            parents.append(previous); previous = None
        elif tag == 'pae1':
            if not parents: raise ValueError('unbalanced pane pop')
            parents.pop(); previous = None
        elif tag == 'cnt1':
            if len(block) < 29: raise ValueError('short control declaration')
            name_off, pane_off, pane_count, animations = struct.unpack_from(endian + 'IIHH', block, 8)
            if pane_off + pane_count * 24 > len(block): raise ValueError('control panes outside section')
            controls.append({'type': string(block, 28), 'name': string(block, name_off),
                             'panes': [string(block, pane_off + n * 24, 24) for n in range(pane_count)],
                             'animation_count': animations})
    if parents: raise ValueError('unbalanced pane tree')
    return {'panes': panes, 'controls': controls}


def scan(roots):
    layouts, animations, errors, counters = [], [], [], Counter()

    def visit(stream, start, size, source, depth=0):
        if depth > 12: raise ValueError('archive nesting exceeds 12')
        stream.seek(start); header = stream.read(min(size, 4096)); magic = header[:4]
        if magic == b'Yaz0':
            inner = yaz0(header, 4)
            if inner not in (b'SARC', b'FLYT', b'FLAN'): return
            if size > MAX_ARCHIVE: raise ValueError('compressed archive exceeds read limit')
            stream.seek(start); data = yaz0(stream.read(size))
            counters['yaz0_archives'] += 1
            visit(io.BytesIO(data), 0, len(data), source, depth + 1)
        elif magic == b'SARC':
            counters['sarc_archives'] += 1
            if size < 32: raise ValueError('short SARC')
            endian = '<' if header[6:8] == b'\xff\xfe' else '>' if header[6:8] == b'\xfe\xff' else None
            if endian is None: raise ValueError('invalid SARC byte order')
            head, _, total, data_off = struct.unpack_from(endian + 'HHII', header, 4)
            if total != size or head < 20 or not head + 12 <= data_off <= size:
                raise ValueError('invalid SARC range')
            stream.seek(start + head); sfat = stream.read(12)
            if sfat[:4] != b'SFAT': raise ValueError('missing SFAT')
            count = struct.unpack_from(endian + 'H', sfat, 6)[0]
            nodes = stream.read(count * 16); sfnt = stream.read(8)
            names_start = head + 12 + count * 16 + 8
            if len(nodes) != count * 16 or sfnt[:4] != b'SFNT' or names_start > data_off:
                raise ValueError('invalid SARC index')
            names = stream.read(data_off - names_start)
            for index in range(count):
                _, attr, lo, hi = struct.unpack_from(endian + 'IIII', nodes, index * 16)
                if not 0 <= lo <= hi <= size - data_off: raise ValueError('SARC member outside archive')
                name = string(names, (attr & 0xffffff) * 4) if attr >> 24 else f'#{index}'
                try: visit(stream, start + data_off + lo, hi - lo, source + '!' + name, depth + 1)
                except (ValueError, UnicodeError, struct.error) as error: errors.append({'source': source + '!' + name, 'error': str(error)})
        elif magic in (b'FLYT', b'FLAN'):
            if size > MAX_ARCHIVE: raise ValueError('layout exceeds read limit')
            stream.seek(start); data = stream.read(size)
            item = {'source': source, 'name': Path(source.split('!')[-1]).stem, 'sha256': digest(data)}
            if magic == b'FLYT': item.update(layout(data)); layouts.append(item)
            else:
                item['sections'] = Counter(tag for tag, *_ in sections(data, b'FLAN')); animations.append(item)
        elif source.lower().endswith(('.bflyt', '.bflan', '.sblarc', '.ssarc', '.sarc', '.pack')):
            raise ValueError(f'unrecognized UI/archive header {magic.hex()}')

    for root_arg in roots:
        root = romfs.Path(root_arg).absolute()
        if not root.is_dir(): raise ValueError(f'not a RomFS folder/image: {root}')
        for path in sorted(root.rglob('*')):
            if not path.is_file(): continue
            counters['files'] += 1
            if counters['files'] % 2000 == 0: print(f'scanned {counters["files"]} files; {len(layouts)} layouts, {len(animations)} animations', file=sys.stderr, flush=True)
            source = str(root) + '::' + path.relative_to(root).as_posix()
            try:
                with path.open('rb') as stream: visit(stream, 0, path.stat().st_size, source)
            except (OSError, ValueError, UnicodeError, struct.error) as error: errors.append({'source': source, 'error': str(error)})
    return {'schema': 1, 'policy_sha256': digest(POLICY.read_bytes()), 'roots': [str(p) for p in roots],
            'counts': dict(counters), 'layouts': layouts, 'animations': animations, 'errors': errors}


def read_new_events(stream):
    events = []
    while True:
        offset = stream.tell(); line = stream.readline()
        if not line.endswith('\n'):
            stream.seek(offset); break  # retain an in-progress record
        event = json.loads(line)
        if event.get('event') == 'session' and (event.get('schema') != 1 or event.get('build') != BUILD or event.get('policy') != policy_fingerprint()):
            raise ValueError('unsupported audit build/schema/policy')
        events.append(event)
    return events


def read_events(path):
    with Path(path).open() as stream: events = read_new_events(stream)
    if events and events[0].get('event') != 'session': raise ValueError(f'missing audit session in {path}')
    return events


def target_matches(target, query):
    for key, value in query.items():
        if key == 'path_suffix':
            if not target.get('path', '').endswith(value): return False
        elif key == 'path_contains':
            if value not in target.get('path', ''): return False
        elif target.get(key) != value: return False
    return True


def state_matches(state, query):
    if not state: return False
    for key, value in query.items():
        if key == 'focus_suffix':
            if not state.get('focus', '').endswith(value): return False
        elif key == 'target':
            if not any(target_matches(t, value) for t in state.get('targets', [])): return False
        elif state.get(key) != value: return False
    return True


def case_key(state, target):
    return (state['screen'], state.get('group'), state.get('mode'), state.get('hero_path', 0), target['id'])


def input_owner_active(state, registry):
    if not state.get('owner_input') or state.get('owner_mode') != 2: return False
    if role(state['screen']) == 'SLATE':
        # Slate children remain allocated/shown after AppHome starts closing.
        parent = registry.get('AppHome_00', {})
        return bool(parent.get('registered') and parent.get('input') and parent.get('mode') == 2 and parent.get('shown', -1) >= 0)
    return role(state['screen']) in ('MENU', 'UNKNOWN')


def coverage(catalogue, audits=(), results=()):
    events = [e for p in audits for e in read_events(p)]
    states = [e for e in events if e['event'] == 'state' and e.get('active')]
    registered = {e['screen'] for e in events if e['event'] == 'screen'}
    observed = {e['screen'] for e in states}
    passed, exercised, passed_targets, result_errors = set(), set(), set(), []
    for path in results:
        result = json.loads(Path(path).read_text()); proof = result.get('audit', {})
        try:
            with Path(proof['path']).open('rb') as stream: fingerprint = digest(stream.read(proof['bytes']))
            if fingerprint != proof['sha256'] or result.get('policy_sha256') != digest(POLICY.read_bytes()) or result.get('adapter_sha256') != adapter_digest():
                raise ValueError('audit/policy/adapter fingerprint differs; replay the changed code')
            if result.get('build') != BUILD: raise ValueError('build differs')
        except (OSError, KeyError, ValueError) as error:
            result_errors.append({'source': str(path), 'error': str(error)}); continue
        for step in result.get('steps', []):
            if not step.get('touch'): continue
            exercised.add(step['before']['screen'])
            if step.get('status') == 'PASS':
                if not step.get('expect') or not state_matches(step.get('after'), step['expect']) or state_matches(step['before'], step['expect']):
                    result_errors.append({'source': str(path), 'error': f'invalid outcome assertion: {step.get("name")}'}); continue
                passed.add(step['before']['screen'])
                if step.get('target'):
                    passed_targets.add(case_key(step['before'], step['target']))
    referenced = {p['part'] for item in catalogue['layouts'] for p in item['panes'] if 'part' in p}
    rows = []
    for item in catalogue['layouts']:
        name = item['name']; routing = role(name)
        rows.append({'name': name, 'source': item['source'], 'routing': routing,
                     'component': name in referenced or bool(re.match(r'^(?:Pa[A-Z_]|Cursor|Common)', name)),
                     'candidates': sum('candidate' in p for p in item['panes']),
                     'controls': len(item['controls']), 'registered': name in registered,
                     'observed': name in observed, 'exercised': name in exercised, 'asserted': name in passed})
    resource_names = {r['name'] for r in rows}
    gaps = []
    for name in sorted(registered | observed):
        if role(name) == 'UNKNOWN': gaps.append({'kind': 'unknown-screen', 'screen': name, 'observed': name in observed})
        if name not in resource_names: gaps.append({'kind': 'screen-without-layout-match', 'screen': name})
    # A shown input owner without a mapping is still observable when active=0.
    # Require a full heartbeat interval to exclude ordinary opening animations.
    missing, empty, registry = {}, set(), {}
    for event in events:
        if event['event'] == 'session': missing.clear(); registry.clear()
        if event['event'] == 'screen': registry[event['screen']] = event
        if event['event'] != 'state': continue
        key = (event['screen'], event.get('group'))
        if input_owner_active(event, registry) and not event.get('targets'):
            start = missing.get(key, event['frame']); missing = {key: start}
            if event['frame'] - start >= 30: empty.add(key)
        else: missing.clear()
    for name, group in sorted(empty): gaps.append({'kind': 'active-without-targets', 'screen': name, 'group': group})
    for name in sorted(observed - passed): gaps.append({'kind': 'observed-without-touch-assertion', 'screen': name})
    for item in rows:
        if not item['component'] and item['routing'] == 'UNKNOWN':
            gaps.append({'kind': 'unclassified-resource', 'screen': item['name'], 'source': item['source']})
    cases = {}
    for state in states:
        for target in state['targets']:
            key = case_key(state, target)
            cases[key] = {'name': f'{state["screen"]}/{target["id"]}',
                          'when': {'screen': state['screen'], 'active': 1, 'mode': state['mode'], 'hero_path': state.get('hero_path', 0)},
                          'tap': {k: target[k] for k in ('kind', 'path', 'adjustment', 'button')},
                          'expect': None, 'status': 'touch-asserted' if key in passed_targets else 'needs-outcome-assertion'}
    return {'schema': 1, 'policy_sha256': digest(POLICY.read_bytes()), 'counts': {
        'scanned_files': catalogue.get('counts', {}).get('files', 0),
        'scanned_archives': catalogue.get('counts', {}).get('sarc_archives', 0),
        'layouts': len(rows), 'animations': len(catalogue['animations']), 'registered_screens': len(registered),
        'observed_screens': len(observed), 'touch_exercised_screens': len(exercised), 'touch_asserted_screens': len(passed),
        'generated_cases': len(cases), 'touch_asserted_targets': len(passed_targets)}, 'layouts': rows, 'gaps': gaps,
        'errors': catalogue['errors'] + result_errors, 'cases': list(cases.values())}


def write_report(catalogue, out, audits=(), results=()):
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    report = coverage(catalogue, audits, results)
    (out / 'coverage.json').write_text(json.dumps(report, indent=2) + '\n')
    (out / 'cases.json').write_text(json.dumps({'schema': 1, 'steps': report['cases']}, indent=2) + '\n')
    lines = ['# BOTW touch coverage', '',
             'Resource presence and routing classification are not runtime acceptance. An asserted screen has at least one successful explicit touch outcome; this is not every state or control.', '',
             '| Evidence | Count |', '| --- | ---: |']
    lines += [f'| {key.replace("_", " ")} | {value} |' for key, value in report['counts'].items()]
    lines += ['', '## Gaps', '', '| Kind | Screen | Details |', '| --- | --- | --- |']
    for gap in report['gaps']:
        details = 'runtime observed' if gap.get('observed') else gap.get('source', '')
        lines.append(f'| {gap["kind"]} | {gap["screen"]} | {details} |')
    lines += ['', '## Scan and evidence errors', '']
    lines += [f'- {e["source"]}: {e["error"]}' for e in report['errors']] or ['None.']
    lines += ['', '## Layout inventory', '', '| Layout | Routing | Component | Candidates | Registered | Observed | Touch attempted | Touch asserted |', '| --- | --- | --- | ---: | --- | --- | --- | --- |']
    for row in report['layouts']:
        lines.append('| ' + ' | '.join(str(row[k]) for k in ('name', 'routing', 'component', 'candidates', 'registered', 'observed', 'exercised', 'asserted')) + ' |')
    (out / 'coverage.md').write_text('\n'.join(lines) + '\n')
    return report


def latest_state(events):
    state = None
    for event in events:
        if event['event'] == 'session': state = None
        elif event['event'] == 'state': state = event
    return state


def send(ctl, command):
    if '\n' in command or '\r' in command: raise ValueError('newline in control command')
    with Path(ctl).open('a') as stream: stream.write(command + '\n')


def replay(route, audit, ctl, out, timeout=15):
    """Only explicit routes: generated candidates never blindly confirm a menu."""
    if not math.isfinite(timeout) or timeout <= 0: raise ValueError('timeout must be positive')
    steps = route['steps']
    for step in steps:
        if not step.get('expect') or not step.get('when'): raise ValueError(f'route step needs when and expect: {step.get("name")}')
        if sum(k in step for k in ('tap', 'swipe', 'key')) != 1: raise ValueError('one action required per step')
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    result = {'schema': 1, 'build': BUILD, 'policy_sha256': digest(POLICY.read_bytes()), 'adapter_sha256': adapter_digest(), 'steps': []}
    offset, current_state = 0, None
    identity = None

    def wait_for(query, after=None, target=None):
        nonlocal offset, current_state, identity
        deadline = time.monotonic() + timeout
        state = None
        while time.monotonic() < deadline:
            try: stat = Path(audit).stat()
            except FileNotFoundError:
                time.sleep(.1); continue
            if identity is None: identity = stat.st_ino
            if stat.st_ino != identity or stat.st_size < offset: raise ValueError('audit restarted; restart the replay')
            with Path(audit).open() as stream:
                stream.seek(offset); events = read_new_events(stream); offset = stream.tell()
            for event in events:
                if event['event'] == 'session': current_state = None
                elif event['event'] == 'state': current_state = event
            state = current_state
            if state is not None and state_matches(state, query) and (after is None or state['seq'] > after):
                matches = [t for t in state.get('targets', []) if target_matches(t, target)] if target is not None else [None]
                if len(matches) > 1: raise ValueError(f'target must be unique ({len(matches)} matches): {target}')
                if matches: return state
            time.sleep(.1)
        raise TimeoutError(f'expected {query}, last state {state}')

    try:
        for index, step in enumerate(steps):
            record = {'name': step['name'], 'touch': False, 'status': 'FAIL', 'when': step['when'], 'expect': step['expect']}
            result['steps'].append(record)
            action = step.get('tap', step.get('swipe'))
            target = action.get('target', action) if isinstance(action, dict) else None
            before = wait_for(step['when'], target=target); record['before'] = before
            if state_matches(before, step['expect']): raise ValueError('outcome already true before input; no observed outcome')
            if 'key' in step:
                if not re.fullmatch(r'[A-Za-z0-9+]+(?:~[0-9.]+)?', step['key']): raise ValueError('invalid route key')
                send(ctl, step['key'])
            else:
                action = step.get('tap', step.get('swipe'))
                if not isinstance(action, dict): raise ValueError('touch action must be an object')
                matches = [t for t in before['targets'] if target_matches(t, action.get('target', action))]
                if len(matches) != 1: raise ValueError(f'target must be unique ({len(matches)} matches): {action}')
                rect = matches[0]['rect']; x, y = rect[0] + rect[2] / 2, rect[1] + rect[3] / 2
                if not all(math.isfinite(v) and 0 <= v <= 1 for v in (x, y)): raise ValueError('target center outside canvas')
                record['target'] = matches[0]
                if 'swipe' in step:
                    dx, dy = action.get('dx', 0), action.get('dy', 0)
                    if not all(isinstance(v, (int, float)) and math.isfinite(v) for v in (dx, dy)) or not (0 <= x + dx <= 1 and 0 <= y + dy <= 1):
                        raise ValueError('swipe endpoint outside canvas')
                send(ctl, f'menu begin {x:.5f} {y:.5f}'); record['touch'] = True; time.sleep(.12)
                if 'swipe' in step:
                    for n in range(1, 13):
                        send(ctl, f'menu move {x + dx*n/12:.5f} {y + dy*n/12:.5f}'); time.sleep(.025)
                    x += dx; y += dy
                send(ctl, f'menu end {x:.5f} {y:.5f}')
            after = wait_for(step['expect'], before['seq']); record['after'] = after
            # A repeated heartbeat is not evidence that a tap did anything.
            changed = any(after.get(k) != before.get(k) for k in ('screen', 'mode', 'group', 'active', 'focus', 'targets'))
            if not changed: raise ValueError('assertion already true before input; no observed outcome')
            record['status'] = 'PASS'
            shot = (out / f'{index:03d}.png').absolute(); send(ctl, f'shot {shot}')
            record['screenshot'] = str(shot)
            print(f'PASS: {step["name"]}', flush=True)
    except (OSError, ValueError, TimeoutError) as error:
        result['error'] = str(error)
        if result['steps']: result['steps'][-1]['error'] = str(error)
        print(f'[RED] touch replay: {error}', file=sys.stderr, flush=True)
        send(ctl, 'menu cancel 0 0'); send(ctl, f'shot {(out / "failure.png").absolute()}')
    data = Path(audit).read_bytes() if Path(audit).exists() else b''
    result['audit'] = {'path': str(Path(audit).absolute()), 'bytes': len(data), 'sha256': digest(data)}
    (out / 'replay.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def watch(audit, ctl, out, seconds):
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    seen = set(); deadline = time.monotonic() + seconds
    with Path(audit).open() as stream:
        history = read_new_events(stream)  # old transitions cannot be captured now
        registry = {e['screen']: e for e in history if e['event'] == 'screen'}
        missing = {}
        while time.monotonic() < deadline:
            for event in read_new_events(stream):
                name = event.get('screen', '')
                if event['event'] == 'session': registry.clear(); missing.clear()
                if event['event'] == 'screen': registry[name] = event
                unknown = event['event'] == 'screen' and event.get('registered') and event.get('input') and event.get('mode') == 2 and role(name) == 'UNKNOWN'
                no_targets = False
                if event['event'] == 'state':
                    if input_owner_active(event, registry) and not event.get('targets'):
                        start = missing.get(name, event['frame']); missing = {name: start}
                        no_targets = event['frame'] - start >= 30
                    else: missing.clear()
                key = (name, 'unknown-screen' if unknown else 'active-without-targets')
                if not (unknown or no_targets) or key in seen: continue
                seen.add(key); stem = re.sub(r'[^A-Za-z0-9_-]', '_', '-'.join(key))
                send(ctl, f'shot {(out / (stem + ".png")).absolute()}')
                if re.fullmatch(r'0x[0-9a-f]+', event.get('root', '')): send(ctl, f'panes {event["root"]} 12')
                (out / (stem + '.json')).write_text(json.dumps(event, indent=2) + '\n')
                print(f'GAP: {key[1]} {name}', flush=True)
            time.sleep(.25)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('scan'); p.add_argument('romfs', nargs='+', type=Path); p.add_argument('--out', required=True, type=Path)
    p = sub.add_parser('report'); p.add_argument('catalogue', type=Path); p.add_argument('--audit', action='append', default=[], type=Path)
    p.add_argument('--results', action='append', default=[], type=Path); p.add_argument('--out', required=True, type=Path)
    p.add_argument('--check', action='store_true', help='fail on unknown runtime screens, empty active views or invalid evidence')
    p = sub.add_parser('replay'); p.add_argument('route', type=Path); p.add_argument('--timeout', type=float, default=15)
    for verb in ('watch',):
        p = sub.add_parser(verb); p.add_argument('--seconds', type=float, default=60)
    for verb in ('replay', 'watch'):
        p = sub.choices[verb]; p.add_argument('--audit', required=True, type=Path)
        p.add_argument('--ctl', required=True, type=Path); p.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'scan':
            catalogue = scan(args.romfs); args.out.mkdir(parents=True, exist_ok=True)
            (args.out / 'catalogue.json').write_text(json.dumps(catalogue, indent=2) + '\n')
            report = write_report(catalogue, args.out)
            print(json.dumps(report['counts'])); return bool(report['errors'])
        if args.command == 'report':
            catalogue = json.loads(args.catalogue.read_text())
            # The resource catalogue is reusable when routing code changes.
            # Runtime sessions and replay proofs must match the current policy.
            report = write_report(catalogue, args.out, args.audit, args.results); print(json.dumps(report['counts']))
            return bool(report['errors'] or args.check and any(g['kind'] == 'active-without-targets' or g['kind'] == 'unknown-screen' and g.get('observed') for g in report['gaps']))
        if args.command == 'replay': return bool(replay(json.loads(args.route.read_text()), args.audit, args.ctl, args.out, args.timeout).get('error'))
        watch(args.audit, args.ctl, args.out, args.seconds); return 0
    except (OSError, ValueError, struct.error) as error:
        print(f'[RED] {error}', file=sys.stderr); return 1


if __name__ == '__main__': sys.exit(main())
