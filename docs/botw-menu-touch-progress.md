# BOTW menu touch progress

Updated: 2026-10-27 (Asia/Shanghai).

This is the active progress tracker. Update it after each verified feature or new failure. `HANDOFF.md` is historical context, not the current status.

## Scope and acceptance rules

- BOTW touch mode only. Physical controllers and other games retain their existing behavior.
- Complete menu touch interaction; preserve the existing movement, combat and rune controls.
- Use the game's live controls, geometry, list state and native selection entry points. A distant item must select directly, without walking through intermediate items with direction inputs.
- Both the icon and text of a button hint should respond. Movement and zoom hints map to gestures.
- Only the current input-owning menu may respond. Hidden, covered, stale or ambiguous targets must not respond.
- Keep implementation checks, Mac runtime evidence and iPhone validation separate.

## Coverage

Mac evidence below uses the current menu implementation with an existing matching graphics runtime/cache. Runtime validation of the complete upstream merge remains a separate item.

| Surface | Status | Evidence or remaining work |
| --- | --- | --- |
| Title, Continue and load confirmation | Mac verified | Touch can enter gameplay without a fallback confirmation key. |
| Inventory direct item selection | Mac verified | Distant slots update native selection and item details directly. |
| Inventory action popup and cancellation | Mac verified | Uses the active popup's native targets and confirm/back actions. |
| Inventory categories, Sort and Hold hints | Partial Mac regression | Bow/shield/material categories and popups passed. Food category and its Eat/Cancel popup now pass. Tapping Y Sort visibly reorders the weapon inventory and displays the native sorted message. X Hold opens holding mode; inline holding prompts still need final checks. |
| System menu entries | Mac verified | Options opens directly; the load sequence also passed. |
| Map taps and stamp popup | Mac verified | Correct pointer position; both the B icon and Back text dismiss the stamp popup. |
| Map/Runes header hints | Mac verified | L/R hints use their final rendered positions. R opens the empty album; its Back text returns to gameplay without a cursor selection. AppHome prompts are published from live guide/header panes even when BoxCursor updates stop. |
| Startup and loading controls | Mac and UIKit verified | Gameplay controls start hidden and require a fresh, shown, input-enabled MainScreen HUD. Title and loading keep the Mac preview in menu routing; gameplay alone restores the artwork. Physical-controller and non-BOTW routing remain unchanged. |
| Map drag | Mac verified; iPhone pending | Replaced held-stick velocity with native position updates. Horizontal/vertical displacement follows the finger, holding still does not drift, release stops, reverse drag restores the map. Uses the inverse rendered transform for zoom/rotation. |
| Map pinch zoom | Implemented; platform checks incomplete | Zoom channel ownership and lifetime have code coverage; iPhone multitouch remains unverified. |
| Gameplay controls flashing during menu actions/slides | Mac state trace and UIKit checks passed; iPhone gameplay pending | Menu presentation is separate from clickable-target availability. L/R slides and item popup/cancel kept controls hidden: 12 frontend queries, zero false answers, including 6 with no clickable targets. Closing restored controls. Observe native screen lifecycle and root visibility each UI frame; retained map/rune children cannot outlive their AppHome owner. |
| Quest rows | Mac verified | Direct native list selection updates the matching details. |
| Quest categories | Mac verified | Main Quests and Memories switch directly; unavailable categories do not activate. |
| Quest/Memories vertical swipe | Mac verified | Native paging between rows 1-5 and 6-10; tapping row 8 then selects it directly. Paging occurs on release, without continuous finger-following animation. |
| Options arrows and ON/OFF | Mac verified | Right arrow: Normal to Fast; left: Fast to Normal; OFF/ON labels choose the corresponding value. |
| Options list swipe | Mac verified | Swipes use the complete native row bounds, including blank padding between text and values. An upward swipe reaches Voice Language; a downward swipe restores the first rows. Taps retain their narrower native targets. Scrolling occurs on release, without continuous finger-following animation. |
| Options horizontal value gestures | Implementation checks passed; runtime pending | Horizontal swipes select the same live left/right arrow or ON/OFF target as a tap, then use the native adjustment path. Missing directions never become Confirm. |
| Dialogue continuation arrow | Implementation checks passed; runtime pending | Requires a visible, input-enabled Message owner. Cursor choices, hidden arrows, inactive touch and conflicting roots are rejected. No NPC runtime evidence yet. |
| Dialogue choices | Pending verification/completion | Exercise native choice selection with an actual NPC. |
| Shops, buy/sell and quantity | Pending completion | Verify shared native list ownership, quantity controls, confirmations and covered menus. |
| Album/photo operations | Pending verification/completion | Thumbnail selection, viewing, paging, delete confirmation and Back. |
| Other confirmations, help and save/load dialogs | Partial | Load, cancellation, Options Y Restore and Cancel passed. Covered Options arrows cannot activate through the restore dialog. Remaining dialog variants still need checking. |
| Complete merged runtime and iPhone regression | Pending | Match upstream graphics caches; verify controller connection, menu exit, gesture cancellation and multitouch. |

