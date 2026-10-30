"""No game files: nested resources, honest evidence levels and semantic replay."""
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import botw_ui_audit as ui
import romfs_image


def section(tag, payload): return tag.encode() + struct.pack('<I', len(payload) + 8) + payload


def flyt():
    def pane(tag, name): return section(tag, b'\x01\0\xff\0' + name.encode().ljust(24, b'\0') + bytes(48))
    data = pane('pan1', 'RootPane') + section('pas1', b'') + pane('bnd1', 'B_Hit_00') + section('pae1', b'')
    return struct.pack('<4sHHIIHH', b'FLYT', 0xfeff, 20, 0x08000000, 20 + len(data), 4, 0) + data


def sarc(name, data):
    names = name.encode() + b'\0'; names += bytes(-len(names) % 4)
    off = 20 + 12 + 16 + 8 + len(names)
    return (struct.pack('<4sHHIII', b'SARC', 20, 0xfeff, off + len(data), off, 0x100) +
            struct.pack('<4sHHI', b'SFAT', 12, 1, 0x65) + struct.pack('<IIII', 0, 1 << 24, 0, len(data)) +
            struct.pack('<4sHH', b'SFNT', 8, 0) + names + data)


def compressed(data):
    # Literal-only Yaz0 fixture, independent of the decoder under test.
    return b'Yaz0' + len(data).to_bytes(4, 'big') + bytes(8) + b''.join(b'\xff' + data[n:n + 8] for n in range(0, len(data), 8))


def session(): return {'event': 'session', 'schema': 1, 'build': ui.BUILD, 'policy': ui.policy_fingerprint(), 'seq': 1}


