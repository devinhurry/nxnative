"""Behavioral tests for the analysis/target-compilation split in dmsh_build."""
import ast
import collections
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
import types
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
BUILD = REPO / 'dm/gfx/tools/dmsh_build.py'
sys.path.insert(0, str(REPO / 'dm/gfx/tools'))
import dmsh_chain


def functions(names, ns):
    tree = ast.parse(BUILD.read_text())
    nodes: list[ast.stmt] = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
    found = {n.name for n in nodes if isinstance(n, ast.FunctionDef)}
    if found != set(names):
        raise AssertionError(f"missing dmsh_build functions: {set(names) - found}")
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(BUILD), 'exec'), ns)
    return ns


class AnalysisIdentity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.code = Path(self.tmp.name) / 'input.bin'; self.code.write_bytes(b'actual code bytes')
        self.ns = {'hashlib': hashlib, 'json': json, 'open': open,
            'abi': types.SimpleNamespace(VALUES={'KIND_TEX': 2}),
            'XLCACHE': types.SimpleNamespace(identity='translator-id'),
            'CODEGEN': types.SimpleNamespace(identity='cross-id'), 'XC': ['--msl-version', '20300'],
            'DUAL_WANT': set(), 'ANALYSIS_CODE_FP': {'vs':'vs-1','ps':'ps-1','cs':'cs-1','gs':'gs-1'},
            'shader_rule_source': lambda name: b'', 'PRE_STATS': collections.Counter(), 'CODEGEN_CACHE': None}
        functions({'analysis_digest','pair_keyed','valid_analysis','cached_analysis'}, self.ns)
        self.job = {'stage':'vs','code':str(self.code),'attr':{},'tex':{},'img':{},'c1':'00'}

    def digest(self, stage='vs', key='k'):
        job = dict(self.job, stage=stage)
        return self.ns['analysis_digest'](key, 'package', b'record', job, stage)

    def test_stage_fingerprints_are_independent_and_pair_pixel_digest_is_an_input(self):
        before_vs, before_ps, before_cs = self.digest('vs'), self.digest('ps'), self.digest('cs')
        self.ns['ANALYSIS_CODE_FP']['vs'] = 'vs-rewritten'
        self.assertNotEqual(before_vs, self.digest('vs'))
        self.assertEqual(before_ps, self.digest('ps'))
        self.assertEqual(before_cs, self.digest('cs'))
        self.assertNotEqual(self.ns['pair_keyed'](before_vs, ['pixel-v1']),
                            self.ns['pair_keyed'](before_vs, ['pixel-v2']))

    def test_abi_values_change_base_source_identity_but_platform_compiler_and_target_do_not(self):
        before = self.digest()
        self.ns.update(TARGETS={'ios'}, IOSOUT='/different/phone', MTL=types.SimpleNamespace(compiler_id='override'))
        self.assertEqual(before, self.digest())
        self.ns['abi'].VALUES['KIND_TEX'] = 3
        self.assertNotEqual(before, self.digest())

    def test_cached_analysis_calls_analyzer_once_and_reuses_the_complete_bundle(self):
        class Cache:
            def __init__(self): self.values={}; self.stores=[]
            def load(self,key): return self.values.get(key)
            def store(self,key,value): self.values[key]=value; self.stores.append((key,value))
        cache=Cache(); self.ns['CODEGEN']=cache; self.ns['PRE_STATS']=collections.Counter()
        complete={'kind':'shader','stage':'vs','analysis_source':'source','candidate':'candidate','fallback':'plain',
            'base_refl':{'stage':'vs'},'candidate_flags':{'layer':False,'layer_from':None,'discard':False,'tf':False,'uint':False,'uint_mask':0,'dual':False}}
        fn=mock.Mock(return_value=complete)
        a=self.ns['cached_analysis']('vs','k','package',b'record',self.job,fn,digest='known')
        b=self.ns['cached_analysis']('vs','k','package',b'record',self.job,mock.Mock(),digest='known')
        self.assertEqual(a[0],b[0]); self.assertFalse(a[2]); self.assertTrue(b[2])
        fn.assert_called_once_with(); self.assertEqual(len(cache.stores),1)

    def test_incomplete_cached_bundle_is_a_miss_and_is_replaced(self):
        class Cache:
            def __init__(self): self.payload={'stage':'vs','candidate':'truncated'}; self.saved=None
            def load(self,key): return self.payload
            def store(self,key,value): self.saved=value
        cache=Cache(); self.ns['CODEGEN']=cache; self.ns['PRE_STATS']=collections.Counter()
        complete={'kind':'shader','stage':'vs','analysis_source':'source','candidate':'candidate','fallback':None,
            'base_refl':{'stage':'vs'},'candidate_flags':{'layer':False,'layer_from':None,'discard':False,'tf':False,'uint':False,'uint_mask':0,'dual':False}}
        analyze=mock.Mock(return_value=complete)
        payload,_,hit=self.ns['cached_analysis']('vs','k','package',b'record',self.job,analyze,digest='known')
        self.assertFalse(hit); self.assertEqual(payload,complete); analyze.assert_called_once_with()
        self.assertEqual(cache.saved,complete); self.assertEqual(self.ns['PRE_STATS']['miss'],1)


