# BOTW menu touch progress

Updated: 2026-10-29 (Asia/Shanghai).

This is the active progress tracker. Update it after each verified feature or new failure. `HANDOFF.md` is historical context, not the current status.

## Scope and acceptance rules

- Menu touch changes are BOTW touch mode only. Physical controllers and other games retain their existing input behavior.
- BOTW widescreen backgrounds are a separate rendering feature for both touch and controller modes. Foreground content and touch targets stay centered at 16:9; other games retain their existing rendering.
- Complete menu touch interaction; preserve the existing movement, combat and rune controls.
- Use the game's live controls, geometry, list state and native selection entry points. A distant item must select directly, without walking through intermediate items with direction inputs.
- Both the icon and text of a button hint should respond. Movement and zoom hints map to gestures.
- Only the current input-owning menu may respond. Hidden, covered, stale or ambiguous targets must not respond.
- Keep implementation checks, Mac runtime evidence and iPhone validation separate.

## Coverage

Mac milestones refer to their recorded runtime evidence. The latest 2026-10-28 runtime uses the retained `371ad45` graphics base with current menu/background changes and matching chain `07b0ea547435`; the newly merged host compiles, but its complete shader chain remains unvalidated. Physical iPhone and controller-connection acceptance remain separate from the Mac and UIKit checks.

