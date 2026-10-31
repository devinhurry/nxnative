"""The launcher's settings (dm/games/settings.tsv through dm/games/settings.py): rows by graphics API and profile, single-screen sections, toggle values and the strict format;
the meta column's optional fields, and the written list against docs/launcher.schema.json, the contract front ends read."""
import importlib.util
import json
import os
import re
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('launcher_settings', ROOT / 'dm/games/settings.py')
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)

BOTW, WONDER = '01007EF00011E000', '010015100B514000'
PERFORMANCE_NVN = ['DM_PRESENT_SNAP', 'DM_PSO_MTL4', 'DM_PSO_PREBUILD', 'DM_NVN_ENC_THREAD', 'DM_FPS_HOLD', 'DM_METAL_HUD']


def build(gid, api, platform=None):
    env = {'GFXAPI': api, **({'SETTINGS_PLATFORM': platform} if platform else {})}
    with tempfile.TemporaryDirectory() as tmp, patch.object(settings.nacp, 'languages', return_value=['en-US']), patch.dict(os.environ, env):
        if not platform: os.environ.pop('SETTINGS_PLATFORM', None)
        return {s['env']: s for s in settings.build(gid, tmp, Path(tmp) / 'control.nacp')['settings']}


class LauncherSettingsTests(unittest.TestCase):
    def test_upscaling_is_opt_in_for_every_graphics_api(self):
        for api, gid in [('nvn', BOTW), ('vulkan', '0100535012974000'), ('gl', '010014E00DB56000')]:
            with self.subTest(api=api):
                s = build(gid, api)['DM_PRESENT_UPSCALE']
                self.assertEqual((s['kind'], s['section'], s['default']), ('choice', 'Game', 'off'))
                self.assertEqual(s['options'], [['off', 'Standard'], ['metalfx', 'MetalFX']])

    def test_frame_buffering_by_graphics_api(self):
        for api, gid in [('nvn', BOTW), ('vulkan', '0100535012974000'), ('gl', '010014E00DB56000'), ('', BOTW)]:
            with self.subTest(api=api):
                rows = build(gid, api)
                self.assertEqual('DM_PRESENT_SNAP' in rows, api == 'nvn')
                if api == 'nvn':
                    s = rows['DM_PRESENT_SNAP']
                    self.assertEqual((s['kind'], s['section'], s['default']), ('toggle', 'Performance', '1'))   # Breath of the Wild's profile: present_snap on
                    self.assertIn('latency', s['note'])

    def test_sections_keep_the_profile_defaults(self):
        botw, wonder = build(BOTW, 'nvn'), build(WONDER, 'nvn')
        self.assertEqual([e for e, s in botw.items() if s['section'] == 'Performance'], ['DM_LOW_MEMORY'] + PERFORMANCE_NVN)
        self.assertEqual(botw['DM_PSO_MTL4']['default'], '1')   # pso_mtl4 on
        self.assertEqual((wonder['DM_PRESENT_SNAP']['default'], wonder['DM_PSO_MTL4']['default']), ('0', '0'))
        self.assertEqual((botw['DM_PSO_PREBUILD']['default'], botw['DM_NVN_ENC_THREAD']['default'], botw['DM_METAL_HUD']['default']), ('1', '1', '0'))   # the host's iOS defaults
        self.assertEqual(list(dict.fromkeys(s['section'] for s in botw.values())), ['Game', 'Controls', 'Touch left stick', 'Touch layout', 'Performance'])
        self.assertNotIn('DM_FPS_HOLD', wonder)   # no frame step, as the Frame rate row
        self.assertIn('first start', botw['DM_PSO_PREBUILD']['note'])   # it runs once in the prepare step, before the first frame

    def test_touch_stick_settings_are_botw_only(self):
        botw = build(BOTW, 'nvn')
        expected = {
            'DM_BOTW_MOVE_DEADZONE': ('0.070', 0, .3, .01), 'DM_BOTW_MOVE_CURVE': ('0.300', .3, 2, .05),
            'DM_BOTW_MOVE_FULL': ('0.710', .35, 1, .01), 'DM_BOTW_MOVE_SIZE': ('0.800', .6, 1.5, .05),
        }
        for key, bounds in expected.items():
            self.assertEqual(tuple(botw[key][k] for k in ('default', 'min', 'max', 'step')), bounds)
            self.assertEqual(botw[key]['section'], 'Touch left stick')
        self.assertEqual(botw['DM_BOTW_MOVE_CURVE']['format'], 'number')
        for gid, api in [(WONDER, 'nvn'), ('0100F2C0115B6000', 'nvn'), ('0100535012974000', 'vulkan'), ('010014E00DB56000', 'gl')]:
            with self.subTest(gid=gid):
                other = build(gid, api)
                self.assertTrue(set(expected).isdisjoint(other))
                self.assertNotIn('Touch left stick', [s['section'] for s in other.values()])

    def test_hold_frames_takes_on_and_off(self):   # the host reads DM_FPS_HOLD as on / off (hle_nvn.c), not 1 / 0
        s = build(BOTW, 'nvn')['DM_FPS_HOLD']
        self.assertEqual((s['on'], s['off'], s['default']), ('on', 'off', 'on'))
        s = build(BOTW, 'nvn')['DM_SHOW_FPS']
        self.assertEqual((s['on'], s['off']), ('1', '0'))

    def test_touch_layout_defaults_and_game_scope(self):
        expected = {
            'FACE_X': '-0.006', 'FACE_Y': '-0.068', 'FACE_SCALE': '1.100',
            'STICK_X': '0.000', 'STICK_Y': '0.023',
            'ZL_X': '0.000', 'ZL_Y': '0.000', 'ZL_SCALE': '1.000',
            'L_X': '0.021', 'L_Y': '0.000', 'L_SCALE': '1.200',
            'R_X': '0.025', 'R_Y': '-0.097', 'R_SCALE': '1.100',
            'ZR_X': '-0.022', 'ZR_Y': '-0.098', 'ZR_SCALE': '1.100',
            'DPAD_X': '0.042', 'DPAD_Y': '0.000', 'DPAD_SCALE': '1.000',
            'FACE_GAP': '1.060', 'BADGES': '0',
        }
        expected = {'DM_BOTW_PAD_' + key: value for key, value in expected.items()}
        for platform in ('mac', 'ios'):
            botw = build(BOTW, 'nvn', platform)
            self.assertEqual({key: row['default'] for key, row in botw.items() if key.startswith('DM_BOTW_PAD_')}, expected)
        self.assertTrue(set(expected).isdisjoint(build(WONDER, 'nvn')))

    def test_iphone_switches_only_on_the_iphone(self):   # the frame-rate counter and touch feedback are the iOS front end's (front_ios.m, DmGamepad.m)
        ios, mac = build(BOTW, 'nvn'), build(BOTW, 'nvn', 'mac')
        self.assertEqual(build(BOTW, 'nvn', 'ios').keys(), ios.keys())   # ios when unset
        self.assertEqual(set(ios) - set(mac), {'DM_SHOW_FPS', 'DM_TOUCH_HAPTICS'})
        self.assertIn('DM_RUMBLE', mac); self.assertIn('DM_METAL_HUD', mac)
        self.assertEqual(set(mac) - set(ios), {'DM_FULLSCREEN'})   # the Mac window's Display mode (front_mac.m reads 1 or 0)
        s = mac['DM_FULLSCREEN']
        self.assertEqual((s['kind'], s['default'], s['options'], s['level']), ('choice', '0', [['0', 'Window'], ['1', 'Fullscreen']], 'basic'))

    def test_low_memory_is_a_botw_opt_in(self):
        for platform in ('ios', 'mac'):
            botw = build(BOTW, 'nvn', platform)
            row = botw['DM_LOW_MEMORY']
            self.assertEqual((row['kind'], row['default'], row['section']), ('toggle', '0', 'Performance'))
            self.assertIn('Play', row['note'])
            self.assertEqual(botw['DM_PSO_PREBUILD']['needs'], 'DM_LOW_MEMORY=0')
            self.assertNotIn('DM_LOW_MEMORY', build(WONDER, 'nvn', platform))

    def test_defaults_follow_each_platform_host(self):
        # nvn_mtl.m pso4_on: Mac defaults on, iOS follows the profile. nvn_rec.h rec_on: iOS on, Mac off.
        for gid, ios_pso in ((BOTW, '1'), (WONDER, '0')):
            with self.subTest(game=gid):
                ios, mac = build(gid, 'nvn', 'ios'), build(gid, 'nvn', 'mac')
                self.assertEqual((ios['DM_PSO_MTL4']['default'], ios['DM_NVN_ENC_THREAD']['default']), (ios_pso, '1'))
                self.assertEqual((mac['DM_PSO_MTL4']['default'], mac['DM_NVN_ENC_THREAD']['default']), ('1', '0'))

    def test_unknown_platform_is_rejected(self):
        with self.assertRaisesRegex(SystemExit, 'SETTINGS_PLATFORM must be ios or mac'):
            build(WONDER, 'nvn', 'mca')

    def test_malformed_platform_defaults_are_rejected(self):
        for default in ('1|', '|0', '1|0|1'):
            with self.subTest(default=default), tempfile.TemporaryDirectory() as tmp:
                row = '\t'.join(('DM_X', 'toggle', '-', default, 'always', 'Game', 'X')) + '\n'
                (Path(tmp) / 'settings.tsv').write_text(row, encoding='utf-8')
                with patch.object(settings, 'HERE', Path(tmp)), patch.object(settings.nacp, 'languages', return_value=['en-US']), \
                        self.assertRaisesRegex(SystemExit, 'platform default'):
                    settings.build(BOTW, tmp, Path(tmp) / 'control.nacp')

    def test_meta_fields_and_the_schema_version(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(settings.nacp, 'languages', return_value=['en-US', 'ja']), patch.dict(os.environ, {'GFXAPI': 'nvn'}):
            (Path(tmp) / 'main.fixups.tsv').write_text('# RENDER_SCALE\t1\n')   # the render scale row's condition
            listed = settings.build(BOTW, tmp, Path(tmp) / 'control.nacp')
        rows = {s['env']: s for s in listed['settings']}
        self.assertEqual(listed['schema'], 1)
        self.assertEqual([e for e, s in rows.items() if s.get('level') == 'basic'], ['DM_FPS_TARGET', 'DM_RENDER_SCALE', 'DM_OPMODE', 'DM_LANG', 'DM_RUMBLE'])
        self.assertEqual(rows['DM_RUMBLE_GAIN']['needs'], 'DM_RUMBLE=1')
        self.assertFalse({'level', 'needs'} & set(rows['DM_METAL_HUD']), 'a row without meta has no optional fields')

    def test_meta_is_strict(self):
        self.assertEqual(settings.meta('level=basic; needs=DM_RUMBLE=1', 1), {'level': 'basic', 'needs': 'DM_RUMBLE=1'})
        self.assertEqual(settings.meta('', 1), {})
        for bad, why in [('colour=red', 'unknown meta key'), ('level', 'unknown meta key'), ('level=basic;level=basic', 'twice'),
                         ('level=advanced', 'does not match'), ('needs=DM_RUMBLE', 'does not match'), ('needs=rumble=1', 'does not match')]:
            with self.subTest(bad=bad), self.assertRaises(SystemExit) as e:
                settings.meta(bad, 1)
            self.assertIn(why, str(e.exception))

    def test_meta_keys_agree_with_the_docs_and_the_schema(self):
        """A key is added in settings.py's META, docs/frontends.md and docs/launcher.schema.json together"""
        schema = json.loads((ROOT / 'docs/launcher.schema.json').read_text(encoding='utf-8'))
        fields = schema['$defs']['setting']['properties']
        docs = (ROOT / 'docs/frontends.md').read_text(encoding='utf-8')
        for key in settings.META:
            with self.subTest(key=key):
                self.assertIn(key, fields)
                self.assertNotIn(key, schema['$defs']['setting']['required'], 'a meta field is optional')
                self.assertRegex(docs, rf'- `{key}` \(optional\)')
        self.assertEqual(schema['properties']['schema']['const'], settings.SCHEMA)

    def test_written_lists_follow_the_schema(self):
        schema = json.loads((ROOT / 'docs/launcher.schema.json').read_text(encoding='utf-8'))
        for gid, api, platform in [(BOTW, 'nvn', None), (BOTW, 'nvn', 'mac'), (WONDER, 'nvn', None), ('0100535012974000', 'vulkan', 'mac')]:
            with self.subTest(gid=gid, platform=platform), tempfile.TemporaryDirectory() as tmp, \
                    patch.object(settings.nacp, 'languages', return_value=['en-US']), patch.dict(os.environ, {'GFXAPI': api, **({'SETTINGS_PLATFORM': platform} if platform else {})}):
                self.assertEqual(conforms(settings.build(gid, tmp, Path(tmp) / 'control.nacp'), schema, schema), [])

    def test_schema_1_takes_new_sections_but_not_new_kinds(self):
        """A section is a heading a reader draws by its name, so a new one stays schema 1; a new kind would not"""
        schema = json.loads((ROOT / 'docs/launcher.schema.json').read_text(encoding='utf-8'))
        row = {'env': 'DM_X', 'kind': 'toggle', 'section': 'Picture', 'label': 'X', 'note': '', 'default': '1', 'on': '1', 'off': '0'}
        self.assertEqual(conforms({'schema': 1, 'game': BOTW, 'settings': [row]}, schema, schema), [])
        self.assertNotEqual(conforms({'schema': 1, 'game': BOTW, 'settings': [{**row, 'kind': 'slider'}]}, schema, schema), [])

    def test_render_base_goes_into_the_render_scale_row(self):
        schema = json.loads((ROOT / 'docs/launcher.schema.json').read_text(encoding='utf-8'))
        for gid, base in [(BOTW, {'docked': [1600, 900], 'handheld': [1280, 720]}), (WONDER, None)]:   # Breath of the Wild's note; Wonder's profile has none
            with self.subTest(gid=gid), tempfile.TemporaryDirectory() as tmp, \
                    patch.object(settings.nacp, 'languages', return_value=['en-US']), patch.dict(os.environ, {'GFXAPI': 'nvn'}):
                (Path(tmp) / 'main.fixups.tsv').write_text('# RENDER_SCALE\t1\n')   # the render scale row's condition
                listed = settings.build(gid, tmp, Path(tmp) / 'control.nacp')
            self.assertEqual({s['env']: s for s in listed['settings']}['DM_RENDER_SCALE'].get('base'), base)
            self.assertEqual(conforms(listed, schema, schema), [])
        for bad in ('1600x900', '1600x900 1280', 'big small', '1600x900x3 1280x720', 'a1600x900 1280x720', '1600x900 1280x720 640x360'):
            with self.subTest(bad=bad):
                profile = type('Profile', (), {'id': BOTW, 'get': lambda self, key, default='', bad=bad: bad})()
                with self.assertRaises(SystemExit): settings.render_base(profile)

    def test_table_format_is_strict(self):
        good = 'DM_X\ttoggle\t-\t0\talways\tGame\tX\n'
        for bad, why in [('DM_X\ttoggle\t-\t0\talways\tGame\tX\t\tlevel=basic\textra\n', 'columns'),
                         ('DM_X\ttoggle\t-\t0\talways\tGame\tX\t\tneeds=DM_NOPE=1\n', 'no row sets'),
                         ('DM_Y\ttoggle\t-\t0\talways\tGame\tY\t\tneeds=DM_X=on\n', 'never takes'),
                         ('DM_X\ttoggle\t-\t0\talways\tX\n', 'columns'), ('DM_X\ttoggle\t-\t0\talways\tsecret\tX\n', 'section'),
                         ('DM_X\ttoggle\ton\t0\talways\tGame\tX\n', 'toggle values'), ('DM_X\ttoggle\t-\t2\talways\tGame\tX\n', 'defaults to 0 or 1'),
                         ('DM_X\trange\t0:1:0.1\t0\talways\tGame\tX\t\tformat=unknown\n', 'meta'),
                         ('DM_X\ttoggle\t-\t0\talways\tGame\tX\t\tformat=number\n', 'only to range')]:
            with self.subTest(why=why), tempfile.TemporaryDirectory() as tmp:
                (Path(tmp) / 'settings.tsv').write_text('# header\n' + good + bad, encoding='utf-8')
                with patch.object(settings, 'HERE', Path(tmp)), \
                        patch.object(settings.nacp, 'languages', return_value=['en-US']), self.assertRaises(SystemExit) as e:
                    settings.build(BOTW, tmp, Path(tmp) / 'control.nacp')
                self.assertIn(why, str(e.exception))


def conforms(value, node, root, at='$'):
    """The JSON Schema keywords launcher.schema.json uses (type, required, properties, items, enum, const, pattern, $ref, allOf with
    if / then), as a list of problems: enough to hold the written lists to the contract without a jsonschema package"""
    if '$ref' in node: return conforms(value, root['$defs'][node['$ref'].rsplit('/', 1)[1]], root, at)
    problems = []
    kinds = {'object': dict, 'array': list, 'string': str, 'integer': int, 'number': (int, float)}
    if 'type' in node and not isinstance(value, kinds[node['type']]): return [f'{at}: not a {node["type"]}']
    if 'const' in node and value != node['const']: problems.append(f'{at}: not {node["const"]!r}')
    if 'enum' in node and value not in node['enum']: problems.append(f'{at}: not one of {node["enum"]}')
    if 'pattern' in node and not re.search(node['pattern'], value): problems.append(f'{at}: does not match {node["pattern"]}')
    if isinstance(value, dict):
        problems += [f'{at}: no {k}' for k in node.get('required', []) if k not in value]
        for k, v in value.items():
            if k in node.get('properties', {}): problems += conforms(v, node['properties'][k], root, f'{at}.{k}')
        for rule in node.get('allOf', []):
            if not conforms(value, rule['if'], root, at): problems += conforms(value, rule['then'], root, at)
    if isinstance(value, list) and 'items' in node:
        for i, v in enumerate(value): problems += conforms(v, node['items'], root, f'{at}[{i}]')
    return problems


if __name__ == '__main__':
    unittest.main()