class PairedVertexDependency(unittest.TestCase):
    def setUp(self):
        self.ns={'PAIRS':{'vs':['ps']},'loc':{'ps':('package',0)},'ANALYSIS_BY_KEY':{},
            'jobs':{'vs':{'stage':'vs'}},'recs':{'vs':('package',b'record')},'analysis_bundles':{},
            'analysis_only':set(),'xerr':{},'w':'/unused'}
        functions({'paired_vertex_dependency_error','fin'},self.ns)

    def test_cold_pixel_analysis_failure_blocks_vertex_before_analysis_or_cache(self):
        result=self.ns['fin']('vs')
        self.assertEqual(result[:2],('vs','dependency failed'))
        self.assertIn('ps',result[2])

    def test_warm_vertex_analysis_is_rejected_when_pixel_source_is_unavailable(self):
        self.ns['analysis_bundles']['vs']={'analysis_source':'cached vertex','candidate':'cached'}
        result=self.ns['fin']('vs')
        self.assertEqual(result[:2],('vs','dependency failed'))
        self.assertIn('ps',result[2])

    def test_valid_pixel_analysis_allows_vertex_even_when_target_compile_fails(self):
        self.ns['jobs']['ps']={'stage':'ps'}
        self.ns['recs']['ps']=('package',b'record')
        self.ns['analysis_bundles']['ps']={'analysis_source':'canonical pixel source','candidate':'pixel candidate'}
        self.ns['analysis_bundles']['vs']={'analysis_source':'canonical vertex','candidate':'candidate'}
        compile_error=subprocess.CalledProcessError(1,['metal'],'','target compile failed')
        materialize=mock.Mock(side_effect=[compile_error, ('ok','',{'stage':'vs'})])
        self.ns['materialize_shader']=materialize
        self.ns['subprocess']=subprocess
        ps_result=self.ns['fin']('ps')
        self.assertEqual(ps_result[:2],('ps','analysis failed'))
        self.assertEqual(self.ns['ANALYSIS_BY_KEY']['ps'],'canonical pixel source')
        result=self.ns['fin']('vs')
        self.assertEqual(materialize.call_args_list,[mock.call('ps',self.ns['analysis_bundles']['ps']),mock.call('vs',self.ns['analysis_bundles']['vs'])])
        self.assertEqual(result[:2],('vs','ok'))

    def test_pair_absent_from_shader_rows_does_not_block_vertex(self):
        self.assertEqual(self.ns['paired_vertex_dependency_error']('vs','vs',self.ns['PAIRS'],{},{}),'')