| Surface | Status | Evidence or remaining work |
| --- | --- | --- |
| Widescreen UI backgrounds | Mac touch-preview and ordinary input layouts verified; physical iPhone/controller connection pending | Inventory/system background bars and the map background fill widescreen displays. Touch preview passed at 21:10; ordinary mode passed at 21:10 and a resized 16:7 window, with the original gameplay HUD. Menu content keeps its original proportions and direct touch positions; offscreen panels retain their foreground crop. See the game's Rendering note for the build/runtime boundary. |
| Title, Continue and load confirmation | Mac verified | Touch can enter gameplay without a fallback confirmation key. |
| Title widescreen background | Mac correction verified; physical iPhone pending | The right-anchored menu gradient now reaches the display edge without a light vertical strip, while logo/menu placement stays centered. Visible title artwork and its light/blur layers use the same proportional cover transform, while their capture sources stay native. UI projection snapshots refresh per draw so artwork and opacity remain current. Arrow and horse title artwork passed at 21:10; Continue/load flow, inventory and map were checked again. The prepared runtime uses an isolated RomFS directory so a concurrent image-based build cannot remove its resources. `widescreen-title-20261029/` records the regression and correction. |
| Inventory direct item selection | Mac verified | Distant slots update native selection and item details directly. |
| Inventory action popup and cancellation | Mac verified | Uses the active popup's native targets and confirm/back actions. |
| Full-health food confirmation | Mac verified; physical iPhone pending | `PauseMenuMantan_00` now uses the shared native PauseMenu-family target path. One tap on Cancel dismisses the warning without consuming food; one tap on Eat confirms from the default Cancel selection and consumes exactly one item. Evidence: `full-health-touch-20261029/`. |
| Inventory category touch cells | Mac verified | Native 32x32 glyph targets expand to the surrounding category cells (58x58 in the tested layout), using live spacing and transforms. Neighbor cells do not overlap and the item-list clip bounds the lower edge. Off-icon upper/right Shield and lower/right Food taps passed through the Mac mouse path. |
| Inventory categories, Sort and Hold hints | Mac verified | All available categories, including armor, food and key items, select directly. Equip, Eat, item details and popup cancellation passed. Y Sort visibly reorders weapons; X Hold, inline Add (0/5 to 1/5), Stop holding and Return-to-game passed. |
| Inventory category carousel, model rotation and recipe Close | Mac verified | Both visible carousel arrows switch categories. Dragging the native Rotate region turns the preview model and release stops rotation. The recipe's Close label returns to the item list. |
| System menu entries | Mac verified | Options opens directly; the load sequence also passed. |
| Map taps and stamp popup | Mac verified | Correct pointer position; both the B icon and Back text dismiss the stamp popup. |
| Map/Runes header hints | Mac verified | L/R hints use their final rendered positions. R opens the empty album; its Back text returns to gameplay without a cursor selection. AppHome prompts are published from live guide/header panes even when BoxCursor updates stop. |
| Startup and loading controls | Mac and UIKit verified | Gameplay controls start hidden and require a fresh, shown, input-enabled MainScreen HUD. Title and loading keep the Mac preview in menu routing; gameplay alone restores the artwork. Physical-controller and non-BOTW routing remain unchanged. |
| Non-modal gameplay tips | Code corrected; user acceptance pending | The shared screen classification excludes `MessageTipsRunTime_00` and `MessageTipsPauseMenu_00` from modal visibility and touch-menu routing. Headshot/shield-surf corner notifications should keep the gamepad visible; centered tutorials still hide it. The user will verify these events in-game. |
| First start with a completely empty save | Mac verified | The constructor observation retains the native cursor manager before its registry exists. Link waking up restores controls without visiting Title or opening a menu. See the [game note](../dm/games/01007EF00011E000/README.md#what-it-needs) for the cause. |
| Map drag | Mac verified; iPhone pending | Replaced held-stick velocity with native position updates. Horizontal/vertical displacement follows the finger, holding still does not drift, release stops, reverse drag restores the map. Uses the inverse rendered transform for zoom/rotation. |
| Map pinch zoom | UIKit and Mac backend verified; physical iPhone pending | Two-finger spread/contraction and release reach the host. Zoom now crosses the native stick-direction threshold; the old 20% spread produced only 3200, below 16384. Injecting the same host ratios into the Mac runtime visibly zooms in and back out. Uses the game's native zoom levels. |
| Gameplay controls flashing during menu actions/slides | Mac state trace and UIKit checks passed; iPhone gameplay pending | Menu presentation is separate from clickable-target availability. L/R slides and item popup/cancel kept controls hidden: 12 frontend queries, zero false answers, including 6 with no clickable targets. Closing restored controls. Observe native screen lifecycle and root visibility each UI frame; retained map/rune children cannot outlive their AppHome owner. |
| Quest rows | Mac verified | Direct native list selection updates the matching details. |
| Quest categories | Mac verified | Main Quests and Memories switch directly; unavailable categories do not activate. |
| Quest/Memories vertical swipe | Mac verified | Native paging between rows 1-5 and 6-10; tapping row 8 then selects it directly. Paging occurs on release, without continuous finger-following animation. |
| Options arrows and ON/OFF | Mac verified | Right arrow: Normal to Fast; left: Fast to Normal; OFF/ON labels choose the corresponding value. |
| Options list swipe | Mac verified | Swipes use the complete native row bounds, including blank padding between text and values. An upward swipe reaches Voice Language; a downward swipe restores the first rows. Taps retain their narrower native targets. Scrolling occurs on release, without continuous finger-following animation. |
| Options horizontal value gestures | Mac verified | Right swipe changes camera sensitivity Normal to Fast; reverse swipe restores Normal, with one native adjustment each. Missing directions never become Confirm. |
| Whole dialogue window and continuation arrow | Mac verified | Beedle greeting advances from blank left padding, and the farewell advances from its text. With choices visible, a background tap does not confirm; direct Good-bye still works. Native background bounds also remain available while text types. Hidden/covered windows fail closed. |
| Dialogue over a full-screen map | Mac verified; physical iPhone pending | Impa's map explanation left Message and AppMap in the same native input group; later map callbacks replaced the dialogue touch target. All unfocused publication paths now prefer an eligible dialogue over its background map. From a disposable copy of `Before-impa-dialogue`, one blank-padding tap closed the map and continued the next dialogue. `inventory-touch-20261025/run35-impa/` records before/after captures, the failing/passing regression and save-integrity checks. |
| Borderless goddess dialogue | Mac verified; physical iPhone pending | `MessageSp_00` renders its text under `N_VoiceA_00` without a normal dialogue window. The visible speech plate now shares the continuation path; private capture sources and focused choices stay excluded. A copy of `Goddess-dialogue` verifies text-body advancement, Heart Container/Yes choices, reward-card text and farewell, returning to five-heart gameplay. `run36-goddess-buttons/` holds captures and logs. Controls briefly appearing between reward prompts remain a separate visibility issue. |
| First-acquisition item cards | User Mac verified | The supplied shrine/chest save reproduces Eightfold Blade acquisition. Clicking the card body now continues through the native A handler; the numbered continuation arrow is covered by the same path and native regression checks. Original save files are preserved. |
| Shrine Skip and action tutorial body | Mac verified | Skip text emits native X during the entry cutscene. Blank padding in the action-tutorial window emits native A; nested controller illustrations do not enlarge its target. Both use native owner and visibility checks. |
| Shop Sell categories | Beedle Mac verified | Native category bindings select Cooking, Armor and Materials directly, including the two-page Materials configuration. Disabled weapon tabs remain inert; no sale was made in this regression check. |
| Movement-stick L3 double-tap timing | Shared geometry and UIKit verified; physical iPhone pending | Maximum release-to-next-down gap is 200 ms. Moving outside the configured deadzone cancels the tap sequence, including a drag back to its origin; holds, cancellation and release-only movement do not seed L3. Two fresh taps still work. `run36-goddess-buttons/ios/` verifies 190/210/350 ms gaps and movement-then-tap cases. Camera double taps and ordinary gamepad handling stay unchanged. |
| Action-button icons and D-pad ownership | Mac artwork and UIKit verified; physical iPhone pending | A/B/X/Y/R/ZR use the supplied six icons at half diameter and round backgrounds. Fill gray is 30% at 20% opacity; exterior ring gray is 47% at 40% opacity. Only D-pad touches retain their initial direction until release; ABXY sliding remains available. `run36-goddess-buttons/ios/` records zero failures and rendered artwork; 22 Mac packaging tests pass. |
| Action badges and thinner menu cross | UIKit verified; Mac compiled; physical iPhone pending | All six action buttons carry Y-style upper-right gray/gold badges with A/B/X/Y/R/ZR labels. Their outer halves remain clickable without locking face-button sliding. Plus/Minus cross thickness is 11% of the button diameter. `run37-badges/ios/` verifies rendering, hit routing, exact cross thickness and controller/ordinary-mode isolation with zero failures. |
| Pre-game touch settings and layout | Native/UIKit and Mac editor verified; physical iPhone gesture feel pending | Separate Touch settings page in iOS and packaged Mac launchers. Preview drag/pinch and sliders move/scale XYAB together (with separate spacing), D-pad equipment together, and movement/ZL/L/R/ZR separately; +/- stay fixed. Defaults are 7% deadzone, 0.30 curve, 70% full travel and 80% movement-stick size. Play saves choices; per-control and all-touch restore preserve unrelated settings. Shared geometry drives preview, drawing and input. Evidence: `touch-settings-20261029/` records live Mac preview drag, spacing/scale, save/reopen/restore; zero UIKit failures in 31 sessions; storage, geometry/HUD and packaging checks. The merged host builds; full game regression stops at the existing translator/lock mismatch before boot. |
| Three-finger menu backup | UIKit configuration and input handling verified; physical gesture pending | Double-tap with three fingers while automatic controls are hidden to reveal the original full virtual pad for one menu visit. Menu pointers are cancelled; buttons and UI right stick bypass direct-menu hit tests. Leaving menus, controller connection or input reset clears the override. It is not saved. Ordinary combat chords remain intact; an unavailable HUD adapter does not block the escape. `inventory-touch-20261025/run34/ios-fallback/` records the focused checks. |
| Terminal and special dialogue bodies | Tower Mac verified; shared native tests pass | Identify rendered text-output roles and their sibling windows across native Message screens, independent of event/container names or instance suffixes. The supplied tower save verifies body and blank-padding taps across activation, scanning and map extraction, followed by gameplay. Existing choice/quantity ownership and hidden/stale/private-capture rejection remain covered. Uses the current menu adapter on the compatible pre-merge graphics host; merged host compilation passes, full merged graphics/iPhone acceptance remains pending. Evidence: `tower-dialogue-20261028/`. |
| Dialogue choices | Mac verified | Direct buy/sell/Good-bye, quantity confirmation and cancellation choices work with Beedle. Domidak/Prissen's two-option conversation also selects its requested branch directly and advances across speaker changes. Other conditional NPC layouts remain unverified. |
| Shops, buy/sell and quantity | Beedle Mac verified | Direct purchase rows use the shared native list setter with the independently validated shop receiver class. Numeric Message fields expose their live number and +/- controls even when the registered hit pane is offscreen. Quantity increment/decrement, All-of-them, cancellation, actual sale and two-item purchase passed. A chosen count is confirmed through the blank area of its number-selection button, outside the number field and arrows; the dialogue body does not accept it, and each arrow responds over a finger-sized strip outwards from the box rather than over the native pad-cursor part alone. Sell-grid left/right paging and page-arrow touch also passed; quantity dialogs block background paging. Other shop layouts remain unverified. |
| Album/photo operations | Deferred by user | Thumbnail selection, viewing, paging, delete confirmation and Back. |
| Ability Controls list and details | Mac verified | Direct final-row selection, native previous arrow, forward vertical swipe and Cancel back to the list. Cursorless pages resolve one live native owner and reject hidden, stale, ambiguous or input-disabled owners. |
| Save selection list swipe | Mac verified | Swiping upward reveals the bottom save, swiping downward restores the top. Shares native focus-and-scroll with Options; a swipe never confirms a load. Tapping after a swipe still opens the selected save's confirmation. |
| iPhone gameplay layout after menus/loading | UIKit verified; physical iPhone pending | Reapply child-layer visibility whenever menu mode changes. Restore the BOTW shield stick and hidden ZL/L3/R3, rather than merely showing the ordinary gamepad's parent layer. |
| System confirmations, save/load and DLC Back | Mac verified | Save Cancel, native Save into the disposable copy, Return to Title Cancel/Confirm and Continue from that new save passed. DLC opens and Back returns to System; the external eShop action was not invoked. Options Y Restore and Cancel passed; covered arrows cannot activate through its dialog. Rare dialog variants remain unverified. |
| Game Over and retry | Mac verified | On the disposable save, native bomb damage reaches Game Over. Direct Quit opens its confirmation, Cancel returns to the retry list, and Continue reloads gameplay. Controls stay hidden through defeat/loading and return with the gameplay HUD. |
| Complete merged Mac graphics runtime | Mac verified | Correct-package shaders restore the title, loading, menus and gameplay. The wrong-package build is rejected before translation; see the shader reference linked below. |
| Physical iPhone/controller transitions | Pending hardware acceptance | UIKit checks cover mode transitions, gesture cancellation and pinch in both directions. No physical iPhone or connected-controller gameplay test was performed. |

## Next work

1. Album/photo work remains deferred at the user's request. Horse registration/naming and specialized vendors need their corresponding game state; these conditional layouts are not claimed as runtime verified.
2. Physical iPhone/controller transitions require hardware acceptance. The user-provided `save-yizhan` slot is copied to external scratch for tests; the original is preserved.

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

The local BOTW build's `run/mac-runtime.json` now points to `dmhost-botw-new-item-touch-07b0ea547435`, the complete merged host with whole-dialogue/item-card touch, shop-grid paging and the current button artwork, plus its matching rebuilt 1.9.0 shaders and modules. Normal pipeline preparation and the recorded quick-runtime checks passed. Quick launch preserves `DM_SAVE`, checks the recorded files, and does not rebuild subsequent source changes. A successful Mac-only build records a new matched runtime automatically. See [Development](development.md) for the general launcher options.

The run18 checkpoint rebuilt the Mac host after the earlier touch-color change (background gray 0.18, perimeter gray 0.15, both alpha 0.40); its preview evidence is `run18/run-gray.log`. Later palette and artwork revisions are recorded below. Editing source alone does not update a recorded quick runtime.

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

## Remaining reachable menus and matched Mac runtime (2026-10-27)

External evidence: `01007EF00011E000-work/inventory-touch-20261025/run19/` and `run20/`.

- Run19 closes the inventory regression: every available category, Equip/Eat/details, both category carousel arrows, model rotation by dragging, and the recipe Close prompt passed. `run-complete.log`, `preview-rotated.png`, `recipe-prompts.txt` and `rotate-geometry.txt` retain the observations. Rotation stops on release and uses only the native preview's live Rotate guide.
- Run19 map checks cover the complete Sheikah Sensor text target, OFF/Shrine choices, creating/selecting/deleting a stamp, rune slots, shrine Travel/Cancel and Cancel. Long footer text is bounded by neighboring glyph edges. Map taps follow the native model point after recentering; live map ownership survives cursorless header/prompt updates. `unit-map-final.log` passed; `ios-final/details.log` reports zero failures in 27 look sessions.
- Run20 found and resolved the black Mac title/scene: [Shader package records match profile keys](reference/shaders.md#shader-package-records-match-profile-keys). The full correct-package build produced 19,592 successful shaders for chain `07b0ea547435`, plus matching `c1_full.tsv` and `cb_extent.tsv`. Normal startup prepared all 15,767 pipeline pairs without failure. `shader-guard-complete-arm64.log`, `wrong-package-rejected.txt`, `final-startup-prebuild.log` and `final-runtime.log` retain the build and gameplay evidence.
- Dialogue taps use the rendered `W_Base_00` / `W_SysBase_00` background under the live Message owner, together with its optional continuation arrow. Text reveal still goes through the native A handler. A focused choice blocks continuation, and late background observations cannot clear the choice's targets. `unit-dialogue-choice-final.log` passes hidden-parent, stale-owner, outside-window, controller-off and choice-publication checks.
- Actual Beedle tests tapped blank left padding to reach the choices, tapped the background without confirming a choice, selected Good-bye directly, then tapped the farewell text to return to gameplay. `dialogue-whole-before.png`, `dialogue-background-advanced-choices.png` and `dialogue-text-exit-gameplay.png` record this. Domidak/Prissen's conversation also passed continuation across speakers and direct branch selection. Tasseren's stable introduction, service choices and no-horse registration response passed whole-window touch; `stable-no-horse.png` establishes why the registration detail/naming pages remain unavailable.
- `gameover-before.png`, `gameover-quit-confirm.png` and `gameover-continue-gameplay.png` record Quit, its Cancel and Continue/reload on the disposable save. Native GameOver/Fade ownership hides controls until the gameplay HUD returns.
- All game runs use external disposable saves. The last source-save checksum verification remains `run16/save-verification.txt`; the original `~/Desktop/save-yizhan` path is no longer present at final review, so it was not rechecked or modified.

## BOTW button artwork override (2026-10-27)

The ordinary pad colors and shadows stay unchanged. The existing active BOTW touch predicate selects the override; menu/loading and physical-controller modes hide the artwork. Buttons use gray 0.26 at alpha 0.20, outlines use gray 0.25 at alpha 0.40 with 20% thicker strokes, and their shadows are disabled. The user-supplied transparent sword PNG occupies 50% of Y's diameter. A gray 0.20 circle with a light-gold outline carries the Y label, centered on the main circle's upper-right edge so it overlaps the button by about half. Its touch still belongs to Y.

`run21/ios-style/details.log` reports zero failures, including exact colors, image loading/size, badge hit routing and restoration of ordinary defaults in controller and non-BOTW modes. `botw-buttons.png` is the rendered UIKit preview. Mac and iOS packaging include the optional profile artwork; Mac touch preview uses the same color constants and PNG. No physical iPhone build was installed.

The subsequent color revision and ZL artwork are checked in `run23/ios-shield/`: zero failures in the UIKit harness, including a fixed touch-down center, a direction arrow on the ring perimeter, preserved shield/movement input and return to idle on release. Its PNGs show the current colors and idle/drag appearance; run21 records the earlier palette. See the [game note](../dm/games/01007EF00011E000/README.md#what-it-needs) for the ZL artwork source and behavior.

The movement-stick, threshold-feedback, circular +/- spacing and L badge revision is recorded in the same [game note](../dm/games/01007EF00011E000/README.md#what-it-needs). `run24/ios-final/` has zero failures in 31 look sessions, with `botw-buttons.png` and `botw-left-drag.png` for idle/drag rendering. `run24/geometry.log` and `hud.log` pass the shared layout and native map/environment alignment checks. `mac-left-stick.log` belongs to the updated gameplay window; Plus opens inventory and Back restores the new artwork. Physical iPhone haptic feel remains pending. The verified host is registered for `run_mac.py --quick`.

The exterior-only button-border revision is documented in the [game note](../dm/games/01007EF00011E000/README.md#what-it-needs). `run25/ios-border/` records zero failures in 31 look sessions and its rendered `botw-buttons.png`; `run25/mac-borders.log` belongs to the matching Mac preview.

The subsequent plain +/- and direction-cursor revision is checked in `run26/ios-style/`: zero failures in 31 look sessions, including controller/non-BOTW restoration. Plus and Minus retain their hit areas but draw only white glyphs. Movement and ZL direction arrows meet the outside edge of the ring. The historical movement sprint stacked two outward-facing arrows; `botw-left-drag.png` records that appearance. The sprint gesture and its feedback were removed in the later movement-response revision below.

The same run closes the Sell-grid horizontal-paging regression; see the [game note](../dm/games/01007EF00011E000/README.md#what-it-needs) for the cause and fix. `sell-swipe-next.png`, `sell-swipe-previous.png`, `sell-quantity-blocks-paging.png` and `sell-paging-evidence.txt` record actual Mac pointer checks. `menu-unit.log` passes direction/release, live geometry, hidden/stale/other-owner rejection and quantity-modal checks. `mac-final.log` is the current preview, and `quick-check.log` checks its registered launch manifest.

## First-acquisition item prompt (2026-10-27)

External evidence: `01007EF00011E000-work/inventory-touch-20261025/run27/`.
See the [game note](../dm/games/01007EF00011E000/README.md#what-it-needs) for the layout mismatch and shared continuation fix. `new-item-click-blocked.png`, `new-item-before.txt` and `new-item-pane-tree.txt` record the reproduction. The user walked to the chest and verified the rebuilt runtime; `mac-body.log` and `new-item-runtime-evidence.txt` record the card-body tap, native A and return to gameplay. `menu-unit.log` passes the added card/arrow and ownership checks alongside previous menu regressions. `source-save-verification.txt` confirms the three supplied save files are unchanged. No physical iPhone build was installed.

The subsequent BOTW movement/ZL size and deadzone adjustment is recorded in the
[game note](../dm/games/01007EF00011E000/README.md#what-it-needs).
`run28/geometry.log` and `build.log` pass; `run28/ios-final/details.log` reports
zero failures in 31 look sessions, including both sticks at 390/540-point
viewport heights and unchanged controller/other-game defaults. The updated
host is registered for Mac quick launch; the existing game process retains
its previous executable until restarted. Physical iPhone feel remains untested.

## Shrine prompts, Sell categories and L3 timing (2026-10-27)

External evidence: `01007EF00011E000-work/inventory-touch-20261025/run29/`.
See the [game note](../dm/games/01007EF00011E000/README.md#what-it-needs) for the
native layouts, category bindings and Skip input ownership. `mac-shrine-fixed.log`,
`tutorial-touch-evidence.txt` and `tutorial-body-before.png` / `tutorial-body-after.png`
record the blank tutorial-body tap and native A. `mac-shop-fixed.log`,
`sell-category-evidence.txt` and the `sell-*-touch.png` images record direct
Cooking/Armor/Materials changes; `sell-disabled-category.png` records rejection.

`mac-entry-ready.log`, `shrine-skip-evidence.txt` and `shrine-skip-after.png`
record the real Mac pointer tap at `(0.911, 0.941)`, native X at frame 3145,
Fade ownership during exit and gameplay restoration at frame 3201. Merely
reaching loading was not counted as Skip acceptance. `menu-final.log` passes
the menu regressions, including a prompt becoming shown without another
matrix calculation, disabled ordinary input groups and closing-owner rejection.
`ios/details.log` reports zero failures in 31 look sessions, including L3
timing and existing controller/non-BOTW routing. `build-final-accepted.log`
records the final Mac build. `source-save-verification.txt` confirms all six
files in the two original slot-zero saves are unchanged. The verified host is
registered for Mac quick launch; physical iPhone feel remains untested.

## Fixed Plus anchor and shrine Minus (2026-10-27)

Plus now has one position beside the minimap whether or not the minimap is
visible. Its 39-unit circle sits 4 frontend points below the minimap clip top,
with a 40%-opaque black fill and a centered white 19-unit cross. Cross thickness
scales with the circle diameter at 12%. Native HUD relocation and both
frontends share the anchor constants. Minus appears below Plus with an 8-point
gap when the map is absent; ordinary gamepads keep their existing layout.

See the [game note](../dm/games/01007EF00011E000/README.md#what-it-needs) for
the shrine visibility cause. Alpha-zero map ancestors invalidate map hit
ownership while preserving the environment HUD's existing placement. Completing
a Slate interaction clears its consumed-tap guard when gameplay resumes.
External evidence is in `inventory-touch-20261025/run30/`: `hud.log` covers the
alpha-only hide and unchanged environment alignment; `geometry.log` covers
size, top alignment and stacked spacing. `ios-final/details.log` reports zero
failures in 31 look sessions, including fixed-position map transitions,
shrines, and controller/non-BOTW restoration. `mac-shrine-hud.log` records the
Mac cold shrine start, Minus opening the map, travel to the overworld, and Plus
opening inventory. `shrine-final.png` shows the final build in the shrine.
`mac-shrine-check.log` confirms the final build's cold shrine start, Minus
opening the map and Back restoring both buttons in their fixed positions.
The matching host is registered for quick launch. Physical iPhone acceptance
remains separate.

## Quantity button surfaces (2026-10-28)

External evidence: `01007EF00011E000-work/inventory-touch-20261025/run31/`
and `run32/`.

The initial dialogue-body confirmation interpretation was incorrect and has
been removed. Quantity acceptance belongs to the number-selection button's
blank area, outside its number field and arrows. The number field only
focuses; arrows adjust once without accepting. Dialogue-body taps do not
accept the count.

The native Message buttons keep their registered `B_Hit_00` cursor anchors
offscreen. Falling back to text geometry left only the number or label
clickable and omitted the visible button's padding. The shared native target
builder now uses the same part's live `W_Base_04` or `W_Decide_00` button
window before falling back to text. It retains the registered owner and entry,
so both quantity acceptance and OK/Cancel follow native focus and validation.
Hidden/transparent windows and other parts are excluded. Arrow geometry stays
relative to the number field instead of the wider confirmation button.

`run32/menu-unit.log` covers first-boot initialization before the registry
exists, restoration through a pane callback without a cursor update, button
blank-area acceptance, inert dialogue/number-field taps, hidden/transparent
button rejection and ordinary choice-button padding. `run32/rewrite.log`
records a coherent main/subsdk0/sdk rewrite and successful freshness check.
Physical iPhone validation remains separate from these checks.

The earlier 16:9 baseline captures (`sell-two-completed.png`,
`buy-all-cancelled.png`, `buy-all-completed.png`) record an actual sale and
both buy-all choice branches before the button-surface correction. They do
not establish the corrected quantity gesture.

Corrected 21:10 Mac acceptance (`mac-shop-fixed.log`):

- `quantity-body-number-inert.png` and `button-touch-evidence.txt`: the value
  changes to two with one right-arrow tap; dialogue and number-field taps emit
  no A. Tapping the quantity button's blank right side emits A for its own
  registered entry.
- `sell-button-confirm.png`: that button accepts two Amber for 60 rupees;
  tapping OK's blank right side completes the sale (balance 5 to 65).
- `buy-button-confirm.png`: the same button accepts two frogs for 20 rupees;
  cancellation returns to the unchanged stock of three and balance 65.
- `buy-all-wide-confirm.png` and `buy-all-wide-cancelled.png`: All of them
  opens the three-frog confirmation; tapping Cancel's blank left padding
  returns without a purchase.
- `buy-all-wide-completed.png`: repeating All of them and tapping OK's blank
  right side completes the purchase (sold out, inventory three, balance 35).

`quick-check.log` validates the final registered host and rewritten modules;
`executable-check.txt` matches the prepared host to the running preview.
`source-save-check.txt` confirms the six original save files are unchanged.

## Movement response and sprint removal (2026-10-28)

The stronger short-drag response and removal of overshoot sprint are recorded
in the [game note](../dm/games/01007EF00011E000/README.md#what-it-needs).
`inventory-touch-20261025/run33/native-input.log` covers direction, neutral/full
endpoints, ordinary B preservation and R/ZR cancellation. `ios-input/` reports
zero failures in 31 look sessions, including short/tall layouts, linear ZL,
controller/non-BOTW restoration, one direction arrow and no overshoot haptics.
`rewrite.log` and `look-cfg.log` validate the refreshed modules and retained
camera observations. `mac-shop-response.log` records the updated Mac preview
reaching gameplay; `quick-check.log` validates the prepared launch runtime.
