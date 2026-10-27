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
| Inventory category touch cells | Mac verified | Native 32x32 glyph targets expand to the surrounding category cells (58x58 in the tested layout), using live spacing and transforms. Neighbor cells do not overlap and the item-list clip bounds the lower edge. Off-icon upper/right Shield and lower/right Food taps passed through the Mac mouse path. |
| Inventory categories, Sort and Hold hints | Partial Mac regression | Bow/shield/material categories and popups passed. Food category and its Eat/Cancel popup now pass. Tapping Y Sort visibly reorders the weapon inventory and displays the native sorted message. X Hold opens holding mode. Inline Add changes the native count from 0/5 to 1/5; Stop holding returns the item. Inline Return-to-game closes inventory and restores gameplay controls. |
| System menu entries | Mac verified | Options opens directly; the load sequence also passed. |
| Map taps and stamp popup | Mac verified | Correct pointer position; both the B icon and Back text dismiss the stamp popup. |
| Map/Runes header hints | Mac verified | L/R hints use their final rendered positions. R opens the empty album; its Back text returns to gameplay without a cursor selection. AppHome prompts are published from live guide/header panes even when BoxCursor updates stop. |
| Startup and loading controls | Mac and UIKit verified | Gameplay controls start hidden and require a fresh, shown, input-enabled MainScreen HUD. Title and loading keep the Mac preview in menu routing; gameplay alone restores the artwork. Physical-controller and non-BOTW routing remain unchanged. |
| Map drag | Mac verified; iPhone pending | Replaced held-stick velocity with native position updates. Horizontal/vertical displacement follows the finger, holding still does not drift, release stops, reverse drag restores the map. Uses the inverse rendered transform for zoom/rotation. |
| Map pinch zoom | UIKit and Mac backend verified; physical iPhone pending | Two-finger spread/contraction and release reach the host. Zoom now crosses the native stick-direction threshold; the old 20% spread produced only 3200, below 16384. Injecting the same host ratios into the Mac runtime visibly zooms in and back out. Uses the game's native zoom levels. |
| Gameplay controls flashing during menu actions/slides | Mac state trace and UIKit checks passed; iPhone gameplay pending | Menu presentation is separate from clickable-target availability. L/R slides and item popup/cancel kept controls hidden: 12 frontend queries, zero false answers, including 6 with no clickable targets. Closing restored controls. Observe native screen lifecycle and root visibility each UI frame; retained map/rune children cannot outlive their AppHome owner. |
| Quest rows | Mac verified | Direct native list selection updates the matching details. |
| Quest categories | Mac verified | Main Quests and Memories switch directly; unavailable categories do not activate. |
| Quest/Memories vertical swipe | Mac verified | Native paging between rows 1-5 and 6-10; tapping row 8 then selects it directly. Paging occurs on release, without continuous finger-following animation. |
| Options arrows and ON/OFF | Mac verified | Right arrow: Normal to Fast; left: Fast to Normal; OFF/ON labels choose the corresponding value. |
| Options list swipe | Mac verified | Swipes use the complete native row bounds, including blank padding between text and values. An upward swipe reaches Voice Language; a downward swipe restores the first rows. Taps retain their narrower native targets. Scrolling occurs on release, without continuous finger-following animation. |
| Options horizontal value gestures | Mac verified | Right swipe changes camera sensitivity Normal to Fast; reverse swipe restores Normal, with one native adjustment each. Missing directions never become Confirm. |
| Dialogue continuation arrow | Mac verified | Beedle greeting, sale cancellation and receipts advance through the visible arrow. Hidden/covered arrows still fail closed. |
| Dialogue choices | Mac verified | Direct buy/sell/Good-bye, quantity confirmation and cancellation choices work with Beedle. Other NPC-specific layouts remain unverified. |
| Shops, buy/sell and quantity | Beedle Mac verified | Direct purchase rows use the shared native list setter with the independently validated shop receiver class. Numeric Message fields expose their live number and +/- controls even when the registered hit pane is offscreen. Quantity increment/decrement, All-of-them, cancellation, actual sale and two-item purchase passed. Other shop layouts remain unverified. |
| Album/photo operations | Deferred by user | Thumbnail selection, viewing, paging, delete confirmation and Back. |
| Ability Controls list and details | Mac verified | Direct final-row selection, native previous arrow, forward vertical swipe and Cancel back to the list. Cursorless pages resolve one live native owner and reject hidden, stale, ambiguous or input-disabled owners. |
| Save selection list swipe | Mac verified | Swiping upward reveals the bottom save, swiping downward restores the top. Shares native focus-and-scroll with Options; a swipe never confirms a load. Tapping after a swipe still opens the selected save's confirmation. |
| iPhone gameplay layout after menus/loading | UIKit verified; physical iPhone pending | Reapply child-layer visibility whenever menu mode changes. Restore the BOTW shield stick and hidden ZL/L3/R3, rather than merely showing the ordinary gamepad's parent layer. |
| System confirmations, save/load and DLC Back | Mac verified | Save Cancel, native Save into the disposable copy, Return to Title Cancel/Confirm and Continue from that new save passed. DLC opens and Back returns to System; the external eShop action was not invoked. Options Y Restore and Cancel passed; covered arrows cannot activate through its dialog. Rare dialog variants remain unverified. |
| Complete merged runtime and iPhone regression | Pending | Match upstream graphics caches; verify controller connection, menu exit, gesture cancellation and multitouch. |

