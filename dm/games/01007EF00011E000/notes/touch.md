# BOTW touch controls, HUD and menus

## Touch and menu work

Resolved: rewriting the UI-camera observation at `main+0xd44a2c` after
`blr x8` was rejected by the generic post-call classifier. See
[Observation gates on any relocatable instruction](../../../../docs/reference/rewriter.md#observation-gates-on-any-relocatable-instruction).
The real `main`, `subsdk0` and `sdk` rewrite and cache-freshness check passed
on 2026-10-27; the subsequent full Mac shader/host build reaches gameplay.

BOTW touch-menu coverage and remaining runtime validation are tracked in
[Menu touch progress](../../../../docs/botw/touch-progress.md). The
[resource inventory and semantic regression workflow](../../../../docs/botw/ui-coverage.md)
adds a generated gap report; resource existence and screen recognition alone do
not establish touch acceptance. The resource census includes both installed
DLCs; their files add no BFLYT layouts or BFLAN animations.

[Touch implementation checklist](../../../../docs/botw/touch-implementation.md)
accounts for every scanned layout and its required screen/state/action group.
The editable `touch_ui_inventory.json` records implementation evidence and
verification independently; `dm/tools/botw_touch_progress.py --require-complete`
rejects any remaining partial/missing implementation. Referenced layout names
are NUL-terminated strings, unlike fixed-width 24-byte native pane names; the
resource scanner preserves both so long component references resolve exactly.

Resolved: Hero's Path was inferred from a private map-capture part, which stays
shown on the regular map, and its long name exceeded the 16-byte trace label.
HUD path lookup now compares complete 24-byte native names. Map direction-pad
visibility follows both native horizontal/vertical direction-key guides
(`E064`/`E065`) in the fresh, matching AppHome footer, after the existing shown,
input-owned parent proof. It does not use the dormant capture source as a mode
signal. Touch X, Back to the regular map and Back to gameplay pass with both
DLCs mounted. The automated routes and evidence are described in the progress
tracker; iPhone acceptance remains pending.

**Resolved: DLC Purchased buttons ignored touches (2026-11-01).** The shared
guide hit test clipped Staff Credits (Y) and Cancel (B) against each other even
though they occupy separate rows. Only glyphs in the same rendered row now
limit a guide's horizontal touch area. Opening the credits also leaves
DLCWindow shown and input-enabled underneath; prompt ownership now follows the
native ScreenMgr's registry order for distinct roots on the same draw layer
(`main+0xf7145c`), so the credits' Return button remains available.
Native regression checks cover both labels and glyphs, horizontal neighbors,
overlaid owners, hidden overlays and ambiguous shared roots. The
[DLC Purchased route](../touch_routes/dlc-purchased.json) exercises entry, credits,
Return and Cancel; all four steps passed in the current-checkout Mac touch
preview with both DLCs mounted and matching shaders. The full regression
harness remains blocked during preparation by the installed Metal compiler
(`32023.883`, lock `32023.921`). Runtime evidence is kept in
`01007EF00011E000-work/dlc-buttons-20261101/`; physical iPhone acceptance remains
pending.

The current Mac checks cover direct quest
selection, category changes and paging, and
Options adjustments and list swipes, stable control visibility during menu
animations, direct map dragging, and Beedle dialogue/buy/sell/quantity flows.
A shop quantity is accepted through the blank area of its number-selection
button, outside the number field and arrows. The dialogue body does not
accept a quantity. Terminal, divine and NPC speech now share text-output
role detection: rendered `P_Text_*`/`P_Sh_*` panes under `N_TextOut_*`, plus
sibling window bounds including blank padding. Container names and instance
suffixes do not select event-specific rules. The shown, input-enabled native
Message owner remains required; focused choices, quantity fields, hidden or
stale screens and private capture sources keep their existing restrictions.
The supplied `before-activate-tower` save reproduced the former inert body
tap. With the shared fix, "Sheikah Tower activated" (body), "Scanning
area..." (blank padding) and "Regional map extracted" over AppMap advanced
through native A, then returned to gameplay. The original save stayed
unchanged. Runtime evidence is in `01007EF00011E000-work/tower-dialogue-20261028/`:
the matching pre-merge graphics host carries the current menu adapter, with
only the observation registration API renamed for that host. The current
merged host also compiles and its native regression passes; the full merged
shader build remains incomplete and was stopped after retaining its completed
cache entries. This test does not establish merged graphics or physical
iPhone acceptance.

Message buttons park their native cursor hit panes
offscreen; use the live button window's bounds before falling back to text.
This also includes the blank padding around OK/Cancel labels. The number
field only focuses, and each +/- arrow retains its adjustment target.

Resolved: a completely empty save bypasses Title, so BoxCursorControl's update
has not run when Link wakes up. Observe the completed constructor as well as
its update, retaining the same validated manager before its screen registry
exists. Later native pane callbacks can then establish gameplay permission.
This keeps controls hidden during the opening movie and restores them when
the live MainScreen heart HUD appears. An empty-save Mac start passed without
opening a menu first. The constructor sequence and observation are gated to
the registered 1.9.0 build; existing input ownership checks still apply.
The MainScreen root remains shown between dialogue pages; its native heart-HUD
InOut layer establishes actual gameplay presentation across those gaps.
Cursorless ability explanations use their live native Back and page arrows;
the native Fade screen keeps controls hidden between menu exit and scene unload.
Ability paging/Cancel, System Save/Cancel, Return to Title and reloading the
new save passed on the Mac using a disposable copy of the user's save.
Save-list swipes share Options' native focus-and-scroll path. UIKit checks
cover restoration of the custom layout after loading/menus and both pinch
directions; the Mac map backend zoomed in/out through the same host pinch API.
Whole-window dialogue taps, inventory preview rotation/category arrows/recipe
Close, map sensor/stamps and Game Over retry also passed on the Mac. The
merged graphics runtime uses the matching 1.9.0 shader package. BOTW touch
artwork overrides the ordinary pad style: no button shadows, 35% gray at 20%
opacity and a 52% gray outline, with 20% thicker strokes. A/B/X/Y/R/ZR are
round and use the six supplied 240-pixel icons at half the button diameter.
When enabled, each action label sits in a 20% gray, gold-outlined badge on the upper-right
edge, half overlapping the main circle. Badges default off. The outer half of each visible badge presses
the same button; face-button sliding remains available.
Mac preview and UIKit rendering passed; controller/non-BOTW UIKit checks
restore the ordinary artwork. The seven `touch_*.png` assets are packaged in the app's
`dm` folder. ZL shows a shield and four directional arrows without an idle background;
holding reveals an unfilled ring and dragging moves a direction arrow just outside its
perimeter while the center stays at touch-down. Mac and UIKit share the vector
paths from [zelda-hyrule-ui](https://chaos-xxl.github.io/zelda-hyrule-ui/#/docs).
**Current:** a short ZL tap (at most 0.35 seconds, without a drag) keeps the
shield held after finger-up; another short tap or pressing B releases the held mode.
B also prevents an overlapping shield tap from re-latching, while a finger
physically holding ZL still permits ZL+B. The ring remains
visible while held. Long holds and drags release normally, and cancellation,
menu transitions, controller handoff and app deactivation clear the held shield.
The focused UIKit tap/hold/drag/movement/reset checks pass. The full UIKit
harness has the same 11 camera-hit, haptic and portrait-layout failures as the
pre-change handler, with no new failures; the independent geometry target also
fails its existing portrait-boundary assertion. Physical iPhone gameplay
acceptance remains pending. The harness uses the Scene lifecycle required by
the current iOS SDK.
BOTW's D-pad direction is captured at touch-down and held until release;
sliding face-button touches keep their original switching behavior. A movement
stick gesture that leaves its configured deadzone resets the L3 tap sequence,
even if it returns to its origin. Holds and release-only movement cannot seed
a double tap. `inventory-touch-20261025/run36-goddess-buttons/ios/` verifies
these paths, all six round icon buttons, palette values and ordinary-mode
restoration with zero UIKit failures. Mac packaging tests cover all seven assets, including the default L icon.
`inventory-touch-20261025/run23/ios-shield/` records the rendered idle/drag states
and passing input/release checks. The movement stick's base anchor is 10 frontend points
up/right of its ordinary home, before the configured default vertical offset of 0.023 canvas height. Its idle artwork is a white circle with four inner
arrows at alpha 0.15; dragging reveals an unfilled gray ring and an arrow just outside it.
Dragging beyond the ring retains one direction arrow, without an extra haptic
or automatic sprint. BOTW movement-stick grabs and L3 double taps are silent;
camera dragging and its R3 double tap are also silent. Face buttons and the ZL
shield-stick grab keep their press feedback.
The map/environment cluster reserves space for + with an 8-point gap. The
visible Plus cross and first heart retain their current padding on zero-inset
sides, including the additional 2 frontend points. A nonzero side inset replaces
that padding, aligning the complete button or first-heart edge to the safe boundary. Both +/- use a white cross over a 40%-opaque black
circle, with no border. Plus has one fixed anchor beside the minimap; its circle
sits 4 frontend points below the minimap top. The circle is 39 native layout
units across, and its centered cross is 19 units long with thickness set to 11%
of the circle diameter. Its position does not depend on minimap visibility,
including a cold start inside a shrine. Without the minimap, Minus appears
directly below Plus. Their shared Mac/UIKit geometry and glyph paths keep
drawing and hit areas aligned. The L rune badge shares
Y's opaque gray fill and gold outline. L now uses the same exterior border width
as XYAB, and R/ZR share the same base diameter. L always uses `touch_l.png`
from the supplied artwork, independently of the current rune and HUD messages.
In BOTW touch gameplay, the rune-style L button uses the ordinary button path:
it sends L immediately on touch-down, remains held while the finger is down,
and releases on finger-up or cancellation. It no longer delays the press or
substitutes D-pad Up after a long hold. The D-pad's own rune-selection behavior
is unchanged. Reset clears a held L and its unread press edge. The explicit L
hit region retains priority over the shield stick's nearby grab area.
`rune-immediate-20261029/` records the focused handler checks and Mac build;
physical iPhone gameplay acceptance remains pending.
By default, BOTW touch movement and ZL sticks use a 7% deadzone. Above 430 frontend
points of viewport height, their base outer-ring diameter is 140 points;
at or below 430, their previous size scaling remains. Movement defaults to 80%
of that size, reaches full output at 71% of its radius, and uses a continuous
radial 0.3-power curve after the deadzone: 20% radius produces about 62% stick
output and 40% produces about 82%. This raises short-drag output without
a time-based ramp; ZL keeps its linear response. The overshoot sprint gesture,
double-arrow indication, threshold haptics and native Dash observation have
been removed. The ordinary B button retains its native behavior. Controller
and other-game defaults remain unchanged. `inventory-touch-20261025/run28/`
records passing shared geometry checks, a Mac build and zero UIKit failures,
including both sticks, short/tall canvases and ordinary-mode restoration.
`inventory-touch-20261025/run33/` verifies the new curve and sprint removal:
native input/cancel checks pass, UIKit reports zero failures in 31 look
sessions, and the rewritten modules have no Dash observation. The matching
Mac preview reaches gameplay and is registered for quick launch; physical
iPhone movement feel remains for user acceptance.
The iOS and packaged Mac launchers offer a separate [Touch settings](../../../../docs/settings.md#touch-left-stick)
page before Play. The editor hides its navigation bar and keeps a compact Back
button beside its existing heading. The shared native geometry powers its draggable, pinch-resizable
layout preview and the real drawing/hit regions. XYAB moves/scales as one group,
with separate spacing; the D-pad equipment group moves/scales together. Movement,
ZL, L, R and ZR adjust independently; +/- stay fixed. Controls also have offset
and size sliders, per-control restore and restore-all-touch defaults. The movement
response chart retains deadzone (0–30%), curve (0.30–2.00) and full-travel (35–100%)
sliders. Play saves choices using the existing launcher preferences; environment
or file overrides remain locked. Layout/response settings apply only in BOTW
touch mode. ZL keeps its linear movement response. The geometry tests and UIKit
harness check custom drawing/hit alignment and controller-mode isolation; settings
storage tests check save/reopen/reset and exact parameter export. The editor
shows raw decimal values and offers **Copy all parameters**, suitable for
sharing new defaults. **Corner button labels** can hide the small circles on
all seven action buttons while preserving their icons and input. English and
Simplified Chinese launcher resources cover both fixed and generated setting
labels/notes. Current evidence lives in
`touch-settings-20261029/`; physical iPhone comfort remains for user acceptance.
Historical evidence in `touch-polish-20261029/` verifies the supplied `riding-horse` save: mounted
loadout remains visible, L shows the default artwork, and dismount restores the
current rune from its isolated source. The focused UIKit harness passes with
zero failures in 32 sessions, including badge-off artwork, fallback L, matching
border widths, R/ZR size and ordinary-mode restoration. The current merged Mac
host builds; native gameplay uses the retained matching graphics base, and the
full regression remains blocked by the existing translator/lock mismatch.
Physical iPhone acceptance remains separate.

**Point touch layouts (2026-11-02, updated 2026-11-03, current).** Normal and compact
controls now use fixed frontend-point diameters and independent X/Y point offsets.
Their rectangles anchor to the control area's left or right edge and bottom,
before applying each offset. Side and bottom safe insets no longer enter this
geometry; changing them also no longer changes the normal/compact selection.
Compact selection uses the actual upright control-area width below 600pt.
Duo Seated uses the lower control pane. Plus/Minus retain their HUD/safe-area
geometry. A/B/X/Y each have independent drawing, hit targets, drag/resize,
restore and exported parameters in both layouts.

The default anchors preserve the former 932x430 normal phone layout with
62pt side and 34pt bottom insets, and 390x844 compact with 34pt bottom inset,
rounded to 0.1pt. Normal A keeps a 28.6pt right margin and 59.4pt diameter;
compact A keeps 22.1pt and 43.9pt. Resizing keeps each control's side and bottom
edge margins. Saved fraction/scale customizations project onto those reference
layouts once; new `_X_PT`, `_Y_PT` and `_SIZE_PT` choices take precedence.
Resetting point defaults does not reimport the retired fraction values.
From 2026-11-03, normal-layout base left margins contract below 800pt of actual
control-area width, by width / 800 with a 0.8 lower bound. Safe insets do not
enter that calculation, and user offsets apply afterward in points. Diameters,
right/bottom margins and compact left margins retain their point values.
At 669pt wide, the movement-stick left margin becomes about 50.51pt, ZL 29.27pt
and the D-pad 205.80pt; the conservative gap to Y grows from 122.3pt to 162.60pt.
The shared geometry applies this rule to UIKit, the Mac preview and the editor.

**Saved layout library and scope protection (2026-11-03, current).** The shared
launcher keeps named layouts with independent normal/compact banks. Portable
JSON carries a schema version, one or multiple layouts, per-button left/right
anchors and point side/bottom margins; importing appends without replacing
existing layouts. Dragging across the center changes the horizontal anchor,
so a Rune/L moved to the right no longer inherits the default left-side width
rule. Explicit anchors fit to the actual control pane on both frontends;
import also fits a diameter that is larger than the pane. The library keeps at
least one layout and falls back to defaults when local data is absent or
unusable. Temporary launch overrides do not overwrite saved user geometry.
See [saved layouts](../../../../docs/settings.md#touch-left-stick) for the file
format and user actions.

A visible button placed on the right excludes scope double taps in a fixed
100pt-diameter disk, at least its actual bounds; ordinary camera dragging stays
active. The guard uses actual custom positions, including L moved right.
Controls now contains both controller and touch settings; Game is displayed as
Graphics. Temporary virtual controls expose Close beside Settings, and the iOS
FPS counter opens the same paused settings page. The shared
[live motion source selector](../../../../docs/reference/services.md#live-controller-motion)
defaults to controller-first automatic fallback to device motion.

Validation: native Mac host and iOS launcher fixture compile; the complete
Swift storage/layout check, 25 launcher metadata tests, 19 Mac-runner tests,
13 documentation checks and 157 HID checks pass. Current-source Mac testing
with matching shaders and a copied outdoor save reaches gameplay. Simulator
installation stalled before the new UIKit handler checks could run. Full
shader regression stops on Metal 32023.883 versus locked 32023.922; the full
GPU fixture also fails experimental frame-generation controls, whose graphics
sources this task does not change. Required LLVM23 tidy is unavailable; LLVM19
reports no finding in new code regions. Physical iPhone/iPad/Duo input and file
picker acceptance remain pending. Evidence is in `layout-library-20261103/` in
the external game work folder.
The earlier 768pt/90% trial passed native geometry/aspect/HUD checks, 702 UIKit checks
with 40 look sessions, and 37 focused settings/storage/documentation tests.
Current-source Mac test gameplay uses the matching existing shader cache and a
copied save. The independent quick shader regression stops before comparison:
local Metal 32023.883 differs from the pinned 32023.922. LLVM 19 reports the
same two frontend findings on unchanged main and this trial. Evidence is under
`touch-margins-20261103/` in the external game work folder.
The 800pt/80% parameter update has updated fixture expectations but has not
rerun validation. Expanded stick/D-pad grab circles can overlap at this floor;
the visible controls remain separate, and input ownership uses the existing routing.
The [touch settings guide](../../../../docs/settings.md#touch-left-stick) describes
the keys and units. The 2026-10-29 group/percentage defaults described earlier
are superseded by this layout; response deadzone/curve/full-travel fractions
retain their meanings.

Validation and captures are under `touch-points-20261102/` in the external
game work folder. Native geometry/HUD/aspect/live-settings fixtures pass,
including viewport compensation for native equipment artwork. UIKit passes
630 drawing/input/lifecycle checks and 40 look sessions, covering phone, iPad,
whole Duo and lower-pane sizes, insets, independent edits and resizing.
The 39 focused launcher/documentation checks, all 53 iOS support tests, and
194 iPhone SDK source compile checks pass. The current-source
`run_mac.py --test --touch-preview` reaches gameplay in the Duo Seated layout
with matching shaders and a copied save; its native HUD capture is retained.
Physical iPhone/iPad/Duo comfort acceptance remains for the user.

Regression scope is BOTW only: other games do not enter these control paths
or expose these settings, and ordinary/controller geometry is covered by the
UIKit fixture. The initial full point-layout regression is `CHANGED`: both
110-second routes reach gameplay, 19,592 shaders and their interfaces are
unchanged, and no new RED appears. FPS p50 is 59.2 to 59.1; frame p99 is 19.81
to 19.92ms. The screenshots retain the scene/camera with different foliage
animation and game time. After the native equipment size correction, the final
quick regression with touch preview and Seated enabled is `PASS`: frames 3628
to 3768, FPS 59.5 to 59.4, and no new shader/interface/RED failures. Reports
are `regress-report/report.md` and `regress-final/report.md` in that work folder.

The broad Python run's remaining seven failures and three errors reproduce
on unchanged `c671dd0b`: missing Mac UI files in host-MSL fixtures, undefined
`ui_finish` in shader-cache fixtures and obsolete frame-generation options.
The environment catalogue mismatch introduced by the new keys is fixed and
its check passes. Graphics motion controls also fail on unchanged `c671dd0b`.
Installed LLVM 19 reports the same two Mac findings before and after this
change; the repository's LLVM 23 lint baseline is not available locally.

The minimap/environment cluster and fixed +/- anchor retain the symmetric
heart/Plus padding described above.
R/ZR cancellation still happens only on an outside release. Crossing either way
over the cancel circle emits a haptic pulse; the release itself adds no pulse.
Continuous movement on the same side adds no pulse. Cancel rings follow live finger ownership,
not the virtual trigger retained for native acknowledgement. Release and reset
invalidate UIKit layout even when the published button bits have not changed,
preventing a canceled ZR guide from remaining visible.

**Touch HUD interactions (2026-10-30).** The native quick equipment/rune strip
publishes its live visibility independently of the collapsed loadout. While it
is open, touch right-stick axes and relative deltas reverse together so the
strip follows the finger. Scene look and physical controller axes retain their
direction. Mac touch preview now publishes the virtual stick as UIKit does;
previously only the ordinary Mac mouse path supplied that UI input.

The Hero's Path playback gauge in the native expanded map requests a separate
four-direction overlay. Combat controls remain hidden, touches outside that
overlay stay on the map path, and leaving Hero's Path releases held directions.
It follows the native gauge's ancestor visibility/alpha, not a remembered X
press, and does not depend on which map is open. Native and UIKit checks cover
activation, exit, direction ownership and controller-mode suppression. The
current test runtime has no mounted add-on content; X does not open Hero's Path
there, so actual playback and physical iPhone acceptance remain pending.

The relocated collapsed map is drawn before other screens in its native
ScreenMgr layer. OBS41 filters the draw receiver at the validated
`main+0xf714b8` dispatch and shifts preceding draw receivers one slot while
preserving their order. It never edits the screen/input registry. Expanded
maps, other layers, ordinary controller mode and other games retain their
native order. This avoids relying on retained roots' visibility as proof that
a dismissed screen is empty. Evidence and checks are in
`touch-hud-interactions-20261030/`; the matching graphics runtime boundary and
Metal compiler limitation described under Rendering still apply.

The production launcher is also compiled separately for simulator UI checks:
`run34/ui-custom-curve.png` records an interactive custom curve, and
`run34/ui-reset-applied.png` records restored stick defaults with the unrelated
30 fps choice preserved after Play. `run34/launcher-identity.txt` verifies the
installed preview executable matches the compiled one.
On iPhone, a three-finger double tap while automatic controls are hidden
reveals the original full virtual gamepad for the current menu visit. It
routes buttons and the native UI right stick directly, cancelling pending
menu pointers first. The three-finger chord cannot activate a menu item;
ordinary three-finger combat and revealed-pad combinations remain available.
Leaving menus, connecting a controller or resetting input ends the override;
no preference is stored. It also works without a native HUD/menu target and
keeps the 2D/3D switch hidden. The UIKit harness in
`inventory-touch-20261025/run34/ios-fallback/` checks configuration, scope,
chord ownership, raw controls and expiry. Physical three-finger recognition
remains for on-device acceptance.
`inventory-touch-20261025/run26/ios-style/` records the plain +/- glyphs,
outside direction arrows, the historical sprint double arrows and outline colors;
the UIKit harness passed with zero failures in 31 look sessions.
`inventory-touch-20261025/run24/ios-final/` records zero UIKit failures, including
controller/non-BOTW restoration and haptic call counts. Mac gameplay confirmed
the artwork, map spacing, Plus and return to gameplay. Physical vibration has
not been checked. Other shop layouts, user-photo files, registered Compendium details, physical-controller and iPhone checks
remain open; see the tracker for evidence and scope.

BOTW button borders lie entirely outside their unchanged background paths, with
their inner edge adjacent to the fill. UIKit uses a separate exterior band for
round buttons, R/ZR teardrops and L/Y badges; Mac preview offsets each circle's
stroke center by half its line width. Ordinary gamepad strokes and touch targets
stay unchanged. `inventory-touch-20261025/run25/ios-border/` has zero failures,
including non-overlap, full border width, badge touch and mode restoration checks.

Resolved: horizontal swipes did nothing in the shop's Sell grid. Its native
`ShopBtnList20_00` screen registers `Pa_Page_4x5_*` slots independently of the
pause inventory, so generic slot taps worked while inventory-only paging was
never reached. The live grid's `N_Cut_00` and category arrows now feed the same
R-stick page action as the pause inventory. Geometry stays scoped to the focused
native owner; stale/hidden grids and quantity dialogs cannot page the background.
`inventory-touch-20261025/run26/` records left/right swipes between the two
Materials pages, a page-arrow tap, direct Ironshroom selection and a blocked
background swipe during quantity selection. Native regression checks passed;
the matching Mac host is registered for quick launch.

Resolved: Impa's map explanation ignored both dialogue-body and continuation
arrow taps. `Message_00`, `AppHome_00` and `AppMap_00` remain shown and
input-enabled in the same native group; later map callbacks replaced the
eligible dialogue view with the background map. Selector ticks, map panes,
guides and ordinary native-menu publications now share the same owner choice:
an eligible dialogue precedes the map, followed by other cursorless prompts.
Each adapter retains its native owner, group, visibility and freshness checks;
focused choices and quantity buttons keep their registered-entry path.
`inventory-touch-20261025/run35-impa/` records reproduction from a disposable
copy of `Before-impa-dialogue`, the failing/passing native regression and the
rebuilt Mac acceptance. A single blank-padding tap at `(0.300, 0.829)` emitted
A at frame 25267, closed the map and continued Impa's next dialogue. All three
original save files remain unchanged. Physical iPhone acceptance is pending.

Resolved: goddess dialogue accepted only the continuation arrow. Its
`MessageSp_00` layout has no ordinary name-window background; the rendered
speech plate is `N_VoiceA_00/N_TextOut_01/P_Sh_01`. That visible plate now
feeds the shared Message continuation path, without accepting private capture
sources or confirming a focused choice through its text. A disposable copy of
`Goddess-dialogue` reproduces the failure and verifies a text-body tap advances,
followed by direct Heart Container and Yes selection. Evidence and native
regression checks are in `inventory-touch-20261025/run36-goddess-buttons/`.
The grant-power speech, reward-card text and farewell also advance by touch,
returning to gameplay with five hearts. The three original save files remain
unchanged. Open: gameplay controls briefly appear during the reward transition,
after the native Message screen closes but before the next prompt opens.

Resolved: first-acquisition item cards had no touch target. `MessageGet_00`
uses a direct `N_Sp_00/W_Base_00` card and a numbered `Pa_ABtn_*`
continuation part (`Pa_ABtn_08` in the supplied Eightfold Blade case), while
the dialogue recognizer accepted only the name-window background and
`Pa_ABtn_00`. Both now use the shared Message continuation path, so the whole
rendered card and its arrow send native A. Nested stat chips and private
capture sources cannot enlarge the card's touch region; existing native owner,
input-group, visibility and freshness checks remain in effect.
`inventory-touch-20261025/run27/` reproduces the failure with a disposable copy
of `save-before-shirin-and-new-pick`. The user verified the rebuilt Mac version:
a card-body tap at `(0.629, 0.543)` emitted A at frame 4019, closed the card and
restored gameplay by frame 4034. Native checks cover the body, numbered arrow,
outside taps, hidden/stale ownership and the previous dialogue cases. The three
source-save files remain unchanged; physical iPhone acceptance is separate.

Resolved: action-tutorial text and shrine Skip were not clickable. Tutorials
use `Pa_Tips_00/N_InOut_00/N_InOut_01/W_Base_00` as their outer continuation
window; its body now shares the native A path, excluding nested illustration
and capture backgrounds. `Skip_00` has no BoxCursor selection and remains
usable while cutscenes disable ordinary UI input groups. Its shown screen,
visible root and live X glyph establish ownership independently of that mask.
Prompt ownership is refreshed on pre-matrix callbacks too: the game can finish
opening a prompt while reusing its transform. Closing/hidden/stale owners
still cannot emit. Mac pointer checks continued the tutorial from blank body
padding and emitted native X from the shrine's Skip text.

**Resolved: shrine apparatus Cancel was not touchable (2026-10-29).**
The console's Move/Cancel row belongs to `SousaGuide_00`, a prompt-only
operation screen with no BoxCursor selection. It was excluded from cursorless
prompt discovery, although its native B glyph and label were already observed.
The shared prompt path now accepts this live, input-enabled owner when the
native gameplay HUD is hidden. Ordinary gameplay hints remain passive, so
they cannot hide or intercept the combat pad. The existing native group,
visibility, root, freshness and controller-mode checks remain in effect.
The failure was reproduced on a disposable copy of
`~/Desktop/botw-saves/Shrine-console`; native B worked while touching Cancel
did nothing. The user verified the fix works. Native regression checks cover
both ends of the glyph/label touch region and rejection while the gameplay
HUD is shown. The current merged Mac host compiles; test runtime paths and
logs are in `shrine-console-touch-20261029/`, with the compatibility graphics
boundary described under Rendering. No original save files were changed.

**Corner-tip control visibility (2026-10-29; device acceptance pending).**
`MessageTipsRunTime_00` and `MessageTipsPauseMenu_00` are non-modal corner
notifications. The former's layout contains the upper-right text/window and
guide; `MessageTips_00` separately owns the centered tutorial with its A
continuation. The broad `Message` screen classification incorrectly treated
the notifications as menus and hid the virtual gamepad for their duration.
The shared screen classifier now excludes both corner-tip screens from menu
presentation, focused/cursorless prompts and message continuation ownership.
Gameplay retains the pad; actual tutorials, dialogue, menus and loading keep
their existing input ownership. Headshot and shield-surf notifications require
the user's in-game check; no attempt was made to trigger either automatically.

**Resolved on Mac: item pickup hid controls and the backup right stick did not turn the camera (2026-10-31).**
The supplied `before-mushroom` save reproduces this with a Sunshroom.
`PickUpWin_00` retains its shown/input-owned state over live gameplay; its
Inventory hint is not a modal menu. Classifying it as one hid the pad even
after the corner notification faded. It now shares the passive corner-tip
policy, including rejection from focused and cursorless menu routing.
The separate [ordinary-stick/relative-look source fix](../../../../docs/reference/services.md#ordinary-virtual-sticks-while-relative-look-is-enabled)
preserves the backup pad's right-stick input.

`pickup-controls-20261031/` in the game's work folder records the independent
save copies, source/host identities and before/after audits: the baseline
reported a menu over live gameplay in 60 pickup snapshots; the fixed run's
21 recorded snapshots retained gameplay with no menu ownership. The Mac pad
remains visible, native virtual right-stick input turns the camera, and a
relative-look gesture still reaches the shared getter. Native tests, the
UIKit gesture harness and iPhone arm64 compilation of the changed input
files pass. Source-save hashes are unchanged. Gameplay uses the current host
input code with retained `371ad45` graphics and matching `07b0ea547435`
shaders; the complete current Mac host builds separately. The scoped BOTW
`regress.py check --quick` stops at the existing Metal compiler mismatch
(`32023.883` installed, `32023.921` required). Physical iPhone acceptance
remains pending.

**Quest notifications and climbing/slipping tips (2026-10-31).**
The native `ChallengeWin_00` is another passive corner notification: its part
is at `(590,106)`, beside the pickup part at `(590,50)`, and both contain the
same Plus glyph (`U+E04B`). There is no A acknowledgement. The old `MENU`
classification hid the pad and allowed the hint to take menu ownership.
It now shares the `TIP` policy with pickups. Native regression coverage
rejects its cached, visible Plus guide and keeps controls visible through
entering, shown and exiting notification states. Actual dialogue, tutorial,
loading and controller-wait ownership stays covered by the existing tests.

The English slippery-climbing and shield-surf messages belong to
`LayoutMsg/MessageTipsRunTime_00.msbt`, already excluded from menu detection.
Mac climbing with the native Jump/Let go hints retains the virtual pad and
publishes gameplay with no menu ownership. Loading-screen climbing advice
and centered tutorials remain separate blocking presentations.

Evidence is in `pickup-controls-20261031/quest-controls-fix-20261031/`:
the new native check fails before the policy change and passes after it;
UI audit/progress checks and the compatible Mac host build pass. The Impa
replay did not reach a quest notification, so a natural quest-update event
and physical iPhone acceptance remain pending. The scoped BOTW regression
is still blocked before boot by the required Metal compiler version.

**Resolved: full-health Eat/Cancel dialog ignored touches (2026-10-29).**
The native screen is `PauseMenuMantan_00`, with two registered `Pa_Btn_*`
entries. Only the exact `PauseMenu_00` and recipe screen were classified as
touch menus, so this separate screen published zero targets despite owning
input. The shared classifier now accepts the PauseMenu screen family while
excluding the render-only `PauseMenuBG_00` and `PauseMenuInfo_00` surfaces.
It uses the same live owner, entry eligibility, hit geometry and native focus
acknowledgement as other menu buttons; the message text is not a confirm
surface. Mac touch preview at 21:10 passed on an independent save copy:
Cancel closed the warning with ten apples retained; Eat confirmed from the
Cancel selection, closed it and reduced ten apples to nine. Captures, runtime
identity and logs are in `full-health-touch-20261029/`, using the compatibility
graphics runtime described under Rendering. Physical iPhone remains pending.

Resolved: Sell category icons were not registered cursor rows. The observed
shop navigation widget uses the same native category setter as quest tabs,
with seven `Pa_CategoryS_*` descriptors rather than four quest descriptors.
Touch now follows those native bindings, including disabled categories and
the Materials page count. Mac checks selected Cooking, Armor and Materials
directly; disabled weapon tabs remained inert and no item was sold.
`inventory-touch-20261025/run29/` retains the runtime and native regression
evidence for these menu fixes; both original source saves are unchanged.

BOTW movement-stick L3 double taps now require at most 200 ms between the
first release and the second touch-down, while retaining platform tap and
distance recognition. Mac preview uses the same gap. Camera double taps,
controller input and other games retain their existing handling. Shared
geometry checks and the UIKit handler suite pass, including 190/210/350 ms
cases and reset behavior; physical iPhone feel remains untested.

Resolved: shrines hid Minus because AppMap's `N_InOut_00` sets alpha to zero
while retaining its visible bit and collapsed viewport size. Map hit ownership
now checks ancestor alpha as well, so a transparent minimap cannot suppress
Minus. The completed Slate interaction also releases its consumed-map guard
on menu exit when gameplay resumes without a minimap. Native HUD checks,
UIKit mode/geometry checks and a Mac cold shrine start passed; the shrine's
Minus opens the map. `inventory-touch-20261025/run30/` records this revision.

**Touch HUD restoration and edge padding (2026-10-29).** A collapsed AppMap
now derives its translation and hit rectangle from its own freshly composed
viewport. It no longer waits for sensor/capture siblings, whose matrix callbacks
can stop while hidden after dialogue. The live screen registry separately
publishes whether MainShortCut's equipment group is visible. With gameplay
controls shown and that group absent, Mac/UIKit draw larger pale round direction
keys with triangular cutouts, retaining the existing locked D-pad touch actions.
Native loadout visibility hides this fallback again; menus, controllers and
other games retain their input behavior. The launcher names its editor
"BOTW touch settings", localized to Chinese.

**Resolved: iPhone minimap lost its hit region after Inventory (2026-10-30).**
The native map can publish its restored bounds before UIKit receives the menu
closing update. UIKit discarded that valid rectangle while its menu mode was
still active; the host sends only changed bounds, so returning to gameplay
could leave a visible map without a hit region and with standalone Minus.
Mac preview already retained this update independently of menu mode. UIKit now
retains the native rectangle too, while map hit testing still requires active
BOTW gameplay controls. A real native invalidation still clears the rectangle,
including hidden shrine maps. The focused handler regression reproduces both
callback orders before the fix and passes after it, including a real map tap,
no input while controls are hidden, and invalidation before menu return.
The production source compiles for iPhone arm64. Evidence is in
`ios-map-return-20261030/`; physical iPhone retesting remains pending.

**HUD safe-area edges (2026-11-01).** Left and right are independent. A zero
safe inset retains the existing heart/HUD/Plus margin; a nonzero inset replaces
that margin, with no extra gap inside the safe boundary. This supersedes the
2026-10-30 rule that ignored the landscape right inset. The native heart group
moves as one container, preserving full/partial heart spacing. Touch mode keeps
the map-to-Plus gap and aligns the full Plus button, including its background
and hit circle. Without the virtual Plus,
the native map's measured edge anchors the linked environment HUD instead.
Existing centered Seated controls and explicit picture bars retain their layout.
The HUD coordinate canvas stays fixed: margins translate anchors rather than
rescaling buttons or map hits. At 16:9 and narrower the native matrix receives
the translation; wide map draws retain the post-scissor GPU anchor.

Mac touch preview accepts `--touch-safe-area left,top,right,bottom` in points
(default all zero). Its virtual pad and native HUD receive the same insets.
Native fixtures cover one-sided/asymmetric insets, small positive insets,
wide/narrow/16:9 canvases, fixed-aspect bars, controller map bounds and stable
glyph size/hits. Mac live evidence and compiler checks are in
`hud-safe-area-20261101/` in the external game work folder. Physical iPhone
appearance still requires acceptance; shader regression retains the compiler
pin limitation documented in the Duo entry.

**Album and Hyrule Compendium touch (2026-10-30).** `AppPictureBook_00`
was missing from the Slate page family; its retained layout could not own
touch targets or inherit AppHome's native guide/header. It now shares that
ownership path with Album and Runes. Its five-category widget uses the
existing validated list setter with its actual descriptor paths and page
counts. Album and Compendium swipes derive their surface from the live native
`Pa_Page_*`, including sparse pages. The large-photo viewer's `B_Photo_00`
is observed separately as a gesture surface: native direction buttons page
photos, while a photo-body tap never triggers the native A/Delete action.
Viewer and grid identities differ to reject gestures crossing a transition;
Back, Delete and header actions retain the viewer's current identity too.
The supplied `After-dialogue-map-not-clickable` save is copied to scratch;
its stock photos and Compendium categories/paging provide Mac acceptance.
It omits user-photo JPEGs and has no registered Compendium entries, leaving
those file/detail operations for further acceptance. Native regression checks
and production iPhone arm64 compilation pass. Evidence is in
`minimap-album-compendium-20261030/`; physical iPhone retesting remains pending.

Native HUD/menu tests and the UIKit harness cover restoration with uncalculated
siblings, loadout hiding/restoration and control-mode isolation. Evidence is in
`touch-hud-refinements-20261029/`; its gameplay capture uses the retained
compatible graphics base described under Rendering, while the complete current
host also compiles.


#### Direct categories and gameplay HUD prompts

**Current, 2026-11-03:** the full-screen touch editor can add separate Weapons,
Shields, Food and Whistle controls in either point-layout bank. Their glyphs
are extracted from the user's `Pack/Bootup.pack!Layout/Common.sblarc` BNTX
(`Nt_PauseIconL_00/02/05`, `Ds_ShortCutHorseIcon_00`); bow context uses
`Nt_PauseIconL_01` and `Nt_PauseIcon_08`. The build prepares these masks outside
the repository. Inventory shortcuts wait for live native category ownership
and use the validated category refresh and native item setter below. Equipment
switches hold native Right/Left; L's optional long modes hold native Up, with
release or explicit Cancel. Tap equipment selection releases only after native
input has consumed the final selection sample. Hiding D-pad leaves touch mode
active while bypassing only `N_MainAll_00` translation/scaling, so a fresh
native matrix restores the authored loadout position and size.

Cancel is independently removable and can be restored through Add button in
either layout bank. Its saved `CANCEL_ENABLED` flag also controls runtime hit
testing and artwork, while gameplay state decides when an added button appears.
Choosing sticky equipment/rune switching or R/ZR camera dragging adds Cancel
once. A later manual removal survives saving, reopening and layout import;
rendering or retaining the same action choice does not add it again.
When D-pad relocation is enabled, both frontends move the loadout target 14pt
upward before HUD normalization, independently of screen size and button scale.

### Magnesis directions with a hidden D-pad

Corrected after native reproduction (2026-11-03): the first implementation
looked for the combined vertical-direction glyph `E065`, which held-object
Magnesis does not use. The existing exact-build screen observer now requires
both rendered Push/Up (`E060`) and Pull/Down (`E061`) guides under
`SousaGuide_00/N_Align_00/Pa_Guide_*/N_InOut_00/T_Icon_00`, excluding each
private capture copy. A fresh gameplay
presentation temporarily enables only Up/Down in both touch frontends; menus,
quick switching and controller handoff retain their visibility rules. Ordinary
and compact layouts keep their saved hidden flag and native loadout position.
The same direction mask controls artwork and touch ownership, and leaving the
operation releases any held temporary direction. Native presentation and layout
checks cover hidden guides, stale frames, quick switching and both layout banks.
The initial iOS/Mac compilation checks pass; the UIKit gesture check compiles
but was not run. Current-checkout `scripts/run_mac.py --test --touch-preview`
with matching shaders reproduced the failure in a disposable save copy. The
user entered held-object Magnesis; live pane/text dumps established `E060` on
`Pa_Guide_03` and `E061` on `Pa_Guide_02`. Native regression checks now use that
observed pair and reject `E065`. Evidence is in
`01007EF00011E000-work/magnesis-grab-20261103/`. The running test window remains
open on the pre-fix binary as requested; updated gameplay and physical iPhone
acceptance remain pending.

**Quick-strip touch correction (2026-11-03).** MainShortCut's horizontal
widget is independent of the focused BoxCursor menu entries. Routing every
quick-strip finger through the generic menu pointer intercepted the working
right-stick drag and left taps without a selectable native menu owner. Touch
now retains the camera/stick drag route. A tap resolves the visible item's
native widget descriptor and calls the existing immediate page setter on the
widget's own update callback, including gameplay frames without cursor updates.
These HUD descriptors have no BoxCursor entry: their UniteButton owns the
`B_Hit_00` pane at `+0x58`. The exact-build `main+0xe2785c` selection callback
also resolves the chosen slot through `screen+0x3884` into the current item/rune
at `+0x387c` and refreshes its description. Moving the list alone leaves that
selection stale and would accept the previously equipped item on close.
The next UI frame acknowledges the selected page before releasing the opening
direction, accepting the item and closing the strip without B. A still-held
virtual direction stays suppressed until release. Empty/hidden cells remain
inert. Quick-strip presentation includes entering/exiting animation, and a
touch opening hold immediately suppresses the missing-loadout D-pad fallback.
The round Cancel default moves down 50pt; right-button scope double-tap
protection now extends to a fixed 100pt radius while retaining camera dragging.
Mac acceptance used current-checkout `scripts/run_mac.py --test --touch-preview`
and an independent outdoors save: a weapon tap equipped Spiked Boko Club and
closed the strip; reopening retained the new equipment. A Camera-to-Cryonis
tap likewise closed the rune strip and reopening retained Cryonis. Native
menu/action/geometry checks and the iOS production import/compilation checks
pass. Physical iPhone gesture acceptance remains pending. Captures and logs
are in `01007EF00011E000-work/quick-repair-20261103/` outside the repository.


Touch category selection uses the native completion paths, rather than
intermediate stick navigation. Compendium's five-category widget calls
`main+0xd6bfa0(widget, 0, category, 1)`; mode 1 synchronizes its current/target
position and first selection. The ordinary `0xd6c244` wrapper always requests
animated mode 0. Quest/Sell keep their existing setter.

Inventory runs the game's own category change: both page fields move to the
category's first page, the three item lists are re-laid out through `0xe3af74`
and the current category follows through `0xe3b20c`. The native item setter
(`0xe3dd14(screen, 0)`) then selects the first item and refreshes its card through
the native focus callback.
The native activation body (`0xe39c08(screen, 0)`) also refreshes button
eligibility after relayout; see the [category sequence](../../../../docs/botw/touch-internals.md#the-fix).

**Resolved on Mac; physical iPhone acceptance pending: item actions stayed on the previous category (2026-11-03).**
Tapping a category and then an item showed the previous category's action (Eat
on a weapon). The host had staged the pending page alone and committed through
`0xe3b9f0`, which forces `screen+0x3a30` to the middle slot. The visible page's
item ids depend on that slot. Updating the grid alone also leaves the item card
and its actions stale when the page reuses the focused entry. The switch now
preserves the carousel slot and immediately resolves native selection for the
new page. The internals, including a rejected shared-fallback-object write, are in
[the touch internals page](../../../../docs/botw/touch-internals.md). Exact
1.9.0 build and instruction checks cover these native contracts.

Mac acceptance used current-checkout `scripts/run_mac.py --test --touch-preview`
with matching shaders and a copied outdoors save. Food → Bows and Arrows showed
Soldier's Bow with **Equip / Drop / Cancel**; returning to Food showed Simmered
Fruit with **Eat / Recipe / Cancel**. Both item cards followed their grid selection,
and category jumps remained immediate. Evidence:
`01007EF00011E000-work/category-item-fix-20261103/final/` (`game.log`,
`09-weapon-popup.png`, `11-return-food-popup.png`). Native menu tests and the 40
focused documentation/profile/tool tests pass. The BOTW-only regression harness
stopped before comparison: this Mac has Metal `32023.883`, while the chain lock
requires `32023.922.4`. C lint also has LLVM 19.1.2 rather than the baseline's
23.1.4; Python lint reports no new findings, with four existing baseline entries
now absent. These are not clean full-regression or lint passes.

**Implemented and checked on Mac; physical iPhone acceptance pending: equipment taps (2026-11-03).**
In the backpack, a short tap equips swords, bows, arrows and shields directly.
A stationary hold reaching 150 ms requests the game's normal item menu while
the finger remains down; lifting afterward does not select a popup row or
equip again. Already-equipped items remain equipped. Other item types keep
their normal short-tap menu. The implementation uses the native Equip action,
with item identity and availability checks, on the guest UI thread. Native
entry points and item offsets are checked against the registered 1.9.0 build.
See [equipment taps and timing](../../../../docs/botw/touch-internals.md#equipment-taps-and-the-150-ms-item-menu)
for the native contracts and cancellation rules.

The current-checkout Mac test used matching shaders and a disposable outdoors
save. Weapon, bow and shield taps equipped the selected item; holding opened
their normal Equip/Remove, Drop and Cancel menu, which remained after release.
Removing the shield through that menu and tapping it again verified a real
unequipped-to-equipped transition. Food still opened Eat, Recipe and Cancel.
Arrow taps selected the correct native item after repeated Food/Shield/Bow
category changes. This route also exposed and resolved stale button eligibility
after changing categories; the native category sequence above restores it.
The supplied save contains only one already-equipped arrow stack: its unchanged
equipment state and native A behavior were checked live; equipping a different
arrow stack is covered by native tests and instruction analysis, not this save.
The game ignores A on an already-equipped arrow stack, so its long press retains
that behavior. Evidence: `01007EF00011E000-work/inventory-equip-20261103/final/`
(`acceptance.txt`, `game.log`, native item dumps and numbered screenshots).
Native menu/action tests, 157 HID checks and 40 focused Python tests pass.
The compiler limitations listed above still apply; the run also retains the
existing `c1_full.tsv` cache warning.

**Resolved on Mac; physical iPhone acceptance pending: category taps sorted the inventory (2026-11-03).**
The previous category path called the game's Sort routine under the mistaken
name "selection resolver". A current-main Mac reproduction showed the sorted
notification on each Shield/Food/Bow switch, and native probes confirmed the
sort and notification calls. Category taps now use the native item setter to
select the first row and refresh its native focus callback while keeping the
category's item order. The original game's manual Sort path remains intact.
The [touch internals](../../../../docs/botw/touch-internals.md#how-the-game-selects-an-item)
record the corrected contracts and the reason the earlier classification was
wrong. Evidence is in `01007EF00011E000-work/category-no-sort-20261103/`.

The current-checkout Mac test used matching shaders and a copied outdoors save.
Ten changes among Weapons, Bows and Arrows, Shields and Food added no calls to
Sort, the category sorter or the sorted notification. Pressing Y once added
exactly one call to each; further category changes left those counts unchanged.
The first item and its card matched every category, including a switch from
the second bow to Food. Food's Eat/Recipe/Cancel menu, bow and shield short-tap
equip, shield Remove followed by re-equip, the held menu after finger-up and
arrow selection all passed. The final screenshots, native item dumps and
`category-results.json` are in `after/`; `before/` retains the reproduction.
Native menu/action tests, 157 HID checks and 40 focused Python tests pass.
The BOTW-only regression still stops before comparison at the Metal compiler
mismatch above. C lint retains the existing LLVM-version findings; Python lint
also reports the existing main-branch optional-value check in
`dm/games/settings.py:134`. Neither is a clean full-lint pass.

Compendium category touch cells share inventory's expansion around the native
glyphs, capped by neighboring category centers and the item-list clip. The native
pane identities and immediate setter remain unchanged. BOTW's default shoulder
positions are exchanged: ZR takes the former inward R position, and R takes the
former outer ZR position. The shared geometry, C defaults and launcher defaults
agree for Mac, UIKit and the editor preview. Focused menu/geometry checks and
18 launcher settings/storage tests pass; physical iPhone acceptance is pending.

BOTW face-button touch ownership uses the individual button circles and enabled
corner badges. The old whole-cluster grab circle captured blank space below Y
as a face-button gesture with no pressed button, preventing camera drag from
starting there. Ordinary gameplay now shares the per-button capture already
used by Camera and Scope. The left-stick ownership check uses the same button
hit eligibility, and the Mac preview shares the fix. Other games retain their
existing cluster behavior; button sizes and sliding behavior are unchanged.

**Resolved: landscape movement gap between L and the equipment cross (2026-10-31).**
Movement touch-down only considered the stick's home grab circle; the existing
lower-left area predicate was unused. Blank points between L and the D-pad fell
through as game touchscreen input, so dragging them produced no movement axes.
UIKit and the Mac preview now let unclaimed space in the lower-left third of
the control area start the floating movement stick. Buttons, the D-pad, the
shield grab region, map taps and native camera/scope targets retain ownership;
an already held movement stick cannot be replaced by another finger.
The UIKit regression covers four points in the gap, drag/release axes and L/D-pad
priority. All new checks pass; the full harness retains three pre-existing
portrait-layout assertion failures. The BOTW-only full game regression stops
before translation because the pinned x86_64 translator cannot load the local
arm64 .NET runtime; no game boot was tested. Physical iPhone acceptance remains pending.

R3 Scope owns a guide bar inside `MainScreen_00`, under
`Pa_CameraPointer_00`, rather than an independent menu screen. Its visible
capture-backed guide plates and native glyphs supply Place pin, Quit and Edit
pins targets. Only those rectangles request pointer ownership alongside the
gamepad; visible controls retain priority and free space keeps ordinary
relative look and R3 double-tap. Hiding the guide bar invalidates pending
actions even when the HUD root and input group remain unchanged.

New-item cards pair `T_PauseGuide_00` with `T_Icon_00`. Their native `0xe04b`
glyph maps to Plus, so the Inventory hint takes precedence over the broader A
continuation area. Card body/arrow taps still send A. Hidden/stale guides and
private capture copies remain ineligible. These adapters require BOTW touch
mode and the validated native owner; controller input is unchanged.

Validation and evidence for this follow-up are recorded in the
[acceptance tracker](../../../../docs/botw/touch-progress.md#category-jumps-and-gameplay-prompts-2026-10-31).


#### Relative camera look

`DM_LOOK_TRACE=1` logs the relative sample injected into BOTW 1.9.0's shared post-filter right-stick vector. The startup line reports whether the build-gated getter observer was installed. The trace confirms the host supplied an input vector; screenshots or game-state changes are still needed to prove the game consumed it.

BOTW relative-look input also accepts `look <phase> <dx> <dy>` through `DM_CTL`: phase 0 begins, 1 moves, 2 ends and 3 cancels; deltas are normalized camera motion.

**Experimental: continuous touch/gyro aiming composition (2026-11-04).**
The host continues publishing six-axis samples during a drag. In build
`cd57b23fa4bbad65803d9788c01821ee`, CameraAiming's getter call at
`main+0xbf0a40` and CameraAiming2's at `main+0xbf2af4` are followed by exact
zero checks on both processed stick components. Nonzero input clears the
tracker-use flag (`+0x369` / `+0x388`) and calls `main+0xd02c68` to deactivate
and reset the orientation tracker. The next eligible zero-input frame calls
`main+0xd02cb0`, initializing reference matrices from the current sensor
orientation. Repeated changes between drag impulses and zero-input frames can
therefore interrupt this tracker and repeatedly establish a new reference.
The complete aiming functions and reset/initialization stores were checked in
the original instructions and decompiled. This applies to physical stick and
touch input alike; it does not establish a touch-only defect or prove that all
native gyro paths are disabled. It is a candidate explanation for the reported
constrained feel; concurrent physical inputs still need device acceptance.

This experiment matches the exact getter return PCs and action vtables, in
addition to the existing frozen HID source proof. A relative touch call
returns zero to that decision while retaining the frame's displacement for
later composition. Physical, ordinary virtual and unknown sources keep their
native results.

Two pitch gates add displacement to the native target and smoothing base;
two final yaw gates shift both the persistent target and current output.
Gyro calculations run before these additions, tracker matrices are untouched,
and the native pitch bounds still apply. Axis consumption is per camera and
frame; END keeps its final sample and CANCEL clears deferred movement too.
Ordinary scene look and MagneForce object input retain the shared-vector path.
The experimental angular gain is 180 degrees per normalized short edge, as in
the earlier direct aiming adapter; the exact sensitivity may differ from the
current native stick response. `DM_LOOK_GYRO_COMPOSE=0` disables composition for
comparison; `DM_LOOK_TRACE=1` reports `look: compose` updates. Rebuild the host
and rewrite main; these changes are restricted to the exact 1.9.0 build.

Targeted host tests cover retained native motion results, unchanged tracker
matrices, 30/60 fps ratios, per-axis single consumption, cancellation and
physical-stick passthrough (91 look checks; motion/HID and observer checks
also pass). A full current-source rewrite and Mac test-mode build succeeded.
In-game Magnesis aiming reached CameraAiming2's new gates: a normalized drag
of `(0.02, -0.015)` produced `-3.6` degrees yaw and `-2.7` degrees pitch,
with both `look: compose` callbacks in frame 13903. This verifies the live
route and touch addition, not simultaneous physical sensor input. Physical
iOS aiming feel remains unverified.

**Current: iPhone shoulder-drag pitch jump (2026-11-05; device acceptance pending).** The reported
downward step happens near the first movement of R or ZR in drag-camera mode,
including horizontal drags with the motion source off. Releasing the bow can
produce an upward step. Switching ZR to drag-cancel avoids it; the same report
was not reproduced on Mac. This does not establish a gyro-reference fault.
A current-checkout Mac test also retained continuous aiming pitch for injected
relative displacement; it does not reproduce UIKit touch delivery or establish
the cause on an iPhone. Its isolated save had no arrows, so firing was not
validated.

`DM_LOOK_TRACE=1` now records UIKit BEGIN/MOVE/END/CANCEL coordinates, the
previous point, normalized displacement, canvas scale and previously published
virtual axes. The shared-getter trace includes both native and substituted
vectors and the matched aiming camera; the pitch gate records its incoming
target, smoothing base, bounds and accepted touch contribution even when that
contribution is zero. Capture a short R/ZR reproduction in `Documents/log.txt`
with this switch in `Documents/env.txt`. These diagnostics distinguish an
unexpected UIKit vertical delta, a native-vector passthrough after a source
mismatch, and a native pitch change with no touch contribution.

An iPhone trace from `03a95cfb` with `DM_MOTION_SOURCE=off` contains four
shoulder holds with maximum touch displacement of 5.70, 8.90, 9.80 and
10.14 pt. The first hold's first MOVE shifts down 5 pt, producing a
2.142857-degree pitch step at frame 716. Its release-only location shifts up
1.667 pt and contributes -0.714286 degrees at frame 752. All 419 recorded
aiming pitch targets equal the preceding target plus its accepted touch
contribution to within 0.000001 degrees; aiming calls with relative input
match their frozen source. This capture establishes that small reported
touch displacements enter camera motion directly, including on button release;
it does not distinguish finger roll from UIKit touch processing.

Free-space and R/ZR camera dragging now recognize a drag using the existing
12 pt tap slop. A shoulder button still presses immediately. Initial movement inside that radius
does not turn the camera; the crossing sample contributes only travel beyond
the radius, then subsequent movement retains its full displacement. Camera
END retains queued movement from MOVE events but does not turn its lifting
contact location into an extra MOVE. Its final location still rejects a tap
when it exceeds the slop, so a release-only displacement cannot become a
scope double tap. Quick-strip scrolling retains its full initial movement
and final location. Native gyro composition is unchanged.

The UIKit input harness replays the recorded drift and intentional drags for
both shoulders and free-space look, plus scope taps and quick-strip scrolling.
The 12 new failing assertions on the original shoulder implementation pass
with the fix; its ten pre-existing artwork/scope-tap failures remain unchanged.
The iPhoneOS source syntax check passes. Real iPhone feel and simultaneous
motion input still require device acceptance.

#### AppCamera touch gestures

In BOTW touch mode, drag with one finger to frame the shot and pinch to zoom.
The viewfinder also shows the virtual gamepad. A touch on a visible control
belongs to that control; the remaining area retains camera gestures and native
footer actions. Face-button priority uses the individual button circles in
this mode, so their wider gameplay grab region does not cover the native hints.
The same-owner Save/Delete confirmation hides the pad and releases its input;
discarding or completing the confirmation restores it in the viewfinder.
In selfie mode, move two fingers together to change Link's pose without changing
zoom. On Mac, use Option-drag or Shift plus a two-finger trackpad scroll for the
pose gesture. Hold a third finger during an iOS pose gesture to add the native
ZL modifier; on Mac, hold Shift during Option-drag or Option during Shift-scroll.
The native X prompt switches between selfie and landscape modes.

**Resolved: AppCamera drag barely moved (2026-10-30).** Framing converted each
pointer delta into native stick tilt, so the game's nonlinear stick response
reduced a 2.56-pixel move to `0.00056`. It now uses the existing relative-look
entry after that response curve; the same small move supplies `0.14222` in the
Mac diagnostic. Normal release retains its final displacement; cancellation,
pinch promotion and an owner/modal change clear the camera-owned look queue.
`DM_LOOK=0` keeps the native-stick fallback. Zoom and selfie pose retain their
native controls.

The Mac test verifies horizontal, vertical and reverse drags with the pad visible,
small repeated moves, and exiting/re-entering the camera. It uses retained
graphics and current camera-input code with only the observation-API compatibility
rename; hashes, traces and screenshots are in
`camera-drag-regression-1793361366/` in the game's work folder. Native menu tests
and all 74 look checks pass; iOS compiles all 188 files. Physical iPhone acceptance
is pending. The BOTW-only `regress.py check --games 01007EF00011E000 --quick`
report in that folder stops at the existing Metal compiler mismatch before game
comparison; the retained-graphics test does not validate a rebuilt shader chain.

**Resolved: Album edge swipes were ignored (2026-10-30).** Carousel gestures
required both their start and release inside the photo. A leftward swipe from
the left side, or a rightward swipe from the right side, could leave the photo
and fail. The shared BOTW carousel path now retains ownership after an in-bounds
start; release may leave the clip. Outside-origin gestures, cancellation and
disabled native arrows remain rejected. A disposable saved-photo run reproduces
the old misses and verifies photo 2 to 3 and back with both edge gestures.
`ui-implementation-20261030/album-regression-current/` retains the source proof,
before/after images and logs. The [acceptance tracker](../../../../docs/botw/touch-progress.md)
records the checks and retained-graphics boundary.

BOTW R/ZR touch feedback occurs on press and cancel-circle boundary crossings.
Releasing inside or outside the circle adds no UI haptic; native cancellation
still occurs only on outside release. UIKit's feedback spy checks these edges,
camera control/gesture coexistence and physical-controller suppression.