## Next work

1. Verify horizontal Options gestures and inline inventory holding prompts.
2. Copy the user-provided `save-yizhan` slot into isolated external scratch and verify NPC dialogue, shop/quantity interaction and populated album operations. Preserve the original save.
3. Run one menu-flow regression and check touch/controller isolation, rather than repeating all checks after every small edit.

## Evidence

Evidence directory (external scratch, not repository assets):

`/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/inventory-touch-20261025/run12/`

| Files | Result |
| --- | --- |
| `s84-quest-adapter-row1-touch.png`, `s85-quest-adapter-row0-retap.png` | Direct quest row selection and matching details. |
| `s88-quest-category-memories-touch.png`, `s89-quest-disabled-category-touch.png`, `s90-quest-main-category-return.png` | Available category changes and unavailable category rejection. |
| `s93-quest-scroll-next-page.png`, `s94-quest-scroll-row8-tap.png`, `s95-quest-scroll-previous-page.png` | Native paging, direct row 8 selection and reverse paging. |
| `run-quest-category-20261026.log`, `run-quest-scroll-20261026.log` | Corresponding native selection/page records. |
| `s97-options-touch-open.png`, `s98-options-camera-right-touch.png` | Options opens; original arrow-only-focus failure reproduced. |
| `s104-options-right-arrow-fast.png`, `s105-options-left-arrow-normal.png` | Arrow adjustment works in both directions. |
| `s106-options-invert-off.png`, `s107-options-invert-on.png` | OFF/ON label adjustment works. |
| `run-options-adjust-20261026.log` | Native left-stick adjustment pulse after focus; no A or repeated direction walking. |
| `s108-shared-menu-field-load.png` | Shared-list build reaches gameplay through touch loading. |
| `s114-options-owned-baseline.png`, `s115-options-owned-swipe.png` | Options value-area swipe reveals Voice Language; no setting activated. |
| `s116-options-label-swipe-down.png` | Label-area swipe failure before the right-anchor correction. |
| `s117-options-label-swipe-up-fixed.png`, `s118-options-label-swipe-down-fixed.png` | Corrected label hit boxes: upward and downward native scrolling passed. |
| `s119-options-restore-touch-dialog.png`, `s120-options-covered-arrow-rejected.png`, `s121-options-restore-cancel-touch.png` | Y Restore text opens its dialog; covered arrow rejected; Cancel returns with settings unchanged. |
| `run-option-label-anchor-20261026.log` | Corrected runtime, native swipe and popup ownership evidence. |
| `s125-bows-category-touch.png` through `s131-material-hold-hint-touch.png` | Bow/shield/material categories, item popups, direct third-slot selection and X Hold opening holding mode. |
| `s142-direct-map-baseline.png`, `s143-map-right-held.png`, `s144-map-held-still.png`, `s145-map-right-released.png` | 10% horizontal drag: matching map displacement, no motion while held still or after release. |
| `s152-v2-map-baseline.png` through `s155-v2-map-return.png` | Clean vertical/reverse run: 10% downward displacement, stationary hold and return to original landmarks. |
| `ios-menu-presentation-20261026/details.log` | UIKit regression: zero failures, including no-target animation visibility and gameplay restoration. |
| `run-map-displacement-final-20261026.log`, `flash-final-acceptance.txt` | Final frontend state trace: L/R tab slides and item popup/cancel produced 12 visible answers, zero false answers; closing switches to hidden-menu state. |
| `s162-final-menu.png`, `s163-final-gameplay.png` | Final runtime returned from the tested menu flow to gameplay. GPU shots show the scene only; the host-overlay visibility evidence is the frontend trace and UIKit checks above. |
| `run-shared-menu-list-resume-20261026.log` | Owned test input plus native Options swipe record. Earlier unsolicited clicks were identified; the user stopped operating before s114. |