## Next work

1. Check additional NPC/shop layouts and remaining dialog variants through the shared native menu path. Category touch cells, inline holding, help-page paging/Cancel and accessible System confirmations have passed.
2. Album/photo work remains deferred at the user's request. The user-provided `save-yizhan` slot was copied to external scratch; Beedle dialogue and shop flows passed, and all three original files retain their checksums after native Save/Load tests on the copy.
3. Validate the complete merged graphics runtime and physical iPhone/controller transitions. Current Mac evidence uses matching pre-merge graphics with the current touch implementation; it does not establish those remaining checks.

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

The local BOTW build's `run/mac-runtime.json` is registered to the tested category/holding/shop/help runtime plus fade-aware visibility, save-list swiping and corrected pinch zoom, with its matching pre-merge graphics snapshot. Quick launch preserves `DM_SAVE`, checks the recorded files, and does not rebuild subsequent source changes. A successful Mac-only build records a new matched runtime automatically. See [Development](development.md) for the general launcher options.

The Mac host was rebuilt after the touch-color change (background gray 0.18, perimeter gray 0.15, both alpha 0.40). The quick manifest now points to that rebuilt host, and the running Mac preview visibly shows the dark translucent controls (`run18/run-gray.log`). Editing source alone does not update a recorded quick runtime.

## 2026-10-27 regression evidence

External evidence: `01007EF00011E000-work/inventory-touch-20261025/run14/`.

- `v3-title-controls.txt`, `v3-loading-controls.txt`, `v3-gameplay-controls.txt`: actual Mac frontend mode stays hidden at title/loading and shows controls only in gameplay.
- `v3-album-controls.txt`, `v3-album.png`, `v3-album-back.png`: the empty album has a live generic Back target without a focused item; tapping Back returns to gameplay.
- `v3-options-before.png`, `v3-options-down-list.png`, `v3-options-up-list.png`: full-row blank-padding swipes reveal Voice Language and return to the first rows.
- `inventory-sort-touch.png`, `inventory-food-category.png`, `inventory-food-popup.png`: native sorting result and food category/action popup.
- `unit-final.log`, `unit-horizontal.log`: focused native menu checks passed, including no-cursor guide publication, default-hidden gameplay ownership and horizontal gesture targeting.
- `ios-controls-default-hidden/details.log`: UIKit handler regression passed with zero failures. No physical iPhone gameplay validation.

Further inventory testing paused after input outside the test script moved the window from inventory into the map. Those later screenshots are not acceptance evidence for holding prompts.


## NPC/shop regression (2026-10-27)

