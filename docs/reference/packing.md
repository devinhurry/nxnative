# Packing

## Compressed inputs

### NSZ decompression rejects `--keys`

- **Symptom:** `decompress NSZ` stops immediately with `nsz: error: unrecognized arguments: --keys …`.
- **Cause:** `nsz` 4.6.1 has no `--keys` argument. It loads `keys.txt` beside `sys.argv[0]`, or falls back to `~/.switch/prod.keys`, while importing its modules, before parsing arguments ([4.6.1 key loader](https://github.com/nicoboss/nsz/blob/4.6.1/nsz/nut/Keys.py)). Newer upstream code supports `--keys`; staging `keys.txt` also supports 4.6.1.
- **Fix:** `scripts/build_ipa_from_nsp.py` `decompress_nsz` links the file selected by `-k` as `keys.txt` in the conversion's temporary folder and runs `nsz -D` there, with `sys.argv[0]` set to `nsz` before import. Input and output paths are absolute. The temporary folder and link are removed on success or failure; the user's default keys are untouched.
- **Found on:** [Super Mario Odyssey](../../dm/games/0100000000010000/README.md), converting its v0 NSZ. Applies to NSZ and XCZ inputs for every game.