Focused checks passed after the current menu-visibility and map-drag changes:

```sh
make -C dm/host/tests GAME=01007EF00011E000 botw_touch_menu
clang -O1 -Wall -Werror -Wno-unused-function -Idm/host -Idm/host/gen/01007EF00011E000 -fsyntax-only dm/host/hle_botw_touch_menu.c
git diff --check
```

Coverage includes disabled categories, stale observations, canceled/replaced requests, page limits, inactive touch, native model acknowledgement, shared-list ownership, message-owner rejection, entering/shown/exiting presentation, retained children without their AppHome owner, and direct drag displacement under scaled/rotated transforms. Holding still does not reapply displacement; cancel rejects unconsumed movement. These checks do not establish physical-controller or iPhone behavior.

## Code and commits

- Implementation: `dm/host/hle_botw_touch_menu.c`, `dm/host/botw_touch_menu.h`.
- Focused checks: `dm/host/tests/t_botw_touch_menu.c`.
- Native build/signature validation: `dm/games/01007EF00011E000/patches.py`. Fixed addresses are gated by the BOTW 1.9.0 main build ID and function signatures.
- Already committed and pushed to `dev`: `64f1bff` (earlier menu fixes), `5f6f798` (merge upstream `4639c51`).
- The current checkpoint includes native list selection, quest categories/paging, Options adjustments/swipes, dialogue continuation, default-hidden gameplay controls, empty-album navigation, direct map dragging, the post-BLR rewrite fix and prepared Mac quick launch. See Git history for checkpoint commits.
- Zelda-on-PC informed the UI recognition approach. Native interfaces and addresses were independently checked against this project's Switch 1.9.0 build.

## Mac quick launch

`python3 scripts/run_mac.py --game /path/to/game-folder --quick --touch-preview --windowed`

The local BOTW build's `run/mac-runtime.json` is registered to the tested default-hidden-controls/empty-album/full-row-scroll runtime and its matching pre-merge graphics snapshot. Quick launch preserves `DM_SAVE`, checks the recorded files, and does not rebuild subsequent source changes. A successful Mac-only build records a new matched runtime automatically. See [Development](development.md) for the general launcher options.

## 2026-10-27 regression evidence

External evidence: `01007EF00011E000-work/inventory-touch-20261025/run14/`.

- `v3-title-controls.txt`, `v3-loading-controls.txt`, `v3-gameplay-controls.txt`: actual Mac frontend mode stays hidden at title/loading and shows controls only in gameplay.
- `v3-album-controls.txt`, `v3-album.png`, `v3-album-back.png`: the empty album has a live generic Back target without a focused item; tapping Back returns to gameplay.
- `v3-options-before.png`, `v3-options-down-list.png`, `v3-options-up-list.png`: full-row blank-padding swipes reveal Voice Language and return to the first rows.
- `inventory-sort-touch.png`, `inventory-food-category.png`, `inventory-food-popup.png`: native sorting result and food category/action popup.
- `unit-final.log`, `unit-horizontal.log`: focused native menu checks passed, including no-cursor guide publication, default-hidden gameplay ownership and horizontal gesture targeting.
- `ios-controls-default-hidden/details.log`: UIKit handler regression passed with zero failures. No physical iPhone gameplay validation.

Further inventory testing paused after input outside the test script moved the window from inventory into the map. Those later screenshots are not acceptance evidence for holding prompts.
