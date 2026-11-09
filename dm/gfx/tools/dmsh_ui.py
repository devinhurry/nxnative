"""Offline fragment variant that copies colour 0 to a separate HUD attachment.

The game still draws once with its original outputs, depth and blending.  The
variant shares the current shader pipeline's fragment body and alpha test.
"""
import re
import dmsh_abi
import dmsh_alpha
import dmsh_side


def variant(msl):
    structure = re.search(r'struct main0_out\s*\{(.*?)\};', msl, re.S)
    if not structure or re.search(r'\[\[color\(7\)', structure.group(1)):
        return None, 'no free colour 7 output'
    colour = re.search(r'\b((?:float|half)([234])?)\s+(\w+)\s*\[\[color\(0\)\]\]', structure.group(1))
    if not colour:
        return None, 'no float colour 0 entry'
    source = dmsh_side.shared_body(msl)
    if source is None:
        return None, 'no supported fragment body'
    try:
        entry = dmsh_side.entry(source, 'main0')
    except ValueError:
        return None, 'no supported fragment entry'
    if not entry or entry['ret'] != 'main0_out':
        return None, 'no fragment entry main0'
    # The first entry follows its shared body and all helper declarations.
    # Sibling entries are irrelevant to this float-colour-only variant.
    source = source[:entry['start']]
    structure = re.search(r'struct main0_out\s*\{(.*?)\};', source, re.S)
    if not structure:
        return None, 'no output structure'
    at = structure.start(1)
    source = source[:at] + '\n    float4 dm_framegen_ui [[color(7)]];' + source[at:]
    count = int(colour.group(2) or 1)
    value = 'out.' + colour.group(3)
    value = f'float4({value})' if count == 4 else f'float4({value}, ' + ', '.join(['0.0'] * (3 - count) + ['1.0']) + ')'
    copy = f'out.dm_framegen_ui = {value}; if (dm_framegen_opaque) out.dm_framegen_ui.a = 1.0;'
    source += f'\nconstant bool dm_framegen_opaque [[function_constant({dmsh_abi.LOGIC_FC + 8})]];\n'
    source += dmsh_side.calling(entry, 'main0', 'main0_out', copy + ' return out;')
    names = ['main0']
    if not dmsh_alpha.refused(msl):
        params = ', '.join(entry['params'] + [f'constant dm_alpha_state& dm_alpha [[buffer({dmsh_abi.ALPHA_BUFFER})]]'])
        source += dmsh_alpha.HELPER
        source += (f'{entry["attr"]}fragment main0_out main0_alpha({params})\n{{\n'
                   f'    main0_out out = dm_body_main0({entry["args"]});\n'
                   f'    if (!dm_alpha_pass(float(out.{colour.group(3)}.w), dm_alpha)) discard_fragment();\n'
                   f'    {copy} return out;\n}}\n')
        names.append('main0_alpha')
    return source, names