External evidence: `01007EF00011E000-work/inventory-touch-20261025/run15/`.

- `run-v3.log`, `quantity-sale-result.png`: quantity +/- changes exactly once; a one-apple sale changes 20 to 19 and rupees 5 to 8.
- `buy-widget-mapping-correct.txt`: all five purchase entries round-trip through the native list descriptor/index methods. The shop receiver vtable is build-ID gated and its four function signatures are checked by `patches.py`.
- `buy-direct-last-row.png`, `run-v4.log`: the last purchase row selects directly and shows its own native insufficient-funds response.
- `sale-all-confirm.png`: All-of-them selects all four amber for 120 rupees; cancellation leaves four amber and five rupees. A subsequent one-amber sale yields three amber and 35 rupees.
- `buy-completed.png`: direct fourth-row selection, quantity 1 to 2, confirmation and purchase leave one frog in stock, two in inventory and 15 rupees (35 minus 20).
- `options-swipe-right-fast.png`, `options-swipe-left-normal.png`: horizontal camera-sensitivity gestures change one step in each direction.
- `unit-hud.log`: focused native checks cover numeric controls, menu presentation during hidden dialogue layers, and an empty MainScreen root whose gameplay HUD is hidden.

A further shop-to-dialogue flash was reproduced in `run-v4.log`: frames 8008-8009 had no registered menu while MainScreen's empty root remained shown. MainScreen is now affirmative gameplay evidence only when its native heart-HUD InOut layer is shown too. The bounded direct-child lookup follows the real MainScreen hierarchy; no delay or prior-menu latch is used. `run-v5.log` reproduces that same two-frame registry gap at frames 3543-3544 with `gameplay=0`, so controls remain hidden. Conversation exit restored the native HUD at frame 5530 and controls after Message closed at frame 5537; the Mac preview visibly showed gameplay controls again. `hud-visibility-evidence.txt` contains the corresponding transitions. Pro HUD mode was also checked: gameplay touch controls still appear with the native minimap/loadout hidden. Physical iPhone behavior remains unverified.


The holding guide uses several numbered labels/glyphs under one `Pa_HaveNum_00`, with suffixes that do not identify pairs. The shared action-prompt cache now matches these by rendered row and reads the live glyph for A/X/B. Inline labels use their native left-aligned origin; hidden parent layers invalidate their cached targets immediately. `unit-final-holding.log` covers the reversed suffixes, button identities, label bounds and hidden-parent rejection. Mac `run-v6.log` records Add (0/5 to 1/5), Stop holding (the item returns), and inline B Return-to-game (inventory closes and gameplay controls return).


## Inventory category touch area (2026-10-27)

The user's small-target report was traced to the native 32x32 `B_Hit_00` glyph bounds. Touch now uses up to twice the glyph width/height, capped to the nearest category-center spacing and the owned item-list clip. The tested seven-category layout yields 58x58 cells, about 3.3 times the original area. The original pane identities and native category setter remain in use; quest categories, controller input and other games retain their existing handling.

`run-v7.log`, `category-cell-debug.txt`, `category-shield-blank-area.png` and `category-food-blank-area.png` record the expanded native rectangles and actual off-icon selection. The Shield tap was at screenshot (480,284), above/right of its glyph; the Food tap at (740,357), below/right. `unit-category-cells-final.log` covers separated neighboring targets, item-list clipping during actual view publication and leaving pointer-menu categories unchanged. Album/photo work is deferred by the user.

The final clipped-cell host also passed startup/loading and the off-icon Food tap in `run-v8.log`. These changes are included in the newer help/fade runtime registered for `run_mac.py --quick` below.


## Cursorless help pages (2026-10-27)

`ControllerWindow_00` clears its BoxCursor focus while an ability explanation is open, although the native screen and its B prompt remain active. Prompt-only publication now resolves a unique visible, input-enabled native screen from the registry; it shares the prompt cache/ownership checks already used by empty AppHome pages. The control's native screen, root and group are retained and checked again before emitting input. Controller mode returns before extra native calls. Hidden/ambiguous owners fail closed.

