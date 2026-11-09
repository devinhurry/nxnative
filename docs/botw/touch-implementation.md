# BOTW touch implementation checklist

Generated from [the editable inventory](../../dm/games/01007EF00011E000/touch_ui_inventory.json) by `python3 dm/tools/botw_touch_progress.py`. Change the inventory and regenerate this page.

This is the implementation record for BOTW touch menus. It covers the supplied base/update and both DLC resource sets. Controller input, other games and existing combat controls stay outside this task. A registered screen or recognized name alone does not count as an implemented action.

339 layouts classified: 89 top-level layouts and 250 reusable components. Rows below group actions that share an implementation; layout counts are not action counts.

| Implementation | Count |
| --- | ---: |
| implemented | 48 |
| partial | 0 |
| missing | 0 |
| not required | 6 |

| Verification of required action groups | Count |
| --- | ---: |
| passed | 32 |
| failed | 0 |
| not run | 14 |
| blocked | 2 |

Passed results include 28 game-state checks and 4 handler tests. A handler test checks synthetic native owners or frontend gesture delivery; it does not prove that story/vendor/DLC state was reached in the game.

Implementation and verification are independent. `blocked` means a save, story/DLC state or hardware is unavailable; it never excuses a missing implementation. `passed` uses the evidence named in that row and does not imply every conditional variant or physical iPhone was tested. Runtime observations and per-target replay assertions are tracked separately in [UI coverage](ui-coverage.md) and [acceptance progress](touch-progress.md).

## Required actions

