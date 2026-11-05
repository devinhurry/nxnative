# Cinematic colour table

`cinematic.cube` is **TEAL LOOK FOR REC 709 V2**, by **tjtop**, from
[FreshLUTs #285](https://freshluts.com/luts/285). OpenShot distributes the same
table as `src/colors/teal_&_orange_vibes/teal_punch.cube` under **CC0 1.0**;
see its [authors and licensing statement](https://github.com/OpenShot/openshot-qt/blob/55123d798ff95d91ae459d9ea18780dac43eaf68/src/colors/AUTHORS.md).

Source revision: `55123d798ff95d91ae459d9ea18780dac43eaf68` of
`https://github.com/OpenShot/openshot-qt`. The table is unmodified, 33 by 33 by
33, with red varying fastest. It is a creative SDR Rec.709 look, not a camera
Log conversion. Black and white map to themselves. The presentation shader
applies it to the existing display-encoded SDR bytes, with no additional sRGB
decode or encode. It does not change geometry, exposure or the game's fog.

CC0 1.0: <https://creativecommons.org/publicdomain/zero/1.0/>

`dm/gfx/tools/host_msl.py` embeds the CUBE source alongside the host's Metal
libraries, so Mac and iOS use exactly the same offline asset. No game shader
extraction or translation is needed.