Visible drawable children of native `Pa_ArrowU_00` / `Pa_ArrowD_00` provide page actions. The live `Pa_PageTips_00` bounds provide the swipe region; a vertical swipe uses the same visible direction as tapping its arrow. A hidden next arrow never becomes an A confirmation.

External evidence: `01007EF00011E000-work/inventory-touch-20261025/run16/`.

- `help-owners.txt`, `help-before.png`: native screen/root ownership and the original unresponsive Cancel page.
- `help-arrow-side-hop.png`: tapping the previous arrow changes Perfect Guard to Side Hop.
- `help-swipe-perfect-guard.png`: an upward swipe returns to Perfect Guard.
- `help-cancel-return-list.png`: B Cancel text returns to the ability list with Perfect Guard selected.
- `unit-help-final.log`: cursorless ownership, arrow/swipe actions, unavailable direction rejection, hidden/input-disabled owners and duplicate-owner rejection. The final focused suite also passed the controller-off no-extra-call and Fade presentation checks.

## System confirmations and scene fades (2026-10-27)

In `run16/run-help-before-fade.log`, actual touch tests passed Save Cancel, native Save, Return to Title Cancel/Confirm, Continue and loading the newly saved slot. `save-verification.txt` and `save-before.json`/`save-after.json` establish that the disposable save changed while the original `save-yizhan` files retained their checksums. DLC Back also returned to System; the eShop button was not tested.

That flow exposed another controls-flash gap: PauseMenu and SystemWindow unregister before MainScreen hides its HUD on return to title. LLDB stopped at frame 30648 with gameplay still presented and a live, visible `Fade_00` in the native registry (`title-transition-before.txt`). Fade now blocks gameplay artwork through the existing presentation path, without supplying touch targets. No delay or prior-menu latch is used.

The rebuilt host passed the same return/load flow in `run-help-fade.log`: SystemWindow at frame 1942 handed presentation to Fade at 1945 while the HUD remained shown until 1957; Title took over at 2015. No gameplay-only gap remained. Subsequent loading stayed hidden until native gameplay returned at frame 4059. The matching host is registered for `run_mac.py --quick`; the quick launch manifest check passed.

## iPhone layout, pinch and save scrolling (2026-10-27)

External evidence: `01007EF00011E000-work/inventory-touch-20261025/run17/`.

- Menu/loading mode participates in the iOS custom-button visibility predicate. Initialization and controller refresh could configure the child layers while that mode was active; returning to gameplay previously showed only their parent. `refreshBotwTouchMenuMode` now reapplies the existing layout after changing mode. `ios-final/details.log` checks hidden ZL/L3/R3/D-pad and restored L3 double-tap after both menu and loading exits, alongside existing controller/non-BOTW checks. UIKit handler regression: zero failures.
- Pinch recognition already existed, but `(ratio - 1) * 16000` stayed below the native digital stick-direction threshold for ordinary spreads. A recognized spread/contraction now supplies a full native zoom direction; release and stale-sample clearing retain their existing ownership rules. UIKit checks now assert both scale directions and release. Native checks require output beyond `+/-0x4000`, rather than merely nonzero. `pinch-spread.txt` / `pinch-contract.txt` record calls to the public host pinch API in the real Mac runtime, producing `32767` / `-32767`; the observed map zoomed in and restored its wider extent. This verifies UIKit handling and the real game backend separately, not physical iPhone multitouch.
- Save-list rows are native `Pa_File_*` parts under `N_FileSelect_00/N_SlideArea_00`. The existing Options focus-and-scroll path now accepts that verified hierarchy too. In `run-final.log`, upward and reverse swipes select the bottom and top rows without A. The actual six-save list scrolls to reveal the old save and back; a subsequent tap opens the newest slot's load confirmation and Start reaches gameplay. Focused checks cover both directions, no load confirmation from a swipe, and rejection of a similarly named part outside the list.

No IPA was packaged or installed for this change. Rebuild the IPA before physical iPhone acceptance.