class TouchAudit(unittest.TestCase):
    def test_scan_folder_and_image_nested_archives_and_reject_truncation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = root / 'RomFS'; src.mkdir()
            data = sarc('Layout/Common.sblarc', compressed(sarc('blyt/Title_00.bflyt', flyt())))
            (src / 'Bootup.pack').write_bytes(data)
            image = root / 'RomFS.img'; romfs_image.pack(src, image)
            folder, packed = ui.scan([src]), ui.scan([image])
            self.assertEqual(folder['errors'], []); self.assertEqual(packed['errors'], [])
            self.assertEqual(folder['layouts'][0]['sha256'], packed['layouts'][0]['sha256'])
            self.assertEqual(folder['layouts'][0]['panes'][1]['path'], 'RootPane/B_Hit_00')
            self.assertEqual(folder['layouts'][0]['panes'][1]['candidate'], 'native-hit')
            (src / 'Broken.sblarc').write_bytes(data[:-1])
            self.assertTrue(ui.scan([src])['errors'])
        for malformed in (b'Yaz0', b'Yaz0\0\0\0\x01' + bytes(8), b'Yaz0\0\0\0\x04' + bytes(8) + b'\0\0\0'):
            with self.assertRaises(ValueError): ui.yaz0(malformed)

    def test_policy_precedence_and_resource_presence_are_not_acceptance(self):
        self.assertEqual(ui.role('MessageTipsRunTime_00'), 'TIP')
        self.assertEqual(ui.role('PickUpWin_00'), 'TIP')
        self.assertEqual(ui.role('MessageTips_00'), 'MENU')
        self.assertEqual(ui.role('PauseMenuInfo_00'), 'PASSIVE')
        self.assertEqual(ui.role('AppMap_00'), 'SLATE')
        self.assertEqual(ui.role('NewUnknown_00'), 'UNKNOWN')
        catalogue = {'layouts': [{'name': 'Title_00', 'source': 'x', 'panes': [], 'controls': []}], 'animations': [], 'errors': []}
        report = ui.coverage(catalogue)
        self.assertFalse(report['layouts'][0]['observed']); self.assertFalse(report['layouts'][0]['asserted'])

    def test_unmapped_input_owner_is_a_gap_even_when_touch_is_inactive(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'audit.jsonl'
            states = [dict(event='state', seq=i + 2, frame=frame, screen='Title_00', group=0,
                           owner_input=1, owner_mode=2, active=0, targets=[]) for i, frame in enumerate((1, 31))]
            path.write_text(''.join(json.dumps(e) + '\n' for e in [session(), *states]))
            report = ui.coverage({'layouts': [], 'animations': [], 'errors': []}, [path])
            self.assertIn('active-without-targets', [g['kind'] for g in report['gaps']])
            self.assertEqual(report['counts']['touch_asserted_screens'], 0)
            closing = dict(event='screen', screen='AppHome_00', registered=1, input=1, shown=0, mode=3)
            map_states = [dict(s, screen='AppMap_00') for s in states]
            path.write_text(''.join(json.dumps(e) + '\n' for e in [session(), closing, *map_states]))
            report = ui.coverage({'layouts': [], 'animations': [], 'errors': []}, [path])
            self.assertNotIn('active-without-targets', [g['kind'] for g in report['gaps']])
            closing['mode'] = 2
            path.write_text(''.join(json.dumps(e) + '\n' for e in [session(), closing, *map_states]))
            self.assertIn('active-without-targets', [g['kind'] for g in ui.coverage({'layouts': [], 'animations': [], 'errors': []}, [path])['gaps']])
            with path.open('a') as stream: stream.write('{')
            self.assertEqual(len(ui.read_events(path)), 4)

    def test_replay_checks_outcome_and_binds_proof_to_the_audit(self):
        target = dict(id='target:RootPane/Row:0', kind='target', path='RootPane/Row', rect=[.1, .1, .2, .1], adjustment=0, button=0)
        before = dict(event='state', seq=2, frame=1, screen='Title_00', active=1, mode='generic', focus='RootPane/Old', targets=[target])
        after = dict(before, seq=3, frame=2, focus='RootPane/Row')
        step = dict(name='select row', when={'screen': 'Title_00'}, tap={'path': 'RootPane/Row'}, expect={'focus_suffix': '/Row'})
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); audit = root / 'audit'; audit.write_text(json.dumps(session()) + '\n' + json.dumps(after) + '\n')
            # An opening animation can expose the screen before its target.
            with patch.object(ui, 'read_new_events', side_effect=[[session(), dict(before, targets=[])], [before], [after]]), patch.object(ui, 'send') as send, patch.object(ui.time, 'sleep'):
                result = ui.replay({'steps': [step]}, audit, root / 'ctl', root)
            self.assertNotIn('error', result)
            self.assertIn('menu begin 0.20000 0.15000', [call.args[1] for call in send.call_args_list])
            catalogue = {'layouts': [], 'animations': [], 'errors': []}
            self.assertEqual(ui.coverage(catalogue, [audit], [root / 'replay.json'])['counts']['touch_asserted_screens'], 1)
            with audit.open('r+b') as stream: stream.write(b'!')
            self.assertTrue(ui.coverage(catalogue, (), [root / 'replay.json'])['errors'])
            with patch.object(ui, 'read_new_events', side_effect=[[session(), before], [session(), dict(before, seq=4)]]), patch.object(ui, 'send'), patch.object(ui.time, 'sleep'):
                result = ui.replay({'steps': [dict(step, expect={'screen': 'Title_00'})]}, audit, root / 'ctl', root)
            self.assertIn('no observed outcome', result['error'])
            with self.assertRaises(ValueError): ui.replay({'steps': [dict(step, expect=None)]}, audit, root / 'ctl', root)

    def test_live_gap_collector_ignores_history_and_captures_new_unknown_owner(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); audit = root / 'audit'
            old = dict(event='screen', screen='Old_00', registered=1, input=1, mode=2)
            new = dict(old, screen='New_00', root='0x1234')
            audit.write_text(json.dumps(session()) + '\n' + json.dumps(old) + '\n')
            ticks = iter((0, 0, 2))
            def tick():
                value = next(ticks)
                if audit.stat().st_size and value == 0:
                    # The first tick precedes the initial history read; the
                    # second appends the new event after that read.
                    tick.count += 1
                    if tick.count == 2:
                        with audit.open('a') as stream: stream.write(json.dumps(new) + '\n')
                return value
            tick.count = 0
            with patch.object(ui.time, 'monotonic', side_effect=tick), patch.object(ui.time, 'sleep'), patch.object(ui, 'send') as send:
                ui.watch(audit, root / 'ctl', root, 1)
            commands = [call.args[1] for call in send.call_args_list]
            self.assertEqual(len(commands), 2)
            self.assertIn('panes 0x1234 12', commands)
            self.assertTrue((root / 'New_00-unknown-screen.json').exists())
            self.assertFalse((root / 'Old_00-unknown-screen.json').exists())

    def test_layout_parser_bounds_and_part_references(self):
        self.assertEqual(ui.string(b'X' * 24, 0, 24), 'X' * 24)
        self.assertEqual(ui.string(b'Short\0', 0, 24), 'Short')
        block = bytearray(120); block[0:4] = b'\x01\0\xff\0'; block[4:28] = b'Pa_Button_00'.ljust(24, b'\0')
        block[88:112] = b'Button_00'.ljust(24, b'\0')
        data = section('prt1', block)
        full = struct.pack('<4sHHIIHH', b'FLYT', 0xfeff, 20, 0x08000000, 20 + len(data), 1, 0) + data
        self.assertEqual(ui.layout(full)['panes'][0]['part'], 'Button_00')
        long_name = b'PaAppDungeonBtnNextMoveFinalDLC_00\0'
        block = block[:88] + long_name
        data = section('prt1', block)
        full = struct.pack('<4sHHIIHH', b'FLYT', 0xfeff, 20, 0x08000000, 20 + len(data), 1, 0) + data
        self.assertEqual(ui.layout(full)['panes'][0]['part'], long_name[:-1].decode())
        for data in (flyt()[:-1], b'FLYT', flyt()[:24] + bytes(4) + flyt()[28:]):
            with self.assertRaises(ValueError): ui.layout(data)


if __name__ == '__main__': unittest.main()
