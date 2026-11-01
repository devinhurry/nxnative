"""Player settings expose only a profile's optional supported features."""
from pathlib import Path
import sys,tempfile,unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'games'))
import settings

class ResolutionSetting(unittest.TestCase):
    def test_framegen_scene_boundaries_require_complete_keys(self):
        profile=settings.game.load('01007EF00011E000')
        valid='bd7ffdd435c6c3bc f7ee6fe10b925543'
        get=profile.get
        for value in (valid, 'bd7ffdd4', valid+' trailing', ' '):
            with self.subTest(value=value),patch.object(profile,'get',side_effect=lambda key,default=None,value=value: value if key=='framegen_scene' else get(key,default)):
                if value==valid:
                    self.assertIn(valid,settings.game.header(profile))
                else:
                    with self.assertRaisesRegex(SystemExit,'full 16-digit shader keys'):
                        settings.game.header(profile)

    def test_verified_rewrite_required(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(settings.nacp,'languages',return_value=['en-US']):
            p=Path(tmp)/'main.fixups.tsv'
            for header,supported in [('# BUILD_ID\t3c10ec35c5ef4c3686b4053afb0e58e7\n',False),
                                     ('# DYNAMIC_RESOLUTION\t1\n',True),('',False)]:
                p.write_text(header)
                for gid in ('010056B015FE8000','01007EF00011E000'):
                    rows=settings.build(gid,tmp,'unused')['settings']
                    dr=[s for s in rows if s['env']=='DM_DYNAMIC_RESOLUTION']
                    self.assertEqual(bool(dr),supported)
                    if dr:self.assertEqual((dr[0]['kind'],dr[0]['default']),('toggle','0'))
                    fps=next(s for s in rows if s['env']=='DM_FPS_TARGET')
                    self.assertEqual(fps['default'],'60')
                    self.assertEqual(fps['options'],[['30','30 fps'],['60','60 fps']])

    def test_frame_generation_switch_requires_profile_inputs(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(settings.nacp,'languages',return_value=['en-US']):
            for gid, offered in [('01007EF00011E000',True),('010015100B514000',False),('010056B015FE8000',False)]:
                rows=settings.build(gid,tmp,'unused')['settings']
                fg=[s for s in rows if s['env']=='DM_FRAMEGEN']
                self.assertEqual(bool(fg),offered)
                if fg:
                    self.assertEqual(fg[0]['default'],'0')
                    self.assertFalse(fg[0].get('needs'))
                    self.assertEqual((fg[0]['kind'],fg[0]['on'],fg[0]['off'],fg[0]['level']),('toggle','30','0','basic'))

            # Listing follows the supplied capability, not a fixed title ID.
            header=settings.game.header(settings.game.load('010015100B514000'))
            header=header.replace('#define DM_GAME_FRAMEGEN_SCENE ""','#define DM_GAME_FRAMEGEN_SCENE "bd7ffdd435c6c3bc"')
            header=header.replace('#define DM_GAME_FRAMEGEN_CAMERA ""','#define DM_GAME_FRAMEGEN_CAMERA "0:2336"')
            with patch.object(settings.game,'header',return_value=header):
                rows=settings.build('010015100B514000',tmp,'unused')['settings']
                self.assertIn('DM_FRAMEGEN',[s['env'] for s in rows])

if __name__=='__main__':unittest.main()