| ID / screen and state | Action | Implementation | Verification / evidence level |
| --- | --- | --- | --- |
| `core.native_target.dispatch` — all native menu screens; visible + input-owning | Tap a visible native hit target and dispatch through its owner | implemented | passed / game state |
| `core.focus.direct` — list/grid screens; target visible or list-scrollable | Select a distant row/cell directly | implemented | passed / game state |
| `core.swipe.page` — list/grid screens; gesture active | Swipe to scroll/page and commit on release | implemented | passed / game state |
| `core.value.adjust` — options/numeric screens; value control shown | Tap value/arrow or swipe to adjust native value | implemented | passed / game state |
| `core.footer.action` — prompt/menu screens; footer shown | Tap rendered button icon or label for confirm/back/page | implemented | passed / game state |
| `core.dialogue.body` — Message screens; body/no-choice state | Tap body/arrow to reveal or advance dialogue | implemented | passed / game state |
| `core.dialogue.choices` — Message/Shop screens; choice list visible | Tap exact choice; background/body tap must not confirm | implemented | not_run / none |
| `core.dialogue.quantity` — Message screens; quantity dialog shown | Focus number field; increment/decrement; confirm/cancel | implemented | passed / game state |
| `core.back` — menu/dialogue screens; native back action available | Invoke current native B/back action | implemented | passed / game state |
| `inventory.category` — PauseMenu inventory; inventory tab active | Select categories directly with immediate page positioning and cursor focus | implemented | passed / game state |
| `inventory.actions` — PauseMenu inventory; item selected | Equip/eat/hold/drop/add/stop holding; open/cancel popup | implemented | passed / game state |
| `inventory.sort_rotate_recipe` — PauseMenu inventory; subview active | Sort, rotate preview, close recipe | implemented | passed / game state |
| `quest.rows_categories` — PauseMenu quests; quest page active | Select quest/category directly and update details | implemented | passed / game state |
| `map.pan_zoom` — AppMap; map active | Tap, drag, pinch zoom and release without drift | implemented | passed / game state |
| `map.stamp_warp_header` — AppMap; marker/stamp/warp/header state | Select marker, place/manage stamp, warp if enabled, activate header prompts | implemented | not_run / none |
| `applet.album` — AppAlbum; grid/photo viewer state | Select/paginate thumbnails, view photo, navigate/back, operate file controls | implemented | passed / game state |
| `applet.picture_book` — AppPictureBook; grid/detail state | Select categories immediately; select entries and navigate pages/details/back | implemented | not_run / none |
| `applet.tool` — AppTool; rune tool active | Operate available native controls and close to gameplay | implemented | not_run / none |
| `applet.camera` — AppCamera_00; Camera Rune shown in native viewfinder | See enumerated camera action requirements: shutter, back, self-portrait, album, framing/focus, zoom, and selfie poses. | implemented | passed / game state |
| `applet.dungeon` — AppMapDungeon; dungeon map active | Tap Divine Beast controls and menu prompts; select a position with the D-pad or by tapping its marker; drag to rotate the map. | implemented | passed / game state |
| `options.rows_values` — OptionWindow; options list active | Select, scroll, change arrows/labels and ON/OFF values | implemented | passed / game state |
| `title.load` — Title; title choices visible | Choose Continue/New Game and accept/cancel load flow | implemented | passed / game state |
| `system.ack` — SystemWindow variants; dialog shown | Choose a visible dialog option through its native hit/focus target; tap an authored confirm/back guide when present. | implemented | not_run / none |
| `system.dlc_amiibo` — DLCWindow/AmiiboWindow; modal shown | Select enabled choice and dismiss; disabled choices inert | implemented | not_run / none |
| `system.controller_pairing` — ChangeController_00/ChangeControllerNN_00; controller diagram/status prompt rendered while controller applet is requested | No touch action: host HID applet returns the connected-player selection immediately; pairing is performed by the operating system/physical controller. | not_required | not_required / not required |
| `system.save_transfer` — SaveTransferWindow; transfer prompt shown | Choose transfer/continue/cancel and acknowledge outcome | implemented | blocked / none |
| `system.keyboard_text` — KeyBoradTextArea; text entry active | Enter/delete/move caret/change layout/accept/cancel text | implemented | not_run / none |
| `horse.registry` — ShopHorse; stable/registration page shown | Select horse; register/capture; confirm/cancel | implemented | blocked / none |
| `horse.name_entry` — ShopHorse + KeyBoradTextArea; name editor active | Enter/erase name; change character page; accept/cancel back to registration | implemented | not_run / none |
| `horse.hud` — MainHorse; horse HUD active | Respect native owner prompts and retain gameplay button routing | not_required | not_required / not required |
| `guide.shrine` — SousaGuide; prompt-only shrine action | Touch native confirm/back prompt, exclude ordinary gameplay hint | implemented | passed / game state |
| `notice.ack` — PickUpWin/ChallengeWin; corner notification shown | Retain gameplay controls; no modal acknowledgement | not_required | not_required / not required |
| `system.error_viewer` — ErrorViewer; error dialog shown | Dismiss/continue with native action | implemented | not_run / none |
| `ending.continue_skip` — StaffRollDLC_00; DLC credit roll with live B guide and page arrows | Tap native B prompt to skip; tap up/down page arrows to scroll credits. | implemented | passed / handler test |
| `intro.advance_mode` — HardMode_00; mode choice dialog with live PaCommonBtnThin_00 left/right registered hit targets | Tap either native option button to choose its corresponding game mode. | implemented | not_run / none |
| `gameover.choices` — GameOver; game-over choice visible | Choose retry/continue/title and confirm/cancel natively | implemented | not_run / none |
| `apphome.pages` — AppHome; Slate child/page active | Select pages/tabs/children, use header actions, close/back | implemented | not_run / none |
| `pause.home` — PauseMenu; pause menu visible | Select sections/options, load, return to gameplay | implemented | passed / game state |
| `message.variants` — Message variants; prompt/card/tutorial state active | Advance body; choose option; skip when shown; dismiss/back | implemented | not_run / none |
| `intro.passive_transitions` — GameTitle_00/DemoStart/OPtext_00/MainHardMode_00/LastComplete_00; logo/story/completion visual or transition state | No separate touch action: these layouts contain no button/control/hit/prompt surface; mode choice belongs to HardMode_00. | not_required | not_required / not required |
| `ending.passive_artwork` — End_00/StaffRoll_00/Thanks_00; base-game ending card, scrolling credit text, or thank-you card | No separate touch action: the layouts contain only end/credit text/artwork and no native button/control/hit/prompt surface. | not_required | not_required / not required |
| `camera.shutter` — AppCamera_00; AppCamera_00 viewfinder active; after shutter, native capture confirmation shows same-owner Delete and Save targets. | Tap the live A shutter guide. In the native capture confirmation, tap the Delete or Save target for the desired choice. | implemented | passed / game state |
| `camera.back` — AppCamera_00; viewfinder active | Tap the displayed B guide to leave the camera. | implemented | passed / game state |
| `camera.self_portrait` — AppCamera_00; viewfinder active | Tap the displayed X guide to switch camera/self-portrait mode. | implemented | passed / game state |
| `camera.album` — AppCamera_00; viewfinder active | Tap the live Minus glyph action to open the photo Album. | implemented | passed / game state |
| `camera.framing_focus` — AppCamera_00; viewfinder active | Drag with one finger to aim/reframe the camera by driving the native right stick. | implemented | passed / game state |
| `camera.zoom` — AppCamera_00; viewfinder active | Pinch to zoom through native D-pad Up/Down steps. | implemented | passed / handler test |
| `camera.selfie_pose` — AppCamera_00; self-portrait mode active | During AppCamera self-portrait mode, hold the pose modifier while translating the two-finger pose gesture: iOS uses a third finger, and Mac uses Shift during Option-drag or Option during Shift precise-scroll. This emits ZL with left-stick direction to choose additional poses. | implemented | passed / handler test |
| `camera.gamepad_menu_coexistence` — AppCamera_00; Camera viewfinder menu active with BOTW touch controls requested | Show and allow touch-gamepad controls while preserving touch access to the native AppCamera menu; keep each touch assigned to its chosen control or menu owner through end/cancel. | implemented | passed / game state |
| `cutscene.skip` — Skip_00; active cutscene with live X guide under Pa_Skip_00 | Tap the X guide to invoke native cutscene skip. | implemented | passed / handler test |
| `system.controller_manual` — ControllerWindow_00; controller help/manual page with list, arrows, and A/B guides visible | Select a manual topic; use the live Up/Down page arrows; tap A confirm or B back guide. | implemented | not_run / none |
| `system.ack.no_button_wait` — SystemWindowNoBtn_00, AppSystemWindowNoBtn_00; choice-less system message waiting for its native caller/service to close or advance it | No touch action is authored by these no-button layout resources. | not_required | not_required / not required |
| `scope.native_actions` — MainScreen_00 / R3 Scope; Scope guide bar visible beside gameplay controls | Tap Place pin, Quit and Edit pins native hints while preserving virtual controls and relative-look gestures | implemented | passed / game state |
| `item_get.inventory` — MessageGet_00; New-item card with visible Inventory Plus hint | Tap the native Plus glyph or its label to open Inventory; card body and arrow continue normally with A | implemented | passed / game state |

## Action evidence and remaining work

### core.native_target.dispatch

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets owned by current screen.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_publish_generic_view`: Publishes current native geometry and semantic targets.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_entry_eligible`: Rejects stale/inactive native entries.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_native_input_group`: Restricts input to current native input group.

**Verification (passed; game state):** Mac native direct-selection and stale-owner regressions are recorded in the active progress tracker.

### core.focus.direct

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets owned by current screen.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_native_list_select`: Selects through native list/setter entry point.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_focus_list_scroll`: Direct focus/select and native list scrolling.

**Verification (passed; game state):** Inventory, quest, shop, map and album direct-selection evidence is recorded.

### core.swipe.page

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_focus_list_scroll`: Direct focus/select and native list scrolling.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_grid_carousel_to_view`: Publishes grid/page/carousel targets.
- [dm/host/front_mac.m](../../dm/host/front_mac.m) `scrollWheel:`: Converts cumulative trackpad deltas and discrete wheel notches into phased touch gestures at native swipe threshold; cancelled gestures end as CANCEL.

**Verification (passed; game state):** Mac native list/swipe flows and the focused 12/12 trackpad contract checks are recorded; exact per-screen conditional states remain not_run.

- [dm/host/tests/t_botw_touch_trackpad.c](../../dm/host/tests/t_botw_touch_trackpad.c) `main`: Platform-owner report: 12/12 focused checks passed for cumulative path, zero-delta end, cancel, vertical/horizontal wheel thresholds, and BOTW/map/live-owner gating.

### core.value.adjust

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_value_adjusters_to_view`: Publishes native labels, arrows and numeric adjustments.