class TargetMaterialization(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name); self.mac=self.root/'mac'; self.ios=self.root/'ios'; self.work=self.root/'tmp'
        for d in (self.mac,self.ios,self.work): d.mkdir()
        class Compiler:
            def __init__(self): self.calls=[]
            def compile(self,target,msl,lib):
                src=Path(msl).read_text(); self.calls.append((target,src))
                if target=='mac' and 'candidate' in src: raise subprocess.CalledProcessError(1,['metal'],'','reject candidate')
                Path(lib).write_bytes((target+'\0'+src).encode())
            def compile_candidates(self,target,candidates,lib):
                last=None
                for i,msl in enumerate(candidates):
                    try: self.compile(target,msl,lib); return i
                    except subprocess.CalledProcessError as e: last=e
                raise last or RuntimeError('no candidate')
            def with_compiler(self,target,refl): return dict(refl, compiler=target)
        self.compiler=Compiler()
        self.ns={'os':os,'json':json,'subprocess':subprocess,'out':str(self.mac),'IOSOUT':str(self.ios),'w':str(self.work),
            'TARGETS':{'mac','ios'},'CHAIN':'chain-current','loc':{'k':('ps_shader.bin',7)},'pc_of':{'k':'pixel-paired'},
            'MTL':self.compiler,'atomic_json':lambda path,value: Path(path).write_text(json.dumps(value,sort_keys=True)),
            'pull_finish':lambda key,sources,refls: refls,'vin_finish':lambda key,sources,refls: refls,
            'alpha_finish':lambda key,sources,refls: refls,'logic_finish':lambda key,sources,refls: refls,
            'fetch_finish':lambda key,src,bindings,refls: refls}
        functions({'active_targets','refresh_reflection','selected_reflection','write_target_refl','materialize_shader','materialize_geometry'},self.ns)

    def test_fallback_is_selected_per_target_with_independent_reflection(self):
        bundle={'kind':'shader','stage':'vs','analysis_source':'analysis','candidate':'candidate layer entry','fallback':'plain entries',
            'base_refl':{'key':'k_b','stage':'vs','entry':'main0','entry_z':'main0_z','entry_discard':'main0_discard','bindings':[]},
            'candidate_flags':{'layer':True,'layer_from':4,'discard':True,'tf':False,'uint':False,'uint_mask':0,'dual':False}}
        status,err,_=self.ns['materialize_shader']('k',bundle)
        self.assertEqual((status,err),('ok',''))
        self.assertEqual((self.mac/'k_b.metal').read_text(),'plain entries')
        self.assertEqual((self.ios/'k_b.metal').read_text(),'candidate layer entry')
        mac=json.loads((self.mac/'k_b.json').read_text()); ios=json.loads((self.ios/'k_b.json').read_text())
        self.assertNotIn('entry_layer',mac); self.assertEqual(ios['entry_layer'],'main0_l')
        self.assertEqual(mac['entry_discard'],'main0_discard'); self.assertEqual(ios['entry_discard'],'main0_discard')
        self.assertEqual([t for t,_ in self.compiler.calls],['mac','mac','ios'])

    def test_geometry_materializes_complete_variant_and_reader_family_per_requested_target(self):
        suffixes=['_b','_bg0','_bg1','_bg2','_bg3','_bg4','_bgv','_bl0']
        outputs={s:{'msl':'source'+s,'reflection':{'key':'k'+s,'stage':'gs','geometry':{'variant':s}}} for s in suffixes}
        bundle={'kind':'geometry','stage':'gs','analysis_source':'source_b','outputs':outputs}
        status,err,_=self.ns['materialize_geometry']('k',bundle)
        self.assertEqual((status,err),('ok',''))
        for suffix in suffixes:
            for d in (self.mac,self.ios):
                self.assertTrue((d/f'k{suffix}.metal').is_file())
                self.assertTrue((d/f'k{suffix}.metallib').is_file())
                self.assertTrue((d/f'k{suffix}.json').is_file())

    def test_target_switch_only_compiles_requested_target_and_keeps_mac_analysis_source(self):
        self.ns['TARGETS']={'ios'}
        bundle={'kind':'shader','stage':'cs','analysis_source':'canonical','candidate':'canonical','fallback':None,
            'base_refl':{'key':'k_b','stage':'cs','bindings':[]},
            'candidate_flags':{'layer':False,'layer_from':None,'discard':False,'tf':False,'uint':False,'uint_mask':0,'dual':False}}
        self.ns['materialize_shader']('k',bundle)
        self.assertEqual([t for t,_ in self.compiler.calls],['ios'])
        self.assertEqual((self.mac/'k_b.metal').read_text(),'canonical')
        self.assertFalse((self.mac/'k_b.metallib').exists())
        self.assertTrue((self.ios/'k_b.metallib').is_file())


class VariantSemanticIdentity(unittest.TestCase):
    def test_helper_edit_invalidates_variant_label_without_editing_entry(self):
        with tempfile.TemporaryDirectory() as td:
            module=Path(td)/'variant.py'
            module.write_text('def helper(x): return x + 1\ndef variant(x): return helper(x)\n')
            module_obj=types.SimpleNamespace(__file__=str(module),__name__='fixture.variant')
            def refresh_fingerprint():
                ns['VARIANT_MODULE_FP']['fixture.variant']=hashlib.sha256(dmsh_chain.code_form(module.read_text())).hexdigest()
            ns={'dmsh_chain':dmsh_chain,'abi':types.SimpleNamespace(VALUES={'SLOT':1}),'hashlib':hashlib,
                'VARIANT_MODULE_FP':{},'VARIANT_ABI_VALUES':[('SLOT',1)]}
            functions({'variant_semantic_label'},ns)
            refresh_fingerprint()
            label=ns['variant_semantic_label']('vin',[module_obj])
            module.write_text('def helper(x): return x + 2\ndef variant(x): return helper(x)\n')
            refresh_fingerprint()
            self.assertNotEqual(label,ns['variant_semantic_label']('vin',[module_obj]))
            ns['VARIANT_ABI_VALUES']=[('SLOT',2)]
            self.assertNotEqual(label,ns['variant_semantic_label']('vin',[module_obj]))


if __name__=='__main__': unittest.main()
