#!/usr/bin/env python3
"""Validate and publish BOTW touch implementation independently of acceptance."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re

REPO = Path(__file__).resolve().parents[2]
INVENTORY = REPO / 'dm/games/01007EF00011E000/touch_ui_inventory.json'
OUT = REPO / 'docs/botw-touch-implementation.md'
IMPLEMENTATION = ('implemented', 'partial', 'missing', 'not_required')
VERIFICATION = ('passed', 'failed', 'not_run', 'blocked', 'not_required')
VERIFICATION_LEVEL = ('game_state', 'handler_test', 'none', 'not_required')
DISPOSITIONS = ('reusable_component', 'interactive_screen', 'prompt_screen', 'visual_only', 'passive_layer')


def validate(data, repo=REPO, catalogue=None, require_complete=False):
    """Reject missing classification, dangling evidence and false completion."""
    errors = []
    def check(condition, message):
        if not condition: errors.append(message)
    check(data.get('schema') == 1, 'unsupported inventory schema')
    scope = data.get('scope', {})
    check(scope.get('other_games_or_controller_input_affected') is False, 'scope must exclude other games and controller input')
    evidence = data.get('evidence', {})
    if evidence.get('current_screen_policy'):
        policy = repo / evidence['current_screen_policy']
        check(policy.is_file() and hashlib.sha256(policy.read_bytes()).hexdigest() == evidence.get('current_screen_policy_sha256'),
              'inventory routing-policy evidence is stale')
    requirements, layouts = data.get('requirements', []), data.get('layouts', [])
    ids = [row.get('id') for row in requirements]
    layout_ids = [row.get('layout_id') for row in layouts]
    check(bool(requirements) and len(ids) == len(set(ids)), 'empty or duplicate requirement IDs')
    check(bool(layouts) and len(layout_ids) == len(set(layout_ids)), 'empty or duplicate layout IDs')
    known_ids, known_layouts = set(ids), set(layout_ids)
    for row in requirements:
        rid = row.get('id')
        status, verified = row.get('implementation_status'), row.get('verification_status')
        level = row.get('verification_level')
        check(status in IMPLEMENTATION, f'{rid}: invalid implementation status')
        check(verified in VERIFICATION, f'{rid}: invalid verification status')
        check(level in VERIFICATION_LEVEL, f'{rid}: missing verification evidence level')
        if verified in ('passed', 'failed'):
            check(level in ('game_state', 'handler_test'), f'{rid}: result needs its actual evidence level')
        for field in ('screen', 'state', 'action', 'implementation_status_reason', 'verification_reason'):
            check(bool(row.get(field)), f'{rid}: missing {field}')
        if status in ('missing', 'partial'):
            check(bool(row.get('implementation_gap')), f'{rid}: unfinished work needs a concrete gap')
            check(not require_complete, f'{rid}: {status}: {row.get("implementation_gap", "unspecified gap")}')
        else:
            check(not row.get('implementation_gap'), f'{rid}: complete status still has an implementation gap')
        if status == 'implemented':
            check(bool(row.get('implementation_evidence')), f'{rid}: implemented without source evidence')
        if status == 'not_required':
            check(verified == 'not_required', f'{rid}: passive requirement has an acceptance status')
        else:
            check(verified != 'not_required', f'{rid}: required action cannot opt out of verification')
        for evidence in row.get('implementation_evidence', []) + row.get('verification_evidence', []):
            file, function = evidence.get('file', ''), evidence.get('function', '')
            path = (repo / file).resolve()
            check(path.is_relative_to(repo.resolve()) and path.is_file(), f'{rid}: missing/outside source file {file}')
            check(bool(evidence.get('why')), f'{rid}: source evidence needs a reason')
            if path.is_relative_to(repo.resolve()) and path.is_file() and function:
                symbol = re.escape(function)
                check(re.search(r'\b' + symbol + r'\s*\(|\bHLE(?:_FORCE)?\([^{}]*,\s*' + symbol +
                                r'\s*,|[-+]\s*\([^)]*\)\s*' + symbol + r'(?:\s*\{|:)', path.read_text()) is not None,
                      f'{rid}: source function not found: {file}:{function}')
    for layout in layouts:
        lid = layout.get('layout_id')
        disposition = layout.get('disposition')
        check(disposition in DISPOSITIONS, f'{lid}: unclassified layout')
        check(bool(layout.get('classification_reason')), f'{lid}: classification needs a reason')
        check(bool(re.fullmatch(r'[0-9a-f]{64}', layout.get('sha256', ''))), f'{lid}: missing resource hash')
        linked = layout.get('requirement_ids', [])
        check(set(linked) <= known_ids, f'{lid}: unknown requirement reference')
        if disposition in ('interactive_screen', 'prompt_screen'):
            check(bool(linked), f'{lid}: input screen needs action requirements')
        if set(layout.get('evidence', {}).get('control_types', [])) & {'NormalButton', 'UniteButton'}:
            check(bool(linked), f'{lid}: declared input control has no action requirement')
        if disposition == 'reusable_component':
            check(bool(layout.get('reuse_disposition')) and bool(layout.get('reuse_reason')), f'{lid}: component needs reuse disposition')
        for ref in layout.get('component_refs', []):
            if ref.get('resolved'):
                check(ref.get('component_layout_id') in known_layouts, f'{lid}: dangling component reference')
            else:
                check(ref.get('resolution') == 'missing_target_layout' and bool(ref.get('resolution_reason')),
                      f'{lid}: unexplained unresolved component')
    for kind in ('control_types', 'interaction_surfaces'):
        for control in data.get(kind, []):
            check(bool(control.get('meaning')), f'{kind}: classification needs a meaning')
            check(set(control.get('requirement_ids', [])) <= known_ids, f'{kind}: unknown requirement reference')
    expected = data.get('totals', {})
    check(expected.get('layouts') == len(layouts) and expected.get('requirements') == len(requirements), 'inventory totals are stale')
    if catalogue is not None:
        scanned = {row['name']: row for row in catalogue['layouts']}
        check(set(scanned) == known_layouts, 'catalogue and inventory layout sets differ')
        for layout in layouts:
            item = scanned.get(layout['layout_id'])
            if not item: continue
            check(item['sha256'] == layout['sha256'] and item['source'].split('::')[-1] == layout['source'], f'{layout["layout_id"]}: catalogue identity differs')
            actual = Counter((ref['pane_path'], ref['component_name']) for ref in layout.get('component_refs', []))
            scanned_refs = Counter((pane['path'], pane['part']) for pane in item['panes'] if 'part' in pane)
            check(actual == scanned_refs, f'{layout["layout_id"]}: catalogue part references differ')
    return errors


def cell(value):
    return str(value).replace('|', '\\|').replace('\n', ' ')


def page(data):
    implemented = Counter(row['implementation_status'] for row in data['requirements'])
    tested = Counter(row['verification_status'] for row in data['requirements'] if row['implementation_status'] != 'not_required')
    levels = Counter(row['verification_level'] for row in data['requirements'] if row['verification_status'] == 'passed')
    lines = ['# BOTW touch implementation checklist', '',
             'Generated from [the editable inventory](../dm/games/01007EF00011E000/touch_ui_inventory.json) by '
             '`python3 dm/tools/botw_touch_progress.py`. Change the inventory and regenerate this page.', '',
             'This is the implementation record for BOTW touch menus. It covers the supplied base/update '
             'and both DLC resource sets. Controller input, other games and existing combat controls stay outside this task. '
             'A registered screen or recognized name alone does not count as an implemented action.', '',
             f'{len(data["layouts"])} layouts classified: {data["totals"]["top_level_layouts"]} top-level layouts '
             f'and {data["totals"]["reusable_components"]} reusable components. '
             'Rows below group actions that share an implementation; layout counts are not action counts.', '',
             '| Implementation | Count |', '| --- | ---: |']
    lines += [f'| {status.replace("_", " ")} | {implemented[status]} |' for status in IMPLEMENTATION]
    lines += ['', '| Verification of required action groups | Count |', '| --- | ---: |']
    lines += [f'| {status.replace("_", " ")} | {tested[status]} |' for status in VERIFICATION if status != 'not_required']
    lines += ['', f'Passed results include {levels["game_state"]} game-state checks and '
              f'{levels["handler_test"]} handler tests. A handler test checks synthetic native owners '
              'or frontend gesture delivery; it does not prove that story/vendor/DLC state was reached in the game.']
    lines += ['', 'Implementation and verification are independent. `blocked` means a save, story/DLC state '
              'or hardware is unavailable; it never excuses a missing implementation. `passed` uses the evidence '
              'named in that row and does not imply every conditional variant or physical iPhone was tested. '
              'Runtime observations and per-target replay assertions are tracked separately in '
              '[UI coverage](botw-ui-coverage.md) and [acceptance progress](botw-menu-touch-progress.md).', '',
              '## Required actions', '', '| ID / screen and state | Action | Implementation | Verification / evidence level |', '| --- | --- | --- | --- |']
    for row in data['requirements']:
        lines.append('| ' + ' | '.join(map(cell, (f'`{row["id"]}` — {row["screen"]}; {row["state"]}', row['action'], row['implementation_status'],
            row['verification_status'] + ' / ' + row['verification_level'].replace('_', ' ')))) + ' |')
    lines += ['', '## Action evidence and remaining work', '']
    for row in data['requirements']:
        lines += [f'### {row["id"]}', '', row['implementation_status_reason'], '']
        if row.get('implementation_gap'): lines += ['**Implementation remaining:** ' + row['implementation_gap'], '']
        for evidence in row['implementation_evidence']:
            lines.append(f'- [{evidence["file"]}](../{evidence["file"]}) `{evidence.get("function", "")}`: {evidence["why"]}')
        if row['implementation_evidence']: lines.append('')
        lines += [f'**Verification ({row["verification_status"]}; {row["verification_level"].replace("_", " ")}):** {row["verification_reason"]}', '']
        for evidence in row.get('verification_evidence', []):
            lines.append(f'- [{evidence["file"]}](../{evidence["file"]}) `{evidence.get("function", "")}`: {evidence["why"]}')
        if row.get('verification_evidence'): lines.append('')
        for artifact in row.get('verification_artifacts', []):
            lines.append(f'- Recorded artifact: `{artifact["file"]}` — {artifact["why"]}')
        if row.get('verification_artifacts'): lines.append('')
    lines += ['## Complete resource disposition', '',
              'Every scanned layout is listed, including passive HUDs, backgrounds and shared parts. '
              'The JSON retains exact resource hashes, owner/component links, control declarations and classification reasons. '
              'New/changed resources must be classified before completion can pass.', '',
              '| Layout | Role | Action requirements |', '| --- | --- | --- |']
    for layout in sorted(data['layouts'], key=lambda row: row['layout_id'].casefold()):
        lines.append(f'| `{layout["layout_id"]}` | {layout["disposition"].replace("_", " ")} | {", ".join(layout["requirement_ids"]) or "No independent menu action"} |')
    lines += ['', '## Updating and checking', '', '```sh', 'python3 dm/tools/botw_touch_progress.py',
              'python3 dm/tools/botw_touch_progress.py --check --require-complete',
              'python3 dm/tools/botw_touch_progress.py --check --catalogue /path/to/catalogue.json', '```', '',
              'The check rejects unclassified layouts, missing action links, dangling source/component evidence '
              'and stale generated documentation. `--require-complete` also rejects every partial or missing '
              'required action, independently of verification availability. An explicit catalogue checks that '
              'every resource and exact part reference is accounted for. This validates the record; source review '
              'and interaction tests establish whether its claims are correct.', '']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, default=INVENTORY)
    parser.add_argument('--out', type=Path, default=OUT)
    parser.add_argument('--catalogue', type=Path)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--require-complete', action='store_true')
    args = parser.parse_args()
    data = json.loads(args.inventory.read_text())
    catalogue = json.loads(args.catalogue.read_text()) if args.catalogue else None
    errors = validate(data, catalogue=catalogue, require_complete=args.require_complete)
    result = page(data)
    if args.check and (not args.out.is_file() or args.out.read_text() != result): errors.append('generated implementation page is stale')
    if errors:
        for error in errors: print('[RED] ' + error)
        return 1
    if not args.check: args.out.write_text(result)
    counts = Counter(row['implementation_status'] for row in data['requirements'])
    print(f'{len(data["layouts"])} classified layouts; implementation: {dict(counts)}; inventory sha256 {hashlib.sha256(args.inventory.read_bytes()).hexdigest()}')
    return 0


if __name__ == '__main__': raise SystemExit(main())