**Verification (passed; game state):** Options and quantity adjustment evidence is recorded.

### core.footer.action

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `generic_action_prompts_to_view`: Publishes currently visible action prompts.

**Verification (passed; game state):** Back/confirm prompt routes are recorded for map, options, dialogue and AppHome.

### core.dialogue.body

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_message_prompt_view`: Publishes visible dialogue body/continuation arrow.

**Verification (passed; game state):** Ordinary/special dialogue and item card paths are recorded.

### core.dialogue.choices

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets owned by current screen.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_native_list_select`: Selects through native list/setter entry point.

**Verification (not_run; none):** Shared native hit/focus/action path is present; the remaining conditional screen states have no independent end-to-end run evidence.

### core.dialogue.quantity

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_value_adjusters_to_view`: Publishes native labels, arrows and numeric adjustments.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets owned by current screen.

**Verification (passed; game state):** Beedle quantity flow is recorded.

### core.back

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `generic_action_prompts_to_view`: Publishes currently visible action prompts.

**Verification (passed; game state):** Map popup, inventory, dialogue and AppHome Back routes are recorded; the AppAlbum native Back action also returned to AppCamera in the Mac guest replay.

- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/suite-camera-album/replay.json` — Mac guest replay: native Album Back returns from AppAlbum_00 to AppCamera_00.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/before-wait-presentation-fix/final-suite-camera-navigation/replay.json` — Final Mac guest replay passes Album Back returning from AppAlbum_00 to AppCamera_00.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/suite-camera-album/replay.json` — Earlier Mac guest Album Back replay; preserved as historical evidence before the final blocking-presentation fix.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/final-suite-camera-navigation/replay.json` — Final six-step Mac guest replay passes AppAlbum Back→AppCamera.

### inventory.category

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_request_category`: Native category refresh runs before final commit; slot zero is staged after refresh so page and focus finish together.

**Verification (passed; game state):** Mac category tap from a nonzero weapon column immediately selects first Food item with matching description; native order/transition tests pass. Physical iPhone pending.

- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/touch-menu-fixes-20261030/acceptance.json` — Current-host retained-graphics Mac case and before/final screenshots.

### inventory.actions

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets owned by current screen.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_native_list_select`: Selects through native list/setter entry point.

**Verification (passed; game state):** Inventory action/popup behavior is recorded.

### inventory.sort_rotate_recipe

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_grid_carousel_to_view`: Publishes grid/page/carousel targets.

**Verification (passed; game state):** Sort, rotate and recipe Close evidence is recorded.

### quest.rows_categories

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_native_list_select`: Selects through native list/setter entry point.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_list_categories_to_view`: Publishes native category controls.

**Verification (passed; game state):** Quest rows/categories evidence is recorded.

### map.pan_zoom

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_service_map_tap`: Maps touch to native map point.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_service_map_drag`: Updates map through native drag setter.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `dm_botw_touch_menu_pinch`: Maps pinch to native zoom levels.
- [dm/host/front_mac.m](../../dm/host/front_mac.m) `magnifyWithEvent:`: Allows magnification only for a live BOTW touch-map owner; tracks gesture direction and cancels outside-map/footer starts.
- [dm/host/front_mac.m](../../dm/host/front_mac.m) `scrollWheel:`: Uses menu pointer phases for map drag and ignores momentum replay.

**Verification (passed; game state):** Mac map gestures passed; focused platform-owner trackpad checks also passed 12/12. Physical iPhone validation remains pending.

- [dm/host/tests/t_botw_touch_trackpad.c](../../dm/host/tests/t_botw_touch_trackpad.c) `main`: Platform-owner report: 12/12 focused checks passed, including magnify allow/deny for BOTW touch-map ownership, stale owner, controller/gameplay mode and footer/outside-map start.

### map.stamp_warp_header

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_service_map_tap`: Maps touch to native map point.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `generic_action_prompts_to_view`: Publishes currently visible action prompts.

**Verification (not_run; none):** Shared native hit/focus/action path is present; the remaining conditional screen states have no independent end-to-end run evidence.

### applet.album

Album thumbnail selection and the viewer carousel route through live native targets; full-photo swipes now require an in-bounds start but may end outside the photo clip, while outside-origin gestures and unavailable native paging arrows remain rejected.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets owned by current screen.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_grid_carousel_to_view`: Publishes grid/page/carousel targets.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `dm_botw_touch_menu_pointer`: Routes the viewer swipe from its active clip and accepts an endpoint outside the clip after a valid in-bounds start.

**Verification (passed; game state):** Post-fix Mac guest replay on saved photo 01/48 passed: photo 2 advanced to photo 3 on an in-bounds left-edge swipe ending outside (.25,.5→.14,.5), then returned to photo 2 on an in-bounds right-edge swipe ending outside (.75,.5→.86,.5). The focused handler test also rejects outside-origin gestures and preserves cancellation. The earlier intermittent edge failure is resolved for these observed cases.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_slate_paging`: Covers left/right edge swipes ending outside, outside-origin rejection, and cancel behavior.

- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/album-regression-current/runtime-postfix.json` — Mac guest route record identifies the active Album photo and post-fix left/right edge swipe transitions.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/album-regression-current/run-postfix.log` — Retained post-fix guest run log for Album edge swipe verification.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/album-regression-current/postfix-photo-middle-before-swipes.png` — Guest photo state before the two edge swipes.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/album-regression-current/postfix-photo-after-left-edge-swipe.png` — Guest state after the left-edge swipe advances to the next photo.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/album-regression-current/postfix-photo-after-right-edge-swipe.png` — Guest state after the right-edge swipe returns to the previous photo.

### applet.picture_book

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets owned by current screen.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_native_list_select`: Selects through native list/setter entry point.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_apply_list_category`: Validated five-category widget calls the native immediate completion mode instead of the animated stick wrapper.

**Verification (not_run; none):** Mac actual category clicks jump Creatures to Treasure and back with native immediate completion. Registered-entry details remain pending.

### applet.tool

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets owned by current screen.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `generic_action_prompts_to_view`: Publishes currently visible action prompts.

**Verification (not_run; none):** Shared native hit/focus/action path is present; the remaining conditional screen states have no independent end-to-end run evidence.

### applet.camera

All enumerated AppCamera actions plus the newly required touch-gamepad/menu coexistence state have concrete owner-scoped platform handlers.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_cursorless_prompt_view`: Publishes live owner-bound AppCamera prompt actions.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `generic_action_prompts_to_view`: Maps displayed A/B/X/Minus glyphs to footer touch targets.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `dm_botw_touch_menu_pointer`: Routes single-finger camera framing to native right-stick axes.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `dm_botw_touch_menu_pinch`: Routes pinch gesture to native D-pad zoom steps.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `dm_botw_touch_camera_pose`: Routes self-portrait pose to native left-stick axes under live AppCamera ownership.
- [dm/ios/Sources/DmGamepad.m](../../dm/ios/Sources/DmGamepad.m) `updateBotwCameraGesture`: Separates iOS pinch zoom and two-finger parallel pose gestures.
- [dm/host/front_mac.m](../../dm/host/front_mac.m) `scrollWheel:`: Supports Mac trackpad pinch and pose scroll paths.

**Verification (passed; game state):** Existing camera actions retain their route and in-game evidence; coexistence is now observed in the Mac native window through viewfinder, same-owner capture modal, and discard back to viewfinder. UIKit handler runs cover touch ownership, footer hint routing, controller suppression, and cleanup. No AppKit frontend harness was run.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_cursorless_help_prompts`: Covers AppCamera A, B, X, Minus, zoom, framing, pose+ZL, modifier release, and owner-change cancellation.
- [dm/host/tests/t_botw_touch_trackpad.c](../../dm/host/tests/t_botw_touch_trackpad.c) `main`: 23/23 checks cover platform-neutral pose/zoom gesture classification and release.
- [dm/ios/tests/ios_look_harness.m](../../dm/ios/tests/ios_look_harness.m) `test_botw_inventory_pointer`: Covers camera gamepad/menu coexistence, active-input cleanup on modal owner change, controls visibility, and reentry.
- [dm/ios/tests/ios_look_harness.m](../../dm/ios/tests/ios_look_harness.m) `test_botw_inventory_pointer`: Covers the camera controls/menu coexistence touch path and owner transition cleanup.
- [dm/ios/tests/ios_look_harness.m](../../dm/ios/tests/ios_look_harness.m) `test_botw_virtual_buttons`: Covers native AppCamera footer label hits without stealing ordinary virtual A.

- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-coverage-20261030/camera-controls-harness-6/details.log` — UIKit handler run reports zero failures and 33 look BEGIN sessions, including controller suppression/restore.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-coverage-20261030/camera-footer-harness-final/details.log` — Final UIKit footer run reports zero failures.

### applet.dungeon

Tilt and Back/Execute use the rendered capture geometry, the live map exposes the D-pad, and relative drag feeds the dungeon camera. Marker taps use live projected centers and the native selection function; the sensor selector inherits the live AppHome prompts.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_cursorless_prompt_view`: Checks the live AppHome and dungeon page before exposing the map controls and D-pad.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_dungeon_prompts`: Maps the offscreen A/B capture to the visible Divine Beast controls.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_publish_generic_view`: Retains AppHome prompts while the sensor selector owns focus.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `dungeon_rotate_input`: Consumes accumulated movement through the dungeon camera while retaining its native limits.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_dungeon_markers`: Uses the projected centers in the game's live selector list, which move with the 3D map.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `dungeon_service_marker`: Calls the validated native selector on the owning game thread after a stationary marker tap.

**Verification (passed; game state):** On Mac with the supplied Vah Medoh save, D-pad selection, Tilt/Execute, sensor and Leave Area prompts, direct marker taps before and after rotation, and relative map dragging worked. Other beasts and physical iPhone gesture feel remain unverified.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_dungeon_captured_prompts`: Checks visible, hidden and ambiguous capture destinations.
- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_dungeon_focused_footer`: Checks focused selector footer ownership and rejects a stale owner.
- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_dungeon_relative_rotation`: Checks accumulated deltas, native interval, cancellation and controller precedence.
- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_dungeon_marker_taps`: Checks projected marker coordinates, tap selection, drag separation and stale owner rejection.

- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/divine-beast-20261109-144505/45-reopen7.png` — The map after choosing Tilt and Execute shows the changed beast pose.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/divine-beast-20261109-144505/game8.log` — Mac game input trace for equal and opposite slow/fast drags, vertical movement and release.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/divine-beast-20261109-144505/game9.log` — Mac run covering sensor selection, Back, Leave Area and cancellation.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/divine-beast-20261109-144505/game11.log` — Mac scripted pointer trace for marker selection before and after rotating the map.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/divine-beast-20261109-144505/76-marker-middle11.png` — The middle position is highlighted after a direct tap.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/divine-beast-20261109-144505/79-marker-after-rotate11.png` — The top position is highlighted at its new location after a drag and direct tap.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/divine-beast-20261109-144505/game12.log` — Final current-checkout Mac run: direct marker selection, map drag, Tilt and Execute.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/divine-beast-20261109-144505/86-reopen12.png` — Reopening after Tilt and Execute shows the changed beast pose.

### options.rows_values

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_value_adjusters_to_view`: Publishes native labels, arrows and numeric adjustments.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_focus_list_scroll`: Direct focus/select and native list scrolling.

**Verification (passed; game state):** Options values and scroll evidence is recorded.

### title.load

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets owned by current screen.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_native_list_select`: Selects through native list/setter entry point.

