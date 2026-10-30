"""Completion must account for actions/resources, without demanding save access."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('botw_touch_progress', Path(__file__).resolve().parents[1] / 'botw_touch_progress.py')
assert SPEC and SPEC.loader
progress = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(progress)


class ProgressTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        (self.repo / 'input.c').write_text('void select_item(void) {}\n')
        self.data = {
            'schema': 1, 'scope': {'other_games_or_controller_input_affected': False},
            'totals': {'layouts': 1, 'requirements': 1},
            'requirements': [{'id': 'list.select', 'screen': 'List', 'state': 'shown',
                'action': 'Select exact item', 'implementation_status': 'implemented',
                'implementation_status_reason': 'Native owner selects exact item.',
                'implementation_evidence': [{'file': 'input.c', 'function': 'select_item', 'why': 'Native selection.'}],
                'verification_status': 'blocked', 'verification_level': 'none', 'verification_reason': 'Save unavailable.'}],
            'layouts': [{'layout_id': 'List', 'name': 'List', 'source': 'List.bflyt', 'sha256': 'a' * 64,
                'disposition': 'interactive_screen', 'classification_reason': 'Native list owner.',
                'requirement_ids': ['list.select'], 'component_refs': []}]}

    def check(self, **kwargs):
        return progress.validate(self.data, self.repo, **kwargs)

    def test_implemented_but_unverified_is_complete(self):
        self.assertEqual(self.check(require_complete=True), [])

    def test_native_registration_cannot_replace_action_implementation(self):
        row = self.data['requirements'][0]
        row['implementation_status'] = 'partial'
        row['implementation_gap'] = 'Direct selection missing; name admission only.'
        self.assertEqual(self.check(), [])
        self.assertTrue(any('partial' in error for error in self.check(require_complete=True)))

    def test_unclassified_and_unlinked_screens_fail(self):
        self.data['layouts'][0]['disposition'] = 'unknown'
        self.assertTrue(any('unclassified' in error for error in self.check()))
        self.data['layouts'][0]['disposition'] = 'interactive_screen'
        self.data['layouts'][0]['requirement_ids'] = []
        self.assertTrue(any('action requirements' in error for error in self.check()))

    def test_stale_source_evidence_fails(self):
        (self.repo / 'input.c').write_text('void another_function(void) {}\n')
        self.assertTrue(any('function not found' in error for error in self.check()))

    def test_new_resource_and_full_part_reference_must_be_classified(self):
        row = copy.deepcopy(self.data['layouts'][0])
        row.update(source='/external/game::List.bflyt', panes=[{'path': 'Root/Part', 'part': 'PaLongComponentReference_00'}])
        catalogue = {'layouts': [row]}
        self.assertTrue(any('part references differ' in error for error in self.check(catalogue=catalogue)))
        self.data['layouts'][0]['component_refs'] = [{'pane_path': 'Root/Part', 'component_name': 'PaLongComponentReference_00',
            'resolved': False, 'resolution': 'missing_target_layout', 'resolution_reason': 'Unused platform illustration.'}]
        self.assertEqual(self.check(catalogue=catalogue), [])
        catalogue['layouts'].append({**row, 'name': 'NewMenu'})
        self.assertTrue(any('layout sets differ' in error for error in self.check(catalogue=catalogue)))

    def test_complete_status_cannot_keep_gap_or_skip_verification(self):
        self.data['requirements'][0]['implementation_gap'] = 'Zoom absent.'
        self.data['requirements'][0]['verification_status'] = 'not_required'
        errors = self.check(require_complete=True)
        self.assertTrue(any('still has an implementation gap' in error for error in errors))
        self.assertTrue(any('opt out of verification' in error for error in errors))

    def test_repository_inventory_is_complete_and_page_is_current(self):
        data = json.loads(progress.INVENTORY.read_text())
        self.assertEqual(progress.validate(data, require_complete=True), [])
        self.assertEqual(progress.OUT.read_text(), progress.page(data))


if __name__ == '__main__': unittest.main()
