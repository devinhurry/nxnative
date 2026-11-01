"""Offline fragment variant: preserve the game's outputs and copy colour 0 to
attachment 7 for a separate premultiplied UI layer (MacNativeGames, MIT).
The pipeline keeps the original draw, depth/stencil tests and colour blend.
"""
import re
import dmsh_abi
import dmsh_alpha


def variant(msl):
    structure = re.search(r'struct main0_out\s*\{(.*?)\};', msl, re.S)
    if not structure or re.search(r'\[\[color\(7\)', structure.group(1)):
        return None, 'no free colour 7 output'
    colour = re.search(r'\b((?:float|half)([234])?)\s+(\w+)\s*\[\[color\(0\)\]\]', structure.group(1))
    entries = list(dmsh_alpha.ENTRY.finditer(msl))
    if not colour or not entries or entries[0].group(1) != 'main0':
        return None, 'no float colour 0 entry'
    if 'main0_out out = {};' not in msl:
        return None, 'no output variable out'
    # Integer / dual-source siblings are not used for this float UI target.
    body = msl.index('{', entries[0].end())
    end, depth = body + 1, 1
    while depth and end < len(msl):
        depth += (msl[end] == '{') - (msl[end] == '}')
        end += 1
    if depth:
        return None, 'unclosed fragment entry'
    source = msl[:end] + '\n'
    at = structure.start(1)
    source = source[:at] + '\n    float4 dm_framegen_ui [[color(7)]];' + source[at:]
    count = int(colour.group(2) or 1)
    value = 'out.' + colour.group(3)
    value = f'float4({value})' if count == 4 else f'float4({value}, ' + ', '.join(['0.0'] * (3 - count) + ['1.0']) + ')'
    copy = f'out.dm_framegen_ui = {value}; if (dm_framegen_opaque) out.dm_framegen_ui.a = 1.0;'
    source = source.replace('return out;', '{ ' + copy + ' return out; }')
    entry = dmsh_alpha.ENTRY.search(source)
    assert entry is not None
    start = entry.start()
    # These side entries use the next slot after the eight logic-target flags;
    # the common shader ABI and unrelated base libraries stay unchanged.
    source = source[:start] + f'constant bool dm_framegen_opaque [[function_constant({dmsh_abi.LOGIC_FC + 8})]];\n' + source[start:]
    alpha, _ = dmsh_alpha.variant(source)
    names = ['main0']
    if alpha:
        entry = dmsh_alpha.ENTRY.search(source)
        alpha_entry = dmsh_alpha.ENTRY.search(alpha)
        assert entry is not None and alpha_entry is not None
        start = entry.start()
        alpha_start = alpha_entry.start()
        source = source[:start] + dmsh_alpha.HELPER + source[start:] + '\n' + re.sub(r'\bmain0\s*\(', 'main0_alpha(', alpha[alpha_start:], count=1)
        names.append('main0_alpha')
    return source, names