**Verification (passed; game state):** Title, Continue and load confirmation are Mac-verified.

### system.ack

Normal SystemWindow variants use visible authored targets and/or visible native guides. Choice-less no-button panels are separately classified as passive waiting states.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets owned by the current dialog screen.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `generic_action_prompts_to_view`: Publishes currently visible native action prompts.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_cursorless_prompt_view`: Provides owner-bound prompt dispatch for dialogs that expose guides.

**Verification (not_run; none):** Shared native target and prompt paths are present; no live dialog interaction was observed in this turn.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_cursorless_help_prompts`: Synthetic tests exercise owner-bound prompt dispatch for guide-bearing screens; no-button panels are intentionally excluded.

### system.dlc_amiibo

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets owned by current screen.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_native_list_select`: Selects through native list/setter entry point.

**Verification (not_run; none):** Shared native hit/focus/action path is present; the remaining conditional screen states have no independent end-to-end run evidence.

### system.controller_pairing

Controller diagrams/text do not expose touch actions; host HID reports connected-player status without opening an OS pairing UI. Shared TRANSITION presentation keeps gamepad/gameplay controls hidden while these status screens are presented.

- [dm/host/hle_hid.c](../../dm/host/hle_hid.c) `h_hid_ShowCtrl`: Reads connected players and returns selected player information immediately; it does not present a controller-pairing UI.
- [dm/host/hle_hid.c](../../dm/host/hle_hid.c) `h_hid_ShowCtrl0`: The no-result controller support applet returns success immediately.

**Verification (not_required; not required):** No touch pairing interaction is required for these host/OS controller-service screens.

- [dm/host/tests/t_hid.c](../../dm/host/tests/t_hid.c) `main`: HID test source exercises the connected-player result contract. This is host/service verification, not a touch interaction.

### system.save_transfer

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds the visible PaCommonBtnThin_00 B_Hit_00 entries in SaveTransferWindow_00.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_native_list_select`: Activates transfer/continue/cancel through the native selector.

**Verification (blocked; none):** No source/destination save-transfer state was available for an end-to-end run; this does not indicate missing code.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `main`: Synthetic SaveTransferWindow test exposes Pa_BtnL_00 and Pa_BtnR_00 as two distinct native registered targets.

### system.keyboard_text

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_swkbd.c](../../dm/host/hle_swkbd.c) `swkbd_show`: Converts the game keyboard request, blocks for host text input, enforces UTF-16 length limits, and writes the result/cancel code back to the guest.
- [dm/host/hle_swkbd.c](../../dm/host/hle_swkbd.c) `h_swkbd_Show`: Routes the guest ShowKeyboard applet call to front_text_input.
- [dm/host/front_mac.m](../../dm/host/front_mac.m) `front_text_input`: Presents a native editable text-input dialog to the user.

**Verification (not_run; none):** The software keyboard HLE forwards ShowKeyboard requests into the platform text-input UI; the exact BOTW keyboard/name-entry state was not reached in this scan.

### horse.registry

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets owned by current screen.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_native_list_select`: Selects through native list/setter entry point.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Uses the visible PaHorseBtn_00 NormalButton B_Hit_00 entries for registered ShopHorse rows.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_native_list_select`: Commits row selection through the guest native list selector.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `generic_action_prompts_to_view`: Publishes the live A/B footer prompts for confirm/cancel, including capture/registration state.

**Verification (blocked; none):** No horse-registration save/state was available for an end-to-end run; this does not indicate missing code.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `main`: Synthetic ShopHorse test verifies two Pa_ShopBtn rows resolve independently through their own native B_Hit entries.

### horse.name_entry

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_swkbd.c](../../dm/host/hle_swkbd.c) `swkbd_show`: Converts the game keyboard request, blocks for host text input, enforces UTF-16 length limits, and writes the result/cancel code back to the guest.
- [dm/host/hle_swkbd.c](../../dm/host/hle_swkbd.c) `h_swkbd_Show`: Routes the guest ShowKeyboard applet call to front_text_input.
- [dm/host/front_mac.m](../../dm/host/front_mac.m) `front_text_input`: Presents a native editable text-input dialog to the user.

**Verification (not_run; none):** The software keyboard HLE forwards ShowKeyboard requests into the platform text-input UI; the exact BOTW keyboard/name-entry state was not reached in this scan.

### horse.hud

The layout/state is evidenced as noninteractive and has no input action in scope.

**Verification (not_required; not required):** MainHorse_00 is HUD/status artwork with no native cnt1 control, hit candidate, or independent input owner; it has no menu action to implement.

