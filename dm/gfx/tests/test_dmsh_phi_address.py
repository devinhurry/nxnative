#!/usr/bin/env python3
"""Address origins across predicated assignments must use actual SSA incoming edges.
Known complementary writes need no arbitrary-memory lookup; genuine unknown
alternatives and changed predicates keep their fallback. No game assets required.
"""
import os,unittest
import test_dmsh_storage_offset as storage
from test_dmsh_maxwell_ftz import s2r_tid,fsetp,code,sts,EXIT,RZ


def guarded(inst,predicate):
    return (inst & ~(15<<16)) | predicate<<16


@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'),'requires offline translator')
class AddressPhi(unittest.TestCase):
    def translate(self,second=True,changed=False,other_base=False):
        body=[s2r_tid(0),s2r_tid(2),s2r_tid(3),fsetp(0,RZ,False)]
        body += [guarded(storage.mov_c(2,0,0x110),0),guarded(storage.mov_c(3,0,0x114),0)]
        if changed:
            body += [storage.iadd_c(0,0,1,0),fsetp(0,RZ,False)]
        if second:
            base=0x120 if other_base else 0x110
            body += [guarded(storage.mov_c(2,0,base),8),guarded(storage.mov_c(3,0,base+4),8)]
        body += [storage.ldg(4,2),sts(4,8),EXIT]
        return storage.StorageOffset().translate(dict(stage='cs',shared=0x1000),code(*body))[0]

    def test_complementary_writes_of_one_base_need_no_global_table(self):
        r=self.translate()
        self.assertFalse(any(b['cb_slot']==255 for b in r['sbufs']),r)
        self.assertIn((0,0x110//4),[(b['cb_slot'],b['cb_offset']) for b in r['sbufs']])

    def test_actual_unknown_alternative_keeps_global_fallback(self):
        r=self.translate(second=False)
        self.assertTrue(any(b['cb_slot']==255 for b in r['sbufs']),r)

    def test_changed_predicate_is_not_assumed_complementary(self):
        r=self.translate(changed=True)
        self.assertTrue(any(b['cb_slot']==255 for b in r['sbufs']),r)

    def test_two_known_alternatives_keep_both_buffers(self):
        r=self.translate(other_base=True)
        self.assertFalse(any(b['cb_slot']==255 for b in r['sbufs']),r)
        slots={(b['cb_slot'],b['cb_offset']) for b in r['sbufs']}
        self.assertTrue({(0,0x110//4),(0,0x120//4)}<=slots,r)

if __name__=='__main__':unittest.main()
