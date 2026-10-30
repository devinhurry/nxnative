# BOTW UI inventory and touch regression

This workflow finds UI resources and native screens without depending on a player
to discover every missing button. It does not equate an asset, a known screen
prefix, or an emitted input with a successful interaction. The current manual
acceptance record remains [Menu touch progress](botw-menu-touch-progress.md).

The [implementation checklist](botw-touch-implementation.md) is the separate
record of every classified layout and required screen/state/action. It names
the code for each implemented interaction and keeps missing/partial work
independent of unverified or unavailable game states. Its source is
`dm/games/01007EF00011E000/touch_ui_inventory.json`; validate and regenerate it
with `python3 dm/tools/botw_touch_progress.py`.

## Evidence and gaps

`dm/tools/botw_ui_audit.py` uses the BFLYT pane/part format documented by the
[SwitchThemeInjector pane reader](https://github.com/exelix11/SwitchThemeInjector/blob/master/SwitchThemesCommon/Bflyt/Pan1Pane.cs)
and [part reader](https://github.com/exelix11/SwitchThemeInjector/blob/master/SwitchThemesCommon/Bflyt/Prt1Pane.cs).
It follows SARC archives, including Yaz0 and nested archives, throughout each
supplied RomFS folder or `DMROMFS1` image. It inventories BFLYT layouts, their
pane paths, component references and control declarations, plus BFLAN animations.
It reads no keys and extracts no textures or game binaries into this repository.
Malformed, oversized or unsupported UI archives are reported as scan errors.

| Evidence | Meaning |
| --- | --- |
| Resource present | A layout exists, including reusable components. This is not a screen count. |
| Routing classified | Its name matches the host's ordered screen policy. This is not an action binding. |
| Registered | The native screen registry exposed it, including hidden screens. |
| Observed | A fresh active menu snapshot exposed its actual touch targets. |
| Touch attempted | The replay tool sent a touch to that live target. |
| Touch asserted | A later native snapshot met an explicit outcome that was false before the touch. |

An asserted screen has at least one asserted interaction, not every control or
conditional state. `cases.json` tracks individual observed targets separately.
Generated targets have no automatic success assertion: they remain pending until
the expected native result is specified. A native focus assertion proves focus;
it does not prove displayed text, a completed purchase or the visual result.

Gaps include unknown registered screens, native names without an exact resource
match, unclassified top-level resources, input-owning shown menus with no mapped
targets across a full 30-frame heartbeat, and observed screens without a touch
assertion. Unclassified components are not automatically declared broken menus.
An archive or a story/DLC state not supplied or reached stays unverified.
Slate children require a shown, input-owning AppHome parent; retained children
during closing/loading do not become false unmapped-menu reports.

## Scan and collect

Keep output on the game's drive, outside the repository:

```sh
python3 dm/tools/botw_ui_audit.py scan "$DM_ROMFS" --out "$UI_REPORT"
```

Supply additional RomFS directories/images as further positional arguments for
add-on content. The initial full scan decompresses archives and can take several
minutes. Keep `catalogue.json`; reporting after a routing change does not require
rescanning unchanged resources. Rescan after updating the game or its content.

Set `DM_BOTW_UI_AUDIT` to an absolute output JSONL filename before launching the
game. Set `DM_CTL` to an absolute control-file path in the same work directory:

```sh
DM_BOTW_UI_AUDIT="$UI_REPORT/audit.jsonl" DM_CTL="$UI_REPORT/ctl" \
  python3 scripts/run_mac.py --test --touch-preview --game "$GAME_FOLDER"
```

Recording defaults off. It uses the existing exact-build pane/selector
observations, changes no guest state, and records nothing during controller
mode. Other games keep their existing routing. The session header contains the
build and shared-policy fingerprint. Events record screen registration/state
changes and semantic menu snapshots. Stable snapshots have a 30-frame heartbeat.
IDs use native pane paths and roles; raw root addresses are diagnostic only.

For an iOS diagnostic build, the switch can name a writable file in the app's
Documents directory. Copy it back with the other diagnostics. Mac replay is not
physical-iPhone acceptance.

Start the optional live gap collector before driving a route:

```sh
python3 dm/tools/botw_ui_audit.py watch --audit "$UI_REPORT/audit.jsonl" \
  --ctl "$UI_REPORT/ctl" --out "$UI_REPORT/gaps" --seconds 300
```

It follows new records only. For a new unknown input owner or persistent unmapped
menu, it records the event and requests the next presented screenshot and native
pane-tree dump. Dumps go to the normal game log. A requested screenshot provides
investigation context; it is not a pixel assertion.

## Replay and report

Use a disposable copy of a supplied save. Routes are explicit input sequences;
the tool does not explore by randomly confirming choices, buying or saving.
Each step specifies `when`, one `tap`, `swipe` or setup `key`, and `expect`.
Touch selectors use live roles, pane paths, button masks or adjustment directions.
The runner waits for a unique live target; ambiguous targets fail. Coordinates come from current native
bounds, never saved pixel positions.

```json
{
  "schema": 1,
  "steps": [{
    "name": "Select a different native row",
    "when": {"screen": "Example_00", "active": 1},
    "tap": {"path_suffix": "/Pa_Row_02/B_Hit_00"},
    "expect": {"focus_suffix": "/Pa_Row_02/N_Cursor_00"}
  }]
}
```

That example documents the schema, not an actual BOTW route. Use the profile's
checked-in routes or refine the generated pending candidates. Swipes use
`{"target": {"kind": "map"}, "dx": 0.1, "dy": 0}`. Native focus, menu mode,
group, gameplay presentation and target appearance can be asserted. A predicate
already true before input fails. Use `target` in an expectation to require a
particular resulting control.

The checked-in routes under `dm/games/01007EF00011E000/touch_routes/` cover
Title/Continue/loading, an Inventory/System/Options/DLC/Slate round trip, and
entering/leaving Hero's Path. Each file states its save/content prerequisites.
The standalone DLC-information Back route starts on that page; it is not
expected to appear automatically on every launch. Hero's Path is a separate
case context, so a regular map interaction cannot count as its acceptance.

```sh
python3 dm/tools/botw_ui_audit.py replay "$ROUTE" \
  --audit "$UI_REPORT/audit.jsonl" --ctl "$UI_REPORT/ctl" --out "$UI_REPORT/replay"
python3 dm/tools/botw_ui_audit.py report "$UI_REPORT/catalogue.json" \
  --audit "$UI_REPORT/audit.jsonl" --results "$UI_REPORT/replay/replay.json" \
  --out "$UI_REPORT"
```

Replay records outcomes and requests screenshots; it stops at the first failure.
Setup keys do not count as touch acceptance. Results retain their assertions and
fingerprint the audit-file prefix, policy and native adapter source. A changed
adapter requires fresh replay. Launch through `run_mac.py --test` to ensure the
running host actually contains that source; these checks do not update a stale
game process. Repeat `--audit` and `--results` to combine save fixtures. `report --check`
fails on scan/evidence errors, observed unknown screens or persistent unmapped
owners. Unvisited resources remain pending rather than failing as known bugs.

Before closing a touch task, regenerate the report, investigate new runtime gaps,
add a semantic regression for a fixed shared role, and update the progress record
with evidence and unvisited states. Native and synthetic resource/replay tests
run in CI without game files. Runtime routes stay local because CI has neither
the game nor its saves.