### guide.shrine

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_cursorless_prompt_view`: Publishes native prompt-only actions.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `generic_action_prompts_to_view`: Publishes currently visible action prompts.

**Verification (passed; game state):** Shrine Quit/Cancel user-verified and native regression passed.

### notice.ack

Pickup and quest updates are passive corner notifications. Their Plus hints use the visible gameplay pad and do not own a touch menu.

**Verification (not_required; not required):** Native layouts place both notices at the right corner with a Plus glyph. The shared TIP policy excludes their lifecycle and cached guides from menu ownership.

### system.error_viewer

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Maps legacy L_BtnDialog* parts and their B_BtnDialog alternate hit panes to the registered native owner entry.

**Verification (not_run; none):** Synthetic ErrorViewer fixture was exercised in the native touch-menu suite; no live guest ErrorViewer error dialog was reached, so game-state verification remains not_run.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `main`: Synthetic registered-entry test asserts two ErrorViewer targets and binds B_BtnDialog to its native owner.

### ending.continue_skip

The live B guide and arrow controls are published through cursorless native prompt handlers.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_pointer_screen_name`: Admits End/StaffRoll/StaffRollDLC/Thanks variants; routing alone does not establish their native skip/continue action.

**Verification (passed; handler test):** Synthetic owner-bound test passed for B skip and separate up/down page-scroll actions.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_cursorless_help_prompts`: Synthetic StaffRollDLC test covers native B skip and separate up/down page-scroll actions.
- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_cursorless_help_prompts`: Native peer reports focused test passed; asserts StaffRollDLC B skip and up/down credit paging remain distinct.

### intro.advance_mode

The screen has concrete PaCommonBtnThin_00 B_Hit_00 targets and uses the shared generic native selector.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_pointer_screen_name`: Admits the listed intro/mode screens where matched by the ordered route table; action ownership remains state-specific.

**Verification (not_run; none):** The mode-choice route and native target path are represented; no live HardMode_00 mode-choice outcome was exercised.

### gameover.choices

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets owned by current screen.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_native_list_select`: Selects through native list/setter entry point.

**Verification (not_run; none):** Shared native hit/focus/action path is present; the remaining conditional screen states have no independent end-to-end run evidence.

### apphome.pages

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_apphome_owner_active`: Requires live AppHome parent for child input.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `generic_action_prompts_to_view`: Publishes currently visible action prompts.

**Verification (not_run; none):** Shared native hit/focus/action path is present; the remaining conditional screen states have no independent end-to-end run evidence.

### pause.home

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets owned by current screen.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_native_list_select`: Selects through native list/setter entry point.

**Verification (passed; game state):** System-menu entry and load flow recorded.

### message.variants

A complete shared or screen-specific code path is present; verification status separately records whether this exact guest state has been exercised.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_message_prompt_view`: Publishes visible dialogue body/continuation arrow.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets owned by current screen.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `generic_action_prompts_to_view`: Publishes currently visible action prompts.

**Verification (not_run; none):** Shared native hit/focus/action path is present; the remaining conditional screen states have no independent end-to-end run evidence.

### intro.passive_transitions

These layouts are presentation/transition output; the separate HardMode_00 option rows and Skip_00 X guide are the native interaction owners.

**Verification (not_required; not required):** No independent touch action is required for these visual/transition layouts based on the supplied native UI resources.

### ending.passive_artwork

Base ending/credit layouts present only rendered end/credit text; the separately interactive StaffRollDLC_00 owns the live B skip and Up/Down page arrows.

**Verification (not_required; not required):** No independent touch action is required for these visual/transition layouts based on the supplied native UI resources.

### camera.shutter

A shutter prompt action and the same-owner native Delete/Save hit targets share the AppCamera touch route; native target selection dispatches the choices.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_cursorless_prompt_view`: Publishes the current AppCamera A shutter guide under its live owner.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Finds visible native hit/focus targets in the nested AppCamera capture confirmation, including Pa_BtnL_01 and Pa_BtnR_01 B_Hit_00.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_native_list_select`: Dispatches the selected native Save/Delete target through the current AppCamera owner.

**Verification (passed; game state):** Final Mac guest replay passes the native A capture prompt into same-owner Save/Delete choices and Delete back to the viewfinder. The Save branch was not clicked, so no photo was stored.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_cursorless_help_prompts`: Synthetic test taps AppCamera A and asserts the native shutter action.

- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/camera-shutter-dialog.png` — Mac guest runtime screenshot showing the capture confirmation with Delete and Save buttons.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/camera-shutter-observation.json` — Mac guest audit before/after captures the live AppCamera_00 owner and distinct Delete/Save B_Hit_00 targets after A capture.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/final-suite-camera-navigation/replay.json` — Final six-step Mac guest route passes Camera Capture→Save/Delete choices and Delete→viewfinder; no Save step is issued.

### camera.back

A camera-specific live prompt/handler is present.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_cursorless_prompt_view`: Publishes the live camera back guide through native prompt ownership.

**Verification (passed; game state):** Final Mac guest navigation replay passes the native AppCamera Quit/Back prompt to gameplay, after also exercising Album Back to Camera.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_cursorless_help_prompts`: Exercises native B guide/back dispatch in the same generic owner-bound prompt adapter used by AppCamera.

- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/before-wait-presentation-fix/final-suite-camera-navigation/replay.json` — Final Mac guest replay passes Camera Quit: AppCamera_00 active → gameplay visible, no menu presentation, active false.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/final-suite-camera-navigation/replay.json` — Final six-step Mac guest route passes Camera Quit→gameplay; the older four-step route remains as historical pre-wait-presentation evidence.

### camera.self_portrait

A camera-specific live prompt/handler is present.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `generic_action_prompts_to_view`: Collects the live X guide as an action target.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `guide_glyph_button`: Maps the native X glyph to the X action.

**Verification (passed; game state):** Mac guest runtime changed into Self-Portrait mode under the native AppCamera X action. The emitted X path also has a focused synthetic touch assertion.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_cursorless_help_prompts`: Taps AppCamera X guide and asserts the native X output.

- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/camera-selfie.png` — Mac guest runtime screenshot after the native X self-portrait action.

### camera.album

A concrete AppCamera touch route is present under exact native owner validation.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `generic_action_button`: Accepts Minus as a native touch action.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `guide_glyph_button`: Maps the AppCamera Album glyph 0xe04c to Minus.

**Verification (passed; game state):** Mac guest touch replay opened the native Album from AppCamera; the separate return-to-camera Back step is recorded under core.back. The camera album action is game-state verified.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_cursorless_help_prompts`: The test checks Minus guide mapping and the touch pulse; no live Album screen was observed.

- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/suite-camera-album/replay.json` — Mac guest audit replay: tap native Minus hint; AppCamera transitions to AppAlbum.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/before-wait-presentation-fix/final-suite-camera-navigation/replay.json` — Final Mac guest replay passes the AppCamera Minus Album hint transitioning to AppAlbum_00.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/suite-camera-album/replay.json` — Earlier Mac guest album replay; preserved as historical evidence before the final blocking-presentation fix.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/final-suite-camera-navigation/replay.json` — Final six-step Mac guest replay passes AppCamera Minus→Album.

### camera.framing_focus

A concrete AppCamera touch route is present under exact native owner validation.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `camera_owner_live_locked`: Restricts camera axis injection to the active AppCamera prompt owner.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `dm_botw_touch_menu_pointer`: Maps one-finger drag deltas to native right-stick framing axes.

**Verification (passed; game state):** Mac guest runtime before/after/held-still screenshots confirm that the touch drag changes camera framing and then stops; handler tests also cover owner and physical-channel preservation.

- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/camera-before-drag.png` — Mac guest AppCamera framing before touch drag.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/camera-after-drag.png` — Mac guest AppCamera framing after touch drag.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-implementation-20261030/camera-held-still.png` — Mac guest AppCamera view held still after drag; no continued camera motion.

### camera.zoom

A concrete AppCamera touch route is present under exact native owner validation.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `camera_owner_live_locked`: Restricts zoom injection to the active AppCamera prompt owner.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `dm_botw_touch_menu_pinch`: Accumulates pinch distance into native D-pad Up/Down zoom steps and clears on neutral input.

**Verification (passed; handler test):** The test covers both native zoom directions and release; the runtime contract was confirmed by the native peer.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_cursorless_help_prompts`: The test covers both native zoom directions and release; the runtime contract was confirmed by the native peer.

### camera.selfie_pose

Both platform handlers hold and release the owner-scoped native ZL modifier with the pose gesture; the gesture reducer separates pose from zoom at the corrected 8-point directional threshold.

- [dm/ios/Sources/DmGamepad.m](../../dm/ios/Sources/DmGamepad.m) `touchesBegan:`: Starts the camera gesture only for live AppCamera and assigns a third touch as the ZL modifier after pose lock.
- [dm/ios/Sources/DmGamepad.m](../../dm/ios/Sources/DmGamepad.m) `updateBotwCameraGesture:`: Updates pinch/pose gesture and applies ZL only for pose mode while the third finger is held.
- [dm/ios/Sources/DmGamepad.m](../../dm/ios/Sources/DmGamepad.m) `endTouches:`: Releases ZL when the modifier finger ends and clears pose input on gesture end.
- [dm/ios/Sources/DmGamepad.m](../../dm/ios/Sources/DmGamepad.m) `touchesCancelled:`: Uses the cancellation path that clears both pose axes and modifier.
- [dm/host/front_mac.m](../../dm/host/front_mac.m) `mouseDown:`: Begins Option-drag pose under the exact AppCamera owner.
- [dm/host/front_mac.m](../../dm/host/front_mac.m) `mouseDragged:`: Updates Mac pose axes and holds the Shift-modified ZL action.
- [dm/host/front_mac.m](../../dm/host/front_mac.m) `scrollWheel:`: Uses Shift precise-scroll for pose and Option for the additional-pose ZL modifier.
- [dm/host/front_mac.m](../../dm/host/front_mac.m) `flagsChanged:`: Tracks modifier release during Mac pose gestures.
- [dm/host/front_mac.m](../../dm/host/front_mac.m) `cancelInput`: Clears pose and ZL on cancellation/resize/reset.
- [dm/host/botw_touch_trackpad.h](../../dm/host/botw_touch_trackpad.h) `dm_botw_camera_gesture_update`: Locks parallel movement to directed pose after 8 points and pinch span to zoom.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `dm_botw_touch_camera_pose_modifier`: Publishes ZL only for a live AppCamera pose action.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `dm_botw_touch_menu_apply`: Applies pose and ZL only to available native channels and clears on owner loss.

**Verification (passed; handler test):** Focused menu tests verify ZL activation/release and owner replacement; the 23/23 trackpad suite verifies the 8-point directional pose-vs-zoom classifier and release. UIKit harness reported zero failures; no live game pose was available.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_cursorless_help_prompts`: Asserts left-stick pose with ZL, modifier release, and no inherited axes or ZL after owner replacement.
- [dm/host/tests/t_botw_touch_trackpad.c](../../dm/host/tests/t_botw_touch_trackpad.c) `main`: 23/23 checks cover pose direction/threshold, pinch-vs-pose locking, and end/cancel release.

### camera.gamepad_menu_coexistence

iOS and Mac now separate safe-viewfinder control presentation from the AppCamera menu owner. Touches are assigned to gamepad controls or the native menu on begin and retain that owner through the gesture; controls hide and active output clears when the camera owner changes to the capture modal.

- [dm/ios/Sources/DmGamepad.m](../../dm/ios/Sources/DmGamepad.m) `refreshBotwTouchMenuMode`: Tracks safe-camera gamepad presentation separately from menu mode and clears active owners/output on camera-owner changes.
- [dm/ios/Sources/DmGamepad.m](../../dm/ios/Sources/DmGamepad.m) `touchesBegan:`: Routes eligible gamepad hits first and sends remaining safe-camera touches to the native AppCamera pointer/gesture path.
- [dm/host/front_mac.m](../../dm/host/front_mac.m) `setBotwMenuActive:`: Tracks camera-control presentation while retaining the menu routing mode.
- [dm/host/front_mac.m](../../dm/host/front_mac.m) `mouseDown:`: Routes control hits before forwarding free-area touches to the native menu.
- [dm/host/front_mac.m](../../dm/host/front_mac.m) `drawRect:`: Draws controls only while the safe AppCamera viewfinder owner is active.

**Verification (passed; game state):** Mac native-window observation confirmed the touch gamepad is visible in the AppCamera viewfinder; a native MENU_A capture opens the same-owner Save/Delete modal and hides the gamepad, and Delete returns to the viewfinder with the gamepad visible again. UIKit harnesses separately verify gamepad A hits versus menu free-area pointer routing, modal owner cleanup/reentry, controller suppression, and visible A/B/X/Minus guide taps without stealing normal virtual A. No Mac AppKit harness was run.

- [dm/ios/tests/ios_look_harness.m](../../dm/ios/tests/ios_look_harness.m) `test_botw_inventory_pointer`: Exercises AppCamera controls and menu touch coexistence, modal owner loss cleanup, controller gating, and viewfinder reentry.
- [dm/ios/tests/ios_look_harness.m](../../dm/ios/tests/ios_look_harness.m) `test_botw_virtual_buttons`: Exercises native AppCamera prompt-label touches and confirms ordinary virtual A retains priority.

- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-coverage-20261030/camera-controls-harness-6/details.log` — UIKit handler run reports zero failures and 33 look BEGIN sessions, including controller suppression/restore.
- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/ui-coverage-20261030/camera-footer-harness-final/details.log` — Final UIKit footer run reports zero failures; A/B/X/Minus hint-label taps route to the native menu without stealing a real virtual A hit.

### cutscene.skip

The shared cursorless prompt adapter admits the live Skip_00 owner and publishes its X action.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_cursorless_prompt_view`: Resolves a live X guide under Pa_Skip_00 and publishes it for the shown native screen owner.

**Verification (passed; handler test):** The focused cutscene skip regression passed for the live native X guide path.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_cutscene_skip_prompt`: Asserts that the cutscene Skip_00 X guide produces the native X action.

### system.controller_manual

ControllerWindow has a native button component in its page list and live guide/arrow surfaces handled by shared generic target and prompt adapters.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_find_generic_targets`: Discovers the PaCommonBtnThinAction_00 B_Hit_00 page-list target under the live ControllerWindow owner.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_cursorless_prompt_view`: Publishes live A/B guide prompts from the active ControllerWindow root.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_paging_prompts`: Maps Pa_ArrowU_00/Pa_ArrowD_00 page arrows to native Up/Down actions.

**Verification (not_run; none):** The generic prompt path has a ControllerWindow B assertion, but page-list selection and arrow paging were not exercised end to end in this turn.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_cursorless_help_prompts`: Synthetic native owner test asserts ControllerWindow B guide mapping; remaining page-list and arrow details are not covered by that assertion.

### system.ack.no_button_wait

No touch action is authored by these message-only layouts. Shared TRANSITION presentation blocks gameplay controls/gamepad while the modal is shown; this is separate from touch acknowledgement.

**Verification (not_required; not required):** There is no authored touch interaction to verify for these passive waiting layouts.

### scope.native_actions

Concrete native and platform handlers are present; handler and game-state acceptance are tracked independently.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_scope_prompts_to_view`: Maps live capture-backed guide rectangles under the shown Scope bar to native glyph actions.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `dm_botw_touch_scope_prompt_at`: Only native hint rectangles request pointer ownership; the ordinary gameplay controls and free-area look keep their input.

**Verification (passed; game state):** Current-host retained-graphics Mac window clicks Quit, Place pin and Edit pins; pad remains visible and free-area drag rotates. UIKit coexistence checks pass; physical iPhone pending.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_scope_native_prompts`: Checks native scope ownership, action output and coexistence; runtime acceptance recorded separately.
- [dm/ios/tests/ios_look_harness.m](../../dm/ios/tests/ios_look_harness.m) `test_botw_scope_pointer`: Zero-failure UIKit run checks all three hints, control priority, concurrent owners, R3 and controller suppression.

- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/touch-menu-fixes-20261030/acceptance.json` — Mac actions and exact source/runtime evidence with retained-graphics validation boundary.

### item_get.inventory

Concrete native and platform handlers are present; handler and game-state acceptance are tracked independently.

- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `generic_back_prompt_observe`: Recognizes the live T_PauseGuide_00/T_Icon_00 pair and native Plus glyph.
- [dm/host/hle_botw_touch_menu.c](../../dm/host/hle_botw_touch_menu.c) `selector_message_prompt_view`: Publishes owner-bound native hints before the broad continuation surface.

**Verification (passed; game state):** Mac supplied shrine save: after freeing one slot in the disposable copy, the Eightfold Blade card shows Inventory Plus; clicking its label emits native Plus and opens Inventory focused on the new item. Full-bag hidden hint is not published. Physical iPhone pending.

- [dm/host/tests/t_botw_touch_menu.c](../../dm/host/tests/t_botw_touch_menu.c) `test_new_item_inventory_prompt`: Checks Plus glyph/label/body overlap and hidden/stale/capture/controller/owner-loss rejection.

- Recorded artifact: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/touch-menu-fixes-20261030/acceptance.json` — Native Plus emission and current-host retained-graphics screenshots before/after the actual label click.


## Updating and checking

```sh
python3 dm/tools/botw_touch_progress.py
python3 dm/tools/botw_touch_progress.py --check --require-complete
python3 dm/tools/botw_touch_progress.py --check --catalogue /path/to/catalogue.json
```

The check rejects unclassified layouts, missing action links, dangling source/component evidence and stale generated documentation. `--require-complete` also rejects every partial or missing required action, independently of verification availability. An explicit catalogue checks that every resource and exact part reference is accounted for. This validates the record; source review and interaction tests establish whether its claims are correct.
