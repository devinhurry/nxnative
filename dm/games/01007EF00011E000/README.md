# The Legend of Zelda: Breath of the Wild (`01007EF00011E000`)

Update 1.9.0 (v1114112) over the base game, SDK 20.5.22. Nintendo EPD's engine (sead / agl / gsys / ksys, NintendoWare G3d / Ui2d / Vfx / Atk, Havok) on NVN. Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`; `subsdk0` and `sdk` are the builds Tears of the Kingdom 1.4.3 runs ([0100F2C0115B6000](../0100F2C0115B6000/README.md)). Plays on the iPhone; 60 fps (30 on the Switch) through the host's frame step. The README lists its IPA at about 16 GB.

## What it needs

Resolved: rewriting the UI-camera observation at `main+0xd44a2c` after
`blr x8` was rejected by the generic post-call classifier. See
[Observation gates where x9-x17 are dead](../../../docs/reference/rewriter.md#observation-gates-where-x9x17-are-dead).
The real `main`, `subsdk0` and `sdk` rewrite and cache-freshness check passed
on 2026-10-27; the subsequent full Mac shader/host build reaches gameplay.

BOTW touch-menu coverage and remaining runtime validation are tracked in
[Menu touch progress](../../../docs/botw-menu-touch-progress.md). The
[resource inventory and semantic regression workflow](../../../docs/botw-ui-coverage.md)
adds a generated gap report; resource existence and screen recognition alone do
not establish touch acceptance. The resource census includes both installed
DLCs; their files add no BFLYT layouts or BFLAN animations.

[Touch implementation checklist](../../../docs/botw-touch-implementation.md)
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
restore the ordinary artwork. The seven `touch_*.png` assets are packaged beside the profile
tables. ZL shows a shield and four directional arrows without an idle background;
holding reveals an unfilled ring and dragging moves a direction arrow just outside its
perimeter while the center stays at touch-down. Mac and UIKit share the vector
paths from [zelda-hyrule-ui](https://chaos-xxl.github.io/zelda-hyrule-ui/#/docs).
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
visible Plus cross has the same right-edge padding as the first heart's left
edge, including the additional 2 frontend points. Both +/- use a white cross over a 40%-opaque black
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
The iOS and packaged Mac launchers offer a separate [Touch settings](../../../docs/settings.md#touch-left-stick)
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

The 2026-10-29 touch defaults use the supplied layout offsets and scales in
`settings.tsv` and `botw_touch_layout.h`; runtime, preview and Restore defaults
agree. Existing saved customization is retained. The current minimap/environment
cluster and fixed +/- anchor use the symmetric heart/Plus padding described above.
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
The separate [ordinary-stick/relative-look source fix](../../../docs/reference/services.md#ordinary-virtual-sticks-while-relative-look-is-enabled)
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

The top heart group keeps its authored corner padding against the full game
view. Landscape's horizontal safe inset, intended for the notch at mid-height,
no longer adds an extra gap to those topmost hearts; map and button safe-area
geometry now follows the right-edge rule below. Physical iPhone edge placement remains for acceptance.

**Right HUD edge padding (2026-10-30).** The minimap/environment cluster and
adjacent +/- controls use the game's authored right-corner padding against the
actual game picture. Landscape's extra right safe inset is no longer added on
top of that padding; it previously left another notch-width gap beside Plus on
iPhone. This is display geometry, independent of touch/controller input. The
map-to-Plus gap, fixed Plus position when the map is hidden, button size and
shared drawing/hit geometry are unchanged. Explicit aspect-ratio bars still
bound the HUD to the game picture. Native tests cover both landscape safe-inset
arrangements and both input modes; 160 graphics checks pass. Evidence is in
`touch-top-right-inset-20261030/`; physical iPhone appearance remains pending.

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

| Setting | Where | Why |
|---|---|---|
| Frame step, `fps_target 60` | [`patches.py`](patches.py) `FRAME_STEP` (`main` `cd57b23f…`), [`game.tsv`](game.tsv) | 60 fps at normal speed; see [Frame rate](#frame-rate) |
| Interval controller floor 2 → 1 (five cuts) and GPU-time path (two cuts) | `patches.py` `CUTS` | the game's own controller at `DM_FPS_TARGET=0` and while its VFR override holds; see [The game's own interval controller](#the-games-own-interval-controller) |
| Render scale stubs | `patches.py` `frame_step` (`main+0x1266880`, `main+0x126686c`) | `DM_RENDER_SCALE`; see [Render scale](#render-scale) |
| `gpu_timestamps segment` | `game.tsv` | the interval controller and the dynamic resolution read the GPU time between the frame's two timestamp reports |
| Integer output rows `8e2cc2671cae6020`, `93aa5e22a8202409` | [`shader_facts_manual.tsv`](shader_facts_manual.tsv) | agl's BC4 block encoder (3D and 2D source) writes `uint`; no PC version gives output types |
| `pad_layout full` | `game.tsv` | the 3D gamepad layout: the right stick turns the camera |
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | no system resource in the NPDM: the game uses `SetHeapSize`. 13 Sentinels' partition (256 MB in front + 256 MB alias + 256 MB stack + 3.25 GB heap) |
| Node area cut 1 GB → 62 MB | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `574284b4…` | made for Tears of the Kingdom's issue #70 on the same `sdk` build; the SDK-wide rule gives it |

No `tex_flush_upload` (a minute's boot saw it flush 32 CPU-filled textures with data, and it needs none).

### Direct categories and gameplay HUD prompts

Touch category selection uses the native completion paths, rather than
intermediate stick navigation. Compendium's five-category widget calls
`main+0xd6bfa0(widget, 0, category, 1)`; mode 1 synchronizes its current/target
position and first selection. The ordinary `0xd6c244` wrapper always requests
animated mode 0. Inventory stages the destination page, requests and refreshes
the category, stages slot zero after refresh preserves the old cursor column,
then commits through `0xe3b9f0` last. Refreshing after commit restarted a
transition and disabled focus. Exact 1.9.0 build and instruction checks cover
these native contracts; Quest/Sell keep their existing setter.

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
[acceptance tracker](../../../docs/botw-menu-touch-progress.md#category-jumps-and-gameplay-prompts-2026-10-31).

## Frame rate

### The frame step (current)

- **60 fps at normal speed (30 on the Switch).** The game steps its time by the frame interval its framework picks (`ksys::VFR`: interval / 2 of a 30 fps tick). With the profile's `fps_target` (60) the host picks it instead, in whole vsyncs (`FRAME_STEP` in `patches.py`, `hle_nvn.c` `fstep_tick`, `nvn_fstep.h`, the same frame step as Tears of the Kingdom's): a stub at the framework's `setWaitVsyncInterval` hands the game the host's step once a frame, and the host keeps each frame on screen that many vsyncs.
- It holds 1 (60 fps). Three late frames in a row (the frame or its GPU work more than 1.7 ms over) step up to the cost, 2 (30 fps) as a rule: no 40 fps on 120 Hz screens. 30 frames that would fit the shorter hold try it again, and each failed try doubles the wait before the next (1 → 8 s). After a hitch, a cost at 30 like the one that held 60 tries it too (probes, below).
- Real time lost to a late frame or a hitch is paid back one vsync per frame (at most 15; the rest of a long load is dropped), so game time = real time. The log line `frame step: game time 30.00 s in 30.00 s (1.000 of real time)` checks it every 1,800 presents, with the frames held 1 / 2 / 3 vsyncs, late frames, paid-back vsyncs and hold changes.
- **Resolved: movies at twice their speed at 60 fps (issue #636).** The game's movie player takes one picture per frame (34 s of its 30 fps movie in about 1,250 presents). While the host's movie decoder hands out pictures, the frame step holds 30: [Movies hold 30 fps under the frame step](../../../docs/reference/frame-rate.md#movies-hold-30-fps-under-the-frame-step).
- Scenes that fix the game's step themselves (the VFR's override: 2 at `main+0xc3b588` / `+0xc5ebf8`, 1 at `main+0xc609d8`) keep it, and the host holds frames that long (log line `the game fixes its own step`; not reached on the Mac yet).
- The stubs: `setWaitVsyncInterval` (`main+0x11269b8`, called once a frame at `main+0x11267c0`; the framework keeps the interval at fw+0x244, getter vtable +0x138, read by both callers of `VFR::updateInterval` and directly in 43 places, and passes it to `nvnWindowSetPresentInterval`) takes the host's step unless the VFR override (+0x29 flag, +0x2c interval) is set. `ksys::VFR::updateInterval` (`main+0x151d3d0`, x0 = the VFR at `[main+0x1e93890]`, called from `GameScene::calc` and the per-frame delegate `main+0x1280f80`) takes the framework's interval in the next frame (ratio = step / 2, base interval 2, and the int interval 16 pieces of logic read); its stub publishes the override at state +0x24 so the host holds frames that long. The step is not written into the VFR call itself, because the game presents on its own thread and the step can change between the two VFR calls of a frame.
- Mac (M4 Pro), from the title into the save's scene: 1.000 of real time at 60; with 12 ms added to every frame (`DM_TEST_PRESENT_LAG=1,12`) it drops to 30 and stays at 1.000. `DM_FPS_TARGET=30` holds 30 (saves power, also from `Documents/env.txt`); `0` runs the game's own interval controller.
- **Frame-step probes (iPhone).** The GPU clock follows the hold: on an iPhone the game went from 14.4 to about 25 ms of GPU time a frame at 30 fps with the same 4,900 draws, its CPU still on the performance cores, and never tried 60 again; a GPU time at the longer hold of at least 1.3 times its time at 60 that alone does not fit 60 (`nvn_fstep_gpu_slowed`) now allows probes. Stepped up by pipeline compiles after a cutscene, it took 12.8–15.2 ms of GPU time a frame at 30 fps (p50) where 60 had held for minutes, and stayed at 30 for 36 and 46 s until the player switched out and back (the same 4,900 draws took 5.8 ms right after a trip to the background and 13.5 ms half a minute later); a step up after 8 s or more at 60 now keeps that run's cost, and a cost at the longer hold of at most 1.1 times it allows a probe (`nvn_fstep_same`). Log lines: `frame step: hold 2 → 1 … (probe, …)`, `the probe held / failed`, `hold 1 held at 0.86`. Details: [development.md, Power](../../../docs/development.md#power).
- **Screens whose rate is not a multiple of 60 (from PR #27).** A cheap 50 ms frame shows 54.5 ms at 165 Hz; counted as late it kept the game at 20 fps for good, so the frame step lets a frame on time show one refresh longer than its hold (`shown_slack`, `nvn_fstep.h`).
- **Resolved: menu repeat twice as fast at 60 fps (2026-10-26).** `sead::ControllerBase::updateDerivativeParams_` (`main+0xeb0ef0`) adds a constant 1.0 (`main+0xeb0f78`..`88`) to each held button's count and repeats when `fmod(count - delay, pulse)` falls below that step, so delays and pulses were counted in frames: holding Down in the System menu for 0.3 s went 5 entries at 60 and 2 at 30 (found by MacNativeGames, `866beb9`). A `FRAME_STEP` stub at `main+0xeb0f88` takes the VFR's ratio (`+0x3c`, interval / 2) instead, keeping 1.0 when there is no VFR or the ratio is not positive. Mac, 60 fps: 0.2 / 0.3 / 0.4 s now move 1 / 2 / 3 entries, as the game does at 30. The pause menu's fast-repeat countdown (`main+0xe67d00`) already reads the VFR's delta.
- `DM_NVN_CUT` growing segments (64, 128, 256 … draws) were tried for fewer commits: the game fell from 60 to 30 fps in the same scene (GPU idle while the long last segments were encoded).

### The game's own interval controller

Used at `DM_FPS_TARGET=0` and for the interval the framework keeps while the VFR override holds. DM_FRAME_STEP=legacy, which ran this method on its own, was removed in 79d82f7b.

- `sead::GameFrameworkNx`'s main loop (`main+0x112660c`, framework +0x267 = 1) runs a dynamic interval: from the last frame's time it computes how many vsyncs were needed (rounded up), clamps that to [2, 3] (the maximum from the interval controller +0xc, built at `main+0x1126c04`), steps up after three overrunning frames and down one level every six frames, and sets the result through `setWaitVsyncInterval` (vtable +0x130, `main+0x11269b8`). `ksys::VFR` is initialized with a constant base interval of 2 (`main+0x127e740` → `VFR::init` `main+0x151d2d0`) and every frame `VFR::updateInterval` (`main+0x151d3d0`, called at `main+0xcf9ad4` / `main+0x1281044`) takes the framework's interval, a frame ratio of interval / 2. The game's time step follows its frame interval, so the speed is right at a steady 60, 30 or 20.
- Five cuts lift its floor from 2 to 1: the candidate floor (`main+0x112670c` `fmov s0,s11` → `fmov s0,s10`, `main+0x1126710` `cmp w27,#2` → `#1`), the step-down target recorded when stepping up (`main+0x112665c` `mov w24,#3` → `#2`, `main+0x1126748` `cmp w8,#3` → `#2`) and the step-down stop (`main+0x1126794` `cmp w9,#3` → `#2`). Probes confirmed it: interval 1 with ratio 0.5, and back to 2 with ratio 1 on a long frame. The zeldaret/botw decompilation (`VFR.cpp`) gave the semantics; 1.9.0's addresses were found by the constants (`60 / interval`, the `fmov s11, #2.0` floor).
- **Resolved: slow motion when the GPU is the bottleneck (GitHub issue #9).** The controller measured a frame as framework +0x250, the main thread's CPU span from the start of `procFrame` to before its draw step (`main+0x1126cec` → `main+0x1126d20`): about 2.7 ms in the shrine (probe at `main+0x11266a4`, `@x19+0x250`; "about 3 ms" in development.md). Only while the object at `[main+0x1e3a638] + 0x1d2b8` exists did it take max(CPU span, GPU time), in 64 of 6,046 shrine frames. An iPhone 16 Pro Max in handheld mode at a 25 ms frame p50 never left interval 1 in 4,800 frames: at 40 fps, about two thirds of the normal speed. The GPU time (framework +0x220) is the difference between the frame's two timestamp reports, `TIMESTAMP_TOP` at the start of its command buffer (`main+0xe94584`) and `TIMESTAMP` at its end (`main+0xe94664`), read after the draw step waited for the frame's fence (`main+0xe949bc`); it read 0–6 ticks, because the host wrote all 5 reports of the frame's one submission with one time. Two cuts (`main+0x112691c`, `main+0x1126974`: `cbz` → `b`) make the controller always take the GPU path, and `gpu_timestamps segment` gives each report the GPU start or end of its `sub_cut` segment (`rep_ticks` in `nvn_mtl.m`).
- Measured on the Mac with two runs sharing the GPU under a heavy CPU load (load average about 75): GPU time p50 16–23 ms; the fixed run stayed at interval 2 (3 while the GPU time passed 1.9 vsyncs, 1 for under 2% of the frames) at 0.93–0.98 of real time (Σ VFR ratio / 30 per wall second, probe `main+0x151d3e0` `@x0+0x30`: +0x30 ratio, +0x34 interval). A run with the old timestamps (`DM_NVN_GPU_TS=submission`) spent 10–70% of its frames at interval 1 and ran at 0.78–0.95.
- The same GPU time drives the dynamic resolution (`main+0x1267070`): a running average as a percentage of a 60 Hz frame scales the resolution down above 175% (29 ms) and back up below 150% (25 ms). With 0 it always sat at its maximum, and it still does whenever the game holds 30.
- **Resolved: Link's move pace speeding up when pressing B (iPhone).** Sprinting flaps between interval 1 and 2 for runs of 6 or more frames, and the VFR step at interval 2 is a whole 30 fps tick. The acquire waited one display-link tick per frame whatever the interval, so the game kept producing frames every 16.7 ms while the screen held each interval-2 frame for 33 ms and dropped the one between (`old frames dropped by merging`): those runs went at double speed. `mtl_link_wait_tick` now waits as many ticks as the present interval.

### Render scale

- `DM_RENDER_SCALE=0.5`–`1.0` (also from `Documents/env.txt`) fixes the 3D views at that fraction of 1600×900 docked (1280×720 handheld) and turns the game's dynamic resolution off; 1.0, the default, keeps it. Factors above 1.0 are refused by the loader (the per-frame texture pool's size is unknown).
- The dynamic-resolution method (`main+0x12666e4`) keeps its scale in s8 (0.8–1.0 in 0.05 steps, `+0x1218`, `main+0x1266818`, or the forced 0.75 / 0.5 of `+0x284 & 0x1800`) and applies it from `main+0x1266880`: the views' scale (`+0x28a0` / `+0x28a4` = s8 × base width (`+0x1214`: 1600 docked, 1280 handheld) / output width), from which the size function (`main+0x106340c`) sizes the scene buffers each frame, the shader ratio `uking_dynamic_resolution_ratio` and the other readers (`main+0xc3c3f4`, an LOD check at `main+0x14126b4`). That block runs only when the dynamic path has just recomputed the scale (`+0x280` bit 4, set at `main+0x1266830`) or in a forced mode, else `main+0x126686c` skips it. The stub sets s8 at the block and, for a factor other than 1.0, takes the block every frame. A multiply in the size function (Tears of the Kingdom's way) would leave the ratio and those readers at the old scale.
- At 0.5 the 1600×900 passes become 800×450 and the 800×450, 400×225, 200×112 and 100×56 chains halve too, while the shadow maps and the 1920×1080 output keep their size and the HUD stays sharp. It holds in handheld mode (960×540 at 0.75). On the Mac (M4 Pro) the GPU time does not change (about 13 ms in the first shrine at 1.0 and at 0.5): a frame has about 650 passes, most of them tiny. Whether it helps an iPhone, whose GPU loads and stores each pass's attachments, is what the setting is for.

### CPU

- **Resolved: CPU hitches (Mac).** In steady play, frames with 30–210 ms of CPU work came every 1–10 s (Zora's Domain, M2 Max): the main thread and the two workers spinning in one job queue poll (`main+0xef62dc`). The first item of some of its jobs is for the thread of core 0; the threads of cores 1 and 2 wait until it is taken (the queue's flag at +0x98, its cursor at +0x94), taking and releasing the queue's lock (+0x1c) on every pass. Polled at full speed by the two workers, the lock went back and forth between their cores, and the main thread lost nearly every exclusive store: in 40 s of a Time Profiler trace it never held the lock while each worker held it about 750 times, and the three spun for 30–210 ms at a time. The spin-wait rule's lock case takes that loop: the workers leave the lock a moment between passes. Zora's Domain on an M2 Max at 120 Hz (42 s of steady play, three runs each, before → after): standing still, frames over 30 ms of CPU work 2.8 / 6.3 / 3.5 → 0 per 30 s, the frame's work p99 20–21 → 8.3–8.4 ms, late frames 2.8 / 5.6 / 2.8 → 2.1 / 0.7 / 2.1 per 30 s; turning the camera, CPU hitches 11.9 / 13.3 / 6.3 → 0, p99 21–25 → 9–15 ms, late frames 12.6 / 13.3 / 7.7 → 1.4 each. Found with `DM_HITCH_DUMP` (the main thread and two workers in one guest loop with no SVC; x0 held the item index) and an `xctrace` Time Profiler trace.
- The spin-wait search takes 310 loops in `main` (308 before the lock and store rules; the new two are the job queue and a state setter at `main+0xf82230` that stores its state and returns on the second pass unless another thread changed it) and widens one in `subsdk0` (`0x27804`, the movie library's thread loop, 6 → 23 instructions). Rewriting `main` takes 26 s of CPU instead of 19.
- `PlacementMgr` and `RadarMgr` yield once per item of their batches (the back-off stretched a 94,263-item radar batch to about 30 s). A yield whose caller's x19–x28 moved now returns at once: outdoors on the Mac, CPU energy went from 0.35–0.74 to 0.21–0.34 W at 60 fps, CPU from 76–83% to 96–106% of a core, and the frame interval's p99 from 19 to 20–21 ms. A `sched_yield` on each of their 200,000 yields a second cost a third of a core more than the back-off had.
- **Address → memory pool lookups**: the game keeps about 1,760 memory pools alive, and `mtl_addr` / `mtl_gpu_addr` scanned them all for every buffer binding of every draw (about 1,000 samples of a submit-thread profile). Last hit, then a binary search (`pool_find`): host submit time in the shrine 21 → 7 ms a frame (p50), the median frame 38 → 21 ms.
- Upload staging blocks are reused: the game used to allocate, make resident and free a 32 MB block for each re-upload of a small CPU-written texture, about 3 GB/s.

## GPU work

- **Submissions in segments.** The game does not submit frame N+1 until frame N's GPU work is done: in the shrine the main thread sat in `nvnSyncWait` 59% of the time and the render thread in `nvnQueueSubmitCommands` 40%. That submit is the host's translation (about 3,600 draws and 347 passes, 7 ms), so the GPU ran 13–14 ms and then sat idle 7.7 ms a frame. The replay now commits every 64 draws between two passes (`sub_cut`, `DM_NVN_CUT`): GPU idle 7.7 → 3.8 ms, most of the rest the game's own work between its fence wait and the next submit (about 2.5 ms).
- **Shrine of Resurrection on the Mac (M4 Pro)**, after the above: docked (1600×900) GPU about 13 ms, frame p50 16.7 ms (60 fps; p90 17.6 ms), was 20.8 ms before segmenting; handheld (`DM_OPMODE=0`, 1280×720) GPU p50 9.3 ms and a steady 60. Host translation is 8 ms a frame (22,000 instructions per draw), spread over Metal's encoder creation and draw calls, argument encoding, retain / release and pool lookups. `DM_NVN_PASSGPU` is off under Metal 4, so GPU time cannot be attributed to passes. The frame loaded 376 MB and stored 432 MB of render-target data (325 of 347 passes load and store everything).
- **Outdoors (2026-10-21, the user's Great Plateau save, Mac M4 Pro).** A frame had about 386 render passes and loaded and stored about 900 MB of attachments (on an iPhone at 60 fps about 55 GB/s, near the memory's bandwidth). 220 passes ended only because the game updates the first 64 bytes of a 64 KB vertex uniform block (`0x70c38c0000`) before each draw group while its shaders read up to 544 bytes of it (the terrain pixel shader `eb0afe555b86da79` indexes the whole block). Partial-cover uniform shadows (`ubp_get`, `DM_NVN_UB_PARTIAL`) and `cb_extent.tsv` keep those passes open: 386 → about 165 passes, GPU p50 about 9.3 → 6.5 ms, submit 5.7 → 4.9 ms; `DM_NVN_UBP_CHECK=1` found every shadow equal to the GPU's memory (968,000 checked). Lazy clears fold the four clear-only passes before the G-buffer into its first pass (about 30 MB less a frame at 1600x900). The frame still loads and stores about 800 MB: the NintendoWare VFX GPU particles run one compute dispatch per emitter between draws (ten 800x450 half-resolution passes and two G-buffer passes, about 190 MB a frame; the G-buffer ones read the depth being drawn), and decals sample the G-buffer right after the game sets it again. Tried and dropped: `DM_NVN_TBDR=1` (10–15% fewer stores, more CPU, red ledger lines, deferred uniform updates off), `DM_NVN_BARRIER=game` (no gain), same-target continuation outside TBDR mode.
- **Cube map filter every tenth frame (current, resolved).** Every tenth frame starts by filtering the environment cube map: 132 one-draw passes into 64x64 to 8x8 faces (22 levels of 6 faces, `f8d9bbda1e0ebb0a` with `2ab186d450f5b32c` / `cfc85e532ccf8dd2`, game barrier `0x12` only between levels), so the G-buffer started 7–9 ms into that frame instead of 1.5 ms and the frame took about 5 ms more GPU time: the regular spike in the Metal HUD's frame-time line. The faces of a level now run as one layered pass ([passes into other layers of one texture level](../../../docs/reference/rendering.md#passes-into-other-layers-of-one-texture-level-run-as-one-layered-pass)): 284 → 173 passes in that frame; Zora's Domain at 900p, FPS 120 (M2 Max), frame p50 10.51 → 10.23 ms, p95 13.16 → 11.11 ms, mean window max 15.6 → 12.1 ms, GPU p95 13.0 → 8.7 ms, 95 → 98 fps.
- **Particle dispatches between effect draws (resolved).** The NintendoWare VFX GPU particles' one dispatch per emitter ended the G-buffer's and the half-resolution passes' effect draws into about 20 extra passes and compute encoders a frame. They now run ahead of the pass ([compute dispatches between the draws of a pass run ahead of it](../../../docs/reference/rendering.md#compute-dispatches-between-the-draws-of-a-pass-run-ahead-of-it)): 28 → 8 compute encoders, 149 → 132 render passes; same scene and switches as the cube map filter above, frame p50 9.92 → 8.97 ms, p95 10.70 → 9.98 ms, GPU p50 7.69 → 6.70 ms, 101 → 111 fps.
- Same-pass feedback: over a thousand draws a frame sample the G-buffer of their own pass (`4d3d5a4408c2e8d9`, `753d0169ae3ce4f0` and others on the 1600×900 G-buffer), and outdoors about 460 of them also write the target they sample (decals reading and blending the normals). A fresh snapshot for each (`DM_NVN_FB_SNAP=all`) takes the Mac's GPU time from about 4 to 28 ms a frame; none has shown magenta blocks on the iPhone so far. The host now snapshots only draws that write what they sample and reuses a snapshot until the game's next barrier: about ten snapshots a frame, each reused by about 50 draws, GPU time within the runs' noise of no snapshots (3.7–4.5 against 3.5–4.1 ms p50, four runs each on the Apple M6). See [Same-pass feedback read through a snapshot](../../../docs/reference/rendering.md#same-pass-feedback-read-through-a-snapshot).

- **Shrines at 20–27 fps (GitHub issues #534 and #598; current, the fix not yet seen in a shrine).** The reporters' shrines (Oman Au on a MacBook Air M2; every shrine on an M3) run at 20–27 fps where the open world holds 60. In the #598 log the slow stretches have about 1,000 draws a frame, as the fast ones, but a GPU time of about 36 ms against 9–13 ms. They have about 240 `passes ended to land them for a read` a frame, all `refused … other GPU writes`, and 280–330 `load-all store-all passes` against about 100. The probe on the Shrine of Resurrection save found the one write behind that refusal there: the GPU particle dispatch `9f8116baffddaf81` binds its three outputs with size 0, which counted as a write anywhere ([A storage buffer bound with size 0 counted as a write anywhere](../../../docs/reference/rendering.md#a-storage-buffer-bound-with-size-0-counted-as-a-write-anywhere)). With the fix, that save's world-load burst (1,200 refusals) is gone. Opening Oman Au's final gate ends the slowdown even out of view (#534): an emitter that stops with the gate would fit, but no shrine save was here to show it.
- **Present snapshots (Mac).** The game's two swapchain textures held its CPU work to display ticks and the GPU at 444 MHz on an M2 Max ([present snapshots](../../../docs/reference/frame-rate.md#present-snapshots-the-games-swapchain-texture-free-at-once)). Judged by cost, the frame step stepped to 30 at a GPU time of 0.75 vsyncs. Zora's Domain from a Cemu save (120 Hz), frames on screen longer than 1/60 s by a quarter: 64 of 8,684 with neither, 41 with the GPU filler alone, 4 of 10,800 with snapshots alone (no step to 30 in 3 minutes, at 444 MHz throughout).

## Rendering

**Native widescreen UI backgrounds (2026-10-28).** Widescreen is independent of touch/controller mode. Menu foreground content and touch coordinates retain the centered 16:9 layout; full-width native background Pictures and Windows extend to the display edges. Windows retain their own corner sizes, and title illustrations use proportional cover sizing. Returning to 16:9 restores native dimensions without accumulating scale.

The former viewport squeeze also clipped backgrounds at the 16:9 boundary. The registered ui2d shaders now correct clip x in a replay-time copy of their projection/clip-offset uniforms (Maxwell c3/c13, NVN UBO slots 0/10), before clipping. Guest buffers and shader libraries are unchanged. Main's build-checked `Pane::DrawSelf` scope (OBS39/40, x21 pane) marks background draws; only those draws may keep a full-display scissor. Foreground scissors remain centered, so offscreen neighboring panels cannot leak into the side margins. The tag uses a reserved instance-count bit in host command records, preserving compact draw sizes and decoded instance counts. Rewrite main with the current profile before running a new host.

Validation: aspect/background restoration and menu/HUD regressions pass; 173 NVN recording checks and 147 graphics checks pass. Mac runtime evidence in `widescreen-ui-20261028/` uses the retained `371ad45` graphics base with this change and the shared menu adapter, shader chain `07b0ea547435`, and newly rewritten compatible modules. The current merged host also compiles; this feature's runtime evidence does not validate the complete merged shader chain. Physical iPhone and actual controller connection remain separate acceptance.

**Title background correction (2026-10-29).** `Title_00` also draws two pairs of gradient panels behind its menu. Their native origin is the right edge: the last `FBLayout_02/03` panels end at x=640, rather than extending beyond it. They now widen and move their right edge by the extra half-canvas width; their left seam stays at x=160. The left gradient panels, logo, menu and hit regions retain their native geometry. The exact title ancestry distinguishes these panels from other framebuffer pictures. Visible artwork and its light/blur pictures scale dimensions and position together, including the smaller arrow, horse and guardian pictures. The separate capture branch stays at native size; its displayed effect pictures receive the same layout correction as the visible artwork. This prevents a hard cut at the old left edge or a mismatched stretched glow. Resizing back to 16:9 restores the original width and position. Corrected UI uniform banks are value snapshots and must refresh for each draw; reusing an argument block that originally pointed at live uniforms can otherwise retain stale title artwork/opacity. Mac captures and logs are in `widescreen-title-20261029/`, with the same compatibility-runtime boundary described above.

- **Resolved: the 3D scene black, only particles and the HUD drawn.** The engine binds almost every texture with `nvnCommandBufferBindTexturesDeferred` (`main+0xec2e64`, one handle, the pointer being the handle field inside the texture-sampler object): the GPU reads the handle when the command executes, and the game records its command blocks once and writes the handles afterwards. The host copied them at recording, mostly zeros, so the deferred-lighting composite read the dummy texture 0. The bind record keeps the source address and replay refreshes the handles first (`bh_fresh`). Found with a data-flow table from `DM_NVN_PASSDUMP_ALL`: the composite's `B` lines were all `tid=0 dummy` (without `_ALL` only the first draw of each pass is listed).
- **Resolved: the same texture attached at two colour slots.** The G-buffer passes attach the albedo and another buffer twice each (c1 = c2, c3 = c4) with write mask 0 on the duplicates. On Apple's TBDR the later copy (loaded, never written) overwrote the other's writes, per 32×32 tile: the albedo held only scattered squares. A repeated slot is left unattached (`rt_dup_slot`).
- **Cube textures sampled as cube arrays**: 1,512 shaders sample the environment probes as `texturecube_array` with a single cube bound; NVN cube textures are now 6-layer 2D arrays bound through views (`tex_fit`).
- **Resolved: a compressed texture as a render target (GitHub issue #4, iPhone 14 Pro).** agl's BC4 block encoder (`8e2cc2671cae6020`) writes a 32×32 RGTC1 (BC4) texture through an `RGBA16UI` view (one texel per 8-byte block). Metal can neither attach a compressed format nor view one uncompressed, and pipeline validation aborted, so the draws did nothing. The pass now draws into an uncompressed shadow of blocks × blocks (`bcrt_attach` / `bcrt_flush`, from PR #11); its output is declared `uint` in `shader_facts_manual.tsv`, as is its 2D-source twin `93aa5e22a8202409`, whose failure showed up in an iPhone run. The A16 has no BC formats; the old decompression path (about 3.9 GB instead of 2.8 GB for this game, over iOS's limit on a 6 GB iPhone) has been removed.
- **Resolved: the sky brownish grey, the distant haze brown (GitHub issue #52, Mac and iPhone).** Each frame a pass (`08fe25061d583637`, `uking_pass_shader.sharcb`) turns a 256×32×16 RGBA16F 3D table of in-scattered light into a 256×256 sky map, which the sky draw (`8110c74078548172`) and the materials' aerial perspective sample. The table and two 2D ones (transmittance 256×64, irradiance 64×64) come from `System/KSys/sky.skybin` in `Pack/Bootup_Graphics.pack` (1,212,416 bytes). The game makes a `CPU_CACHED | GPU_CACHED` pool per texture, creates the textures, copies the data in with `memcpy` and flushes (`main+0x1257d50`, once; the flush goes through `main+0xebf4c4`). The host made the 3D table a GPU texture of zeros. `DM_NVN_TEXRAW=212,214` and `DM_NVN_TEXINFO=256x32` (`storage 1048576 bytes non-zero 781567`, `swizzled=0`) showed it. Every game now fills a texture from storage the game flushed before its first use (`nvn_flushed`, `tex_init_fill`; `DM_NVN_FLUSH_FILL=0` turns it off). In the Great Plateau save it fills that one texture; the flushes (about 15 a frame) merge into about 530 ranges, frame times unchanged.
- **Resolved: dark boxes and cream cloud rectangles behind HUD prompts, a black stamina wheel and a black System menu background (layout captures, GitHub PR #6).** Panes tagged `CaptureOn` (about 140 layouts, e.g. `PaGuideKeySmoke_00`; user data `A8`, `CaptureScale` 0.5, `MultiFilter`) are drawn, blurred at half size and copied into a capture texture that replaces the placeholder `FBLayout_00`. The game creates it with its per-format default mapping (`main+0xecb0bc`: R8 → (R, 0, 0, 1), RG8 → (R, G, 0, 1), …), then rebuilds it on the same storage with the capture's mapping: `main+0xf597dc` picks (1, 1, 1, R) for an `A8` capture and alpha 1 when the pane says `CaptureOutputAlpha` 255 (read at `main+0xf58e98`); `main+0xecacf0` stores the mapping and rebuilds (`main+0xecabe8`), and `main+0xec33f0` replaces the registered descriptor only if `nvnTextureCompare` reports a difference. The host ignored the mapping, so the captures kept (R, 0, 0, 1): hard-edged dark boxes (the shadow pane `e6a88e12dbae9743`) and cream cloud (the glow `aa209f57b133e862`). The earlier `alpha_from_red` workaround (all 26 layout pixel shaders, `main`'s BNSH at 0x1d83000; since removed from the host) fixed the alpha but zeroed green and blue (a black stamina wheel) and left the System menu black. `nvnTextureCompare` now compares the mapping (an unset mapping counting as (R, G, B, A)); checked on the Mac by the PR's author: green stamina, the purple noise meter, the blurred System menu.
- The game keeps NVN's GL depth mode. It has an `RG8_UI2F` vertex attribute (converted on the CPU, `vconv_i2f`). 101 compute and 4 vertex shaders read the driver segment `c0`; they render the same since compute `c0` carries the dispatch size.
- It finalizes its transient render targets before every submit and builds them again the next frame, which the storage-takeover rule guards with a 16-submission window (`alias_take_over`).
- Windowed on the Mac with `present_now`'s residency commit: its title, 60 fps, no GPU error.

**Gameplay edge HUD and loading fills (2026-10-29, resolved on Mac).** The native heart container moves toward the left display edge, preserving the spacing of full and partial hearts. The collapsed minimap and its sensor, noise, temperature, time and weather panes move together toward the right edge. Touch mode retains its upper-right map layout; ordinary input retains the lower-right layout. Hearts retain native padding against the full display; the map cluster uses its authored right-corner padding independently of input mode. Touch map bounds and the adjacent plus/minus buttons use the same HUD rectangle. Expanding the Slate restores its native centered position; returning to 16:9 restores all original positions without accumulating offsets. The HUD draw scope fixes [target-clamped scissors](../../../docs/reference/rendering.md#edge-anchored-ui-keeps-open-scissor-edges) without opening menu clips.

**Resolved: minimap disappeared in very wide windows (2026-10-29).**
The D-pad center is published relative to the centered 16:9 UI canvas. At 32:9,
its valid position beside that canvas has a negative normalized x. Rejecting
coordinates outside `[0,1]` disabled the entire touch HUD, restored the native
map placement and removed its touch target. Publication now accepts finite
coordinates outside that centered canvas; it still rejects nonfinite values.
That fixes touch-HUD activation; the separate native scissor rejection is fixed
by [anchoring the collapsed map after CPU clipping](../../../docs/reference/rendering.md#edge-anchored-ui-keeps-open-scissor-edges).
Native checks cover the negative D-pad position, valid map hits at 32:9 and
inactive restoration. Mac 3.6:1 gameplay verifies the complete touch minimap,
click-to-open Slate, Back and resizing to 16:9 and back. There are 178 passing
recording checks and 160 passing graphics checks, including safe-edge clips.
Evidence is in `ultrawide-minimap-20261029/`. Gameplay uses the retained graphics
base and matching shaders; the current merged host compiles separately.
Physical iPhone acceptance remains pending.

**Resolved: minimap blur flashed adjacent HUD after Inventory (2026-10-30).**
The return animation copies a 192x192 region of the UI framebuffer for its
blur. The collapsed map had moved at GPU replay for widescreen, but this
capture still sampled its old native rectangle, including temperature/noise
graphics. The copy shader `17dccd27ad609e8b` now receives a replay-time UV
snapshot following that same map projection. A recorded map draw must match
the current frame, source canvas and clipped source rectangle; full-frame,
unrelated-menu and 16:9 copies keep their original uniforms. Capture projection
also participates in the argument-cache identity, so an ordinary copy cannot
reuse its corrected snapshot. Guest uniforms and shader libraries are unchanged.
The before/after texture dumps locate the contamination before blur; eight
21:10 return frames show the corrected map. All 168 graphics checks pass,
including source-edge alignment and unchanged unrelated copies. Evidence is in
`minimap-album-compendium-20261030/` (`probe-contact.png`, `fixed-contact.png`).
Mac gameplay uses the retained compatible graphics base; the complete current
host compiles separately. Full regression preparation stops on the unchanged
HEAD baseline Metal compiler/lock mismatch. Physical iPhone remains unverified.

The loading screen's upper cream background is `P_Capture_00` under `N_LogoInOut_00`, a 1280x275 panel with an animated projected texture. Its complete native draw now stretches with the display, preserving texture/clip alignment throughout the wipe; see [Projected fullscreen fills](../../../docs/reference/rendering.md#projected-fullscreen-fills-keep-texture-and-clip-coordinates-together). Text, status icons and logo keep their proportions. The lower black background already uses the full-display background path. Both fill a wide display.

Validation: Mac 21:10 touch and ordinary-input gameplay, map expansion/return, edge-area map/plus taps, and resizing to 16:9 and back passed. Aspect/safe-area/restoration and touch-HUD checks pass, with 176 NVN recording checks, 155 graphics checks and zero UIKit handler failures. Evidence is in `widescreen-hud-loading-20261029/` in the NSP work folder. Runtime captures use the retained graphics base and shader chain described above; the current merged host compiles. `regress.py check --games 01007EF00011E000` stops before boot on the existing translator `xlate_source` lock mismatch, including its HEAD baseline. No shader-chain tools changed. Physical iPhone and an actual connected controller remain unverified.

### Upscaling (current)

Handheld, the game draws 1280x720 into its 1920x1080 window textures and crops the window to it. Docked it scales its 900p scene to 1080p with one draw and draws the HUD on the 1080p target. The optional [MetalFX present](../../../docs/reference/rendering.md#the-present-upscales-through-metalfx) scales that presented picture in either mode; it cannot recover detail lost in the game's own upscale.

Measurements reported in [PR #215](https://github.com/seedds/nxnative/pull/215), the present command buffer's GPU time:

| Device and content → output | MetalFX | Standard |
|---|---|---|
| M2 Max, handheld 1280x720 → 2560x1440, full screen | 0.74–1.32 ms | 0.07–0.11 ms |
| M2 Max, docked 1920x1080 → 2560x1440, full screen | 1.35 ms | 0.11 ms |
| M2 Max, 1280x720 → 2868x1320, offscreen | 0.40–1.17 ms | 0.04–0.07 ms |
| iPhone 17 Pro Max, docked 1920x1080 → 2346x1320 | p50 2.1–5.0 ms per 600 presents; p95 up to 6.1 ms | Not measured on that build |

On the Mac, frame times stayed at 60 fps; crop comparisons showed sharper edges on Link, his shield and the map text, with unchanged colours. The iPhone ran at 60 fps with the launcher setting reaching the host; a cold docked run reached thermal state serious after 226 s, a warm start after 64 s. The matching iPhone Standard run and MetalFX's share of the thermal cost remain unmeasured. Standard stays the default. These gameplay measurements are the PR author's; this integration has not repeated a device gameplay run.

## Memory

- **Resolved: the world-load crash (about 1 run in 3 on the Mac) came from the host's command record sizes.** About 3 s after Start, a task worker's `operator new` (`main+0x155a79c`) got null and the game wrote through it (`main+0x155a7a4`). Each model file gets a heap of its resource size table entry + 0x1008; the file goes in 4 KB aligned, and the model's setup (`main+0x155a2ac`) takes the rest as a frame heap (vtable `main+0x1d4f950`, head +0xe0, tail +0xe8). Part of the setup is GPU memory for the model's prerecorded commands, sized by recording each mesh's draw and each shape's state for each pass into a scratch command buffer and summing `nvnCommandBufferGetCommandMemoryUsed` (`main+0xf9aeb4`, `main+0xf9bb54`), so the host's record sizes count against the table. Draw records had grown to carry the indirect and multi-draw fields (0x38 → 0x50 per recorded draw on 2026-10-18 and 10-20), and every recording began with an 8-byte BEGIN record. `Obj_TreeConiferous`, `Obj_TreeBroadleaf_B` and `FldObj_HyliaBridge_A-02` then needed one 4 KB page more than their entries allow, which fit only when the file's alignment pad (0 to 0xff8) was small (about 15% of loads each failed; most models have about 0xd00 to spare). Plain draws now leave those fields out and recordings have no BEGIN (0x30 per recorded draw, `nvn_obj.h` `draw_rec`): all 510 models of the world load fit whatever the pad. To check a whole scene, probe where the setup heap is cut (`main+0x155a520` with `!x21`) and the end of the setup (`main+0x155a5f4` with `!x2`) with `DM_PROBE_HEAP=28,38,40,e0,f8 DM_PROBE_HEAPFRAME=1d4f950 DM_PROBE_HEAPWORDS=1`. A model fits any placement when entry + 0x1008 covers the resource heap's header and object (0x310), the file, the frame heap's block header and its peak use, plus 0xff8 of pad.
- **Resolved: the iPhone app was killed for memory in the first shrine (GitHub issue #9, iPhone 16 Pro Max, handheld).** An 8 GB iPhone gives the app about 3.4 GB (resident plus `headroom to the system memory limit` stayed at 3,375 MB). Resident memory grew about 0.2 MB a frame from 2.6 GB at the shrine load until the kill, with the residency set and texture counts flat. The deferred-release drain ran on the guest submit thread with no autorelease pool (`defer_drain` now has its own `@autoreleasepool`): on the Mac a host without it grew 1 MB a frame in the shrine (GPU 3.0 → 4.4 GB in 2,400 frames); with it the shrine stays at 2.7–2.9 GB resident and 1.5–1.7 GB GPU (vmmap at 2.8 GB: about 1.6 GB guest memory, 0.75 GB private textures, 0.17 GB IOAccelerator). Found on the way: about 10 serial-table entries a frame were never deleted (finalized transient targets replay resolved again; 276,000 after 25,000 frames), now in a 512-entry table (`tex_put`, `g_ghost`, `finalized textures still referenced`); and the memory-pool tracking table had 4,096 slots against 4,006 pools on the phone, now growing in blocks of 1,024 (`nvn_dirty.c`, up to 262,144).
- About 2.8 GB in the first shrine in handheld mode, idle or walking (Mac), against the 3.4 GB an 8 GB iPhone gives the app; the README says it comes close to that limit without the Increased Memory Limit capability.

## Audio

- **Resolved: crashes in `CommandListProcessor::Process` (SIGSEGV under `render_main`, at 60 s and 134 s in the shrine).** SDK 20's `AudioRenderSystem` has another layout (getters inlined, `GenerateCommand` takes and returns a `Span<std::byte>`, device and mode at +0x48 / +0x4c, command buffer at +0xf8 / +0x100, `UpdateImpl` locks +0x2d0; DeviceSink is command 0x14). The public `ExecuteAudioRendererRendering` (`sdk+0x221e90`) reaches `AudioRendererImpl::ExecuteAudioRendererRendering` (`sdk+0x22ca88`) through the vtable, so the host's takeover of the `Impl` function was never called: the SDK's own `AudioRenderSystem::ExecuteAudioRendererRendering` ran with no update lock, every `RequestUpdate` rendered a catch-up frame, and two threads wrote the same command buffer. The host now also takes over the PLT target; catch-ups fell from one per update to 3 per run.

## Services and loading

- **Resolved: every pointer in `.data` / the GOT a module offset, crashes everywhere.** SDK 20 packs relative relocations as `DT_RELR`: `main` has 223,994 of them (`relr_apply` in `loader.c`).
- **Resolved: SIGBUS inside Metal (`AGCDeserializedReply`) at a guest-stack address.** Ending a render pass inside `nvnQueueSubmitCommands` made the driver compile its fast-clear blit on the render thread's small stack; every implemented NVN function except the recording calls now runs on the 512 KB host stack (`nvn_big_entry`).
- SDK 20 calls it needed: `applet::GetAppletResourceUserId` (SDK 20's `OpenAudioRenderer` aborts on ARUID 0; the host reports 0x80), `pl::RequestSharedFontLoad`, `pl::IsVrMode` / `BeginVrMode` / `EndVrMode`, `pctl::CheckStereoVisionPermission` (not permitted: the options' Labo VR mode stays 2D), `oe::TryPopLaunchParameter` (none), `time::StandardSteadyClock::GetCurrentTimePoint`, the console six-axis sensor (`hid::*SevenSixAxisSensor*`: zero states) and more `nfp` calls (`AttachActivateEvent` / `AttachDeactivateEvent` crashed in the SDK at `sdk+0x3f2a78`; two-argument `Mount`, `Unmount`, `GetCommonInfo`, `GetRegisterInfo`, `GetState`, `Finalize`). `nvnPrivate0` (a flag in `sdk`'s bss) stays 0, and `nn::ro::ProtectRelro` runs natively on the host's no-op permission calls.
- `main` imports `ScalableFontEngineHelper::Decode` (SDK 20), so the shared font is served as BFTTF. Focus handling mode 2 (focus notifications are sent).
- Rewriter: 1 to 6 halfword jump tables in `main` changed when `half_count` padded only to their largest entry.

## Files and shaders

- RomFS is almost all Yaz0 (`.s*` extensions) and SARC (`Pack/*.pack`); `romfs_marker` `Pack/Bootup_Graphics.pack`.
- 19,592 shaders: `Shader/*.sbfsha` (BNSH), the gsys / ksys resource packs in `Pack/Bootup_Graphics.pack` and the terrain pack in `Pack/TitleBG.pack`, particle effects in `Effect/*.sesetlist` (11,373 shaders, 101 compute), layouts (`.sblarc`) and 37 in `main`. All bind with Mario's texture handle layout; the full build had no failure and no unresolved binding.
- **Resolved: duplicate pipeline keys from disabled blend state.** A recording held 4,829 keys for 1,982 distinct pipelines from 1,818 Metal 4 bases; 2,845 keys differed only in blend factors of targets whose blending was disabled. [Pipeline keys omit unused colour state](../../../docs/reference/shaders.md#pipeline-keys-omit-unused-colour-state) describes the shared normalization.
- `pack_ipa.py` packs its 16 GB IPA in 57 s (Info-ZIP took 2 min 50 s).

### Shader cache validation

The [operation-specific shader caches](../../../docs/reference/shaders.md#shader-caches-follow-each-operations-inputs)
are implemented (2026-10-30), including complete translation outputs, SPIRV-Cross
conversion, source analysis, variants and independent Mac/iOS compilation.
The reproducible harness, source hashes and reports are in
`01007EF00011E000-work/shader-cache-full-20261030/`:
`candidate_subset.py`, `candidate-report.json` and `metal-repeat-report.json`.
The workload keeps the pair closure of 11 real BOTW shaders: three vertex,
five pixel and three compute shaders. It compiles both Mac and iOS outputs.

All 87 source, reflection and library artifacts match byte for byte across
cold, warm and forced rebuilds, with zero shader failures. Cold took 20.498 s,
warm 2.854 s and forced 21.012 s; common discovery/snapshot setup took 1.305 s.
The warm run starts no translator, SPIRV-Cross or Metal compiler process,
hits all 11 analysis bundles and 37 variant entries, and restores all 21
libraries per target. These are bounded-workload measurements, not timings
for all 19,592 game shaders. The first build must populate the new caches.

The comparison also exposed a Metal input-basename dependency and concurrent
same-key compilation. The [fixed input-name convention](../../../docs/reference/shaders.md#metal-cache-entries-require-a-fixed-compiler-input-name)
and cache format 4 make repeated and forced outputs agree; older compiled
cache entries are rebuilt once. The pre-change baseline differs in two fetch
libraries per target because of the corrected compiler filename convention,
despite identical MSL. The extra per-target analysis sources stay outside the
runtime app; packaging tests retain unrelated `.metal` game assets.

Supplemental translator coverage in `translation-cache-20261030/report.json`
compares 98 jobs, including an integer-attribute retry and a synthetic geometry
reader: all 197 raw outputs and 97 ordinary MSL sources match cold, warm and
disabled-cache runs. Unit tests additionally cover scoped invalidation,
paired source dependencies, independent target fallback, corruption and races.

Cache scheduling was then isolated in `dmsh_shader_pipeline.py`. The separate
`shader-cache-isolation-20261030/candidate-report.json` records identical
87-file cold/warm/forced outputs and agreement with the pre-refactor outputs
apart from chain metadata. Reusing the pre-refactor cache also restores all
11 analysis bundles and 42 target libraries without translation or compilation.
The builder supplies explicit callbacks and retains shader transforms and
target fallback policy.

The real compiler comparison above is explicitly experimental:
`DM_ALLOW_OTHER_METAL=1` uses local Metal `32023.883`; the unchanged lock requires
`32023.921`. The supported-toolchain regression report is
`shader-cache-full-20261030/regress/report.md`; that check stops at this compiler
mismatch. No new-chain gameplay or rendered-image comparison is claimed.
BOTW is the only locally available Mac game build; other games have no local
regression run for this change.

### Pipelines on a cold start

- **Experimental runtime-only cache policy:** [Learn and restart measurements](../../../docs/experiments/file-backed-memory.md#further-experiment-runtime-captured-pipeline-cache-2026-10-31) preserve archive lookup with a small cache of requested bases. First-use compilation, further cache growth and physical-iPhone acceptance remain open; defaults are unchanged.
- **Experimental, 2026-10-31:** a retained-graphics Lab-save comparison on the M2 Mac and external SSD reduced kernel footprint from 2888 to 2346 MiB by deriving GPU-only copies of the runtime archives with Apple's `metal-lipo`. Both 115-second runs retained archive hits and produced inspected gameplay screenshots. This is not a new current-graphics or physical-iPhone result. [Cause and reproduction](../../../docs/reference/memory.md#pipeline-archives-copied-from-removable-storage); [full experiment](../../../docs/experiments/file-backed-memory.md#follow-up-pipeline-archive-bytes-2026-10-31).
- `pso_pairs.tsv`: 3,012 shader pairs from agl's BAHS program variations (the agl / gsys / terrain resource packs), which `shader_pairs.tsv` does not hold. 109 of the 543 pairs drawn on entering Zora's Domain came from them; with the table all 543 are known. The prebuild (15,767 bases) takes 910 MB in 16 files, 187 s with 7 workers for the first 12,755 and 19 s for the 3,012 more; the files open in 2.2 s cold, 0.25 s from the file cache, and add about 850 MB of footprint.
- Mac (M2 Max), the Zora's Domain save, Metal shader cache empty (a new bundle ID per run):

| Start | Frame entering the area | Draws that waited, entering it |
|---|---|---|
| `DM_PSO_MTL4=0`, no `pso_user.tsv` | 990 ms, then 535 / 738 / 496 ms frames | 512 draws, 3,325 ms |
| Hybrid, archive prebuilt from `shader_pairs.tsv`, no `pso_user.tsv` | 830 ms, no other frame over 250 ms | 102 draws, 650 ms |
| Hybrid, archive prebuilt with `pso_pairs.tsv` too, no `pso_user.tsv` | 340 ms, no other frame over 150 ms | 50 draws, 20 ms (no pair without its pulling base) |
| Hybrid, archive and `pso_user.tsv` of an earlier run | no frame over 100 ms | 17 draws, 4.6 ms |

Every kind of cold start also shows the game's own 130–220 ms frames every 9–13 frames for a while after the load, with no pipeline work in them.

- The prepare step with the seed list `pso_manifest.tsv` (1,789 lines: New Game to the Shrine of Resurrection, then a Zora's Domain save load). Mac (M2 Max), runs started at a 1-minute load average below 4: Metal cache empty (a new bundle ID per run), the prebuilt archive, that save loaded. Frames over 25 ms with new pipelines or shader library loads, in the 60 s after the last menu press:

| Start | Before the first frame | Frames with pipelines / library loads |
|---|---|---|
| No list (the profile before its list) | – | 4 / 5 (75 libraries), 168 ms of that work, worst frame 128 ms |
| The list, background prewarm (`DM_PSO_PREPARE=0`) | – (14.6 and 16.0 s on one worker, during boot) | 0 / 0 (two runs) |
| The list, prepare step | 5.2 and 2.2 s on 12 workers, 3.3 s on 8 (872 bases compiled) | 0 / 0 (three runs) |
| Second start (Metal cache and archive warm) | 0.08 s, no screen | 0 / 0 |
| A player's list (5,783 lines with the manifest), warm | 0.23 s, no screen (2.7 s in the background) | 0 / 0 |

- **The pipeline archive made offline** ([development.md](../../../docs/development.md#the-pipeline-archive-made-offline)): every one of the 15,767 pairs makes a base (none left to the device, none left out); `metal-tt` built the iPhone 17 Pro Max's archive (`applegpu_g18p`, iOS 27.0) in 252 s on an M2 Max: 653 MB, 219 MB zipped. On that iPhone (iOS 27.0.1) a test app found all 200 bases of a 200-pair archive, at 0.06–0.3 ms each. On the Mac the same build for the M2 Max (`applegpu_g14s`, 615 MB, 253 s) held all 15,767 bases: the prebuild tool with it opened it in 1.8 s from the external drive, found 16 of 16 probed bases in 57 ms and built nothing, where the device's own prebuild took 187 + 19 s on 7 workers. The process's footprint rose by about 615 MB with the archive open. Resolved on the iPhone 17 Pro Max (iOS 27.0.1): the app with the archive (622.8 MB) opened it in 555 ms, found 16 of 16 probed bases in 17 ms, and its prepare step took 0.53 s with no base compiled (1,722 bases from the archives), where the device's own prebuild took 7–8 minutes on a first start; footprint 1,424 MiB at frame 300 and 2,579–2,679 MiB in play to frame 2,100, with the device's own earlier prebuild (932.7 MB in 30 files of `pso_archive/`, from before the archive was shipped) still open beside it.

- **A Mac app** (`--platform mac-app`, M2 Max). Before the shader pairs went into the app: `pipeline prebuild: no …/Resources/dm/shader_pairs.tsv, nothing to build`, no hybrid draws, and first-seen pipelines compiled on the submit thread in frames of 100–546 ms ([Shader-pair tables in a Mac app](../../../docs/reference/shaders.md#shader-pair-tables-in-a-mac-app)). With the pairs and the archive for `applegpu_g14s` in the app (586.2 MB): 16 of 16 probed bases found in 20.6 ms, prepare step 0.23 s, no base compiled, no red line. The first launch of the freshly signed app waited about 100 s while macOS checked its signature; later launches start in a few seconds. The run stayed in the title and menus, so no hybrid draw occurred in it ([PR #241](https://github.com/seedds/nxnative/pull/241)). Repeated on an M4 Pro (`applegpu_g16s`) with an empty Application Support folder: `metal-tt` built the archive in 6:12 (629.4 MB, an APFS clone in the app; ad-hoc signing of the 16.9 GB app took 4:40). The first launch waited about 4 minutes for the signature check before the host started. The archive opened in 250.5 ms from the external drive and covered every pair (16 of 16 probed bases in 34.5 ms), so no pair base was built. The prepare step still compiled 871 bases in 2.80 s on 14 workers: the prewarm list's bases with a vertex layout, which the archive never holds, and which went into the app's own `pso_archive/` (19.9 MB). No red line in the 90 s after.

On this Mac the background prewarm also ends before the save loads, so the step changes the first minute only where the prewarm is slower than the way into play: a slower device, fewer cores, a longer list, a player who skips through the title. Frames over 25 ms without pipeline work (20–71 per run) are the game's own and vary with the machine's other load.

## Mac routes

### Upstream integration (2026-10-30, current)

Merged upstream `ee6648cb`, preserving the BOTW touch adapters and their separate
physical-controller input path. Movement-stick feedback and camera-area R3
double-tap feedback are disabled; the input actions remain unchanged. The iOS
compile check passes all 188 files, the UIKit harness has zero failures, the HID
suite passes 148 checks, and the native touch-menu and trigger-action tests pass.
The focused Python packing, patch, chain, coverage and documentation tests pass.

The game regression selects BOTW, the only local Mac game build, because the
touch behavior is BOTW-only. It stops before comparison: the installed Metal
compiler is `32023.883`, while the shader lock requires `32023.921`. No compiler
bypass was used. The report is
`ui-coverage-20261030/upstream-merge-regress/report.md` in the game's work folder;
this merge has not been validated by a full game run with newly built shaders.

### Relative camera look

`DM_LOOK_TRACE=1` logs the relative sample injected into BOTW 1.9.0's shared post-filter right-stick vector. The startup line reports whether the build-gated getter observer was installed. The trace confirms the host supplied an input vector; screenshots or game-state changes are still needed to prove the game consumed it.

BOTW relative-look input also accepts `look <phase> <dx> <dy>` through `DM_CTL`: phase 0 begins, 1 moves, 2 ends and 3 cancels; deltas are normalized camera motion.

### AppCamera touch gestures

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
before/after images and logs. The [acceptance tracker](../../../docs/botw-menu-touch-progress.md)
records the checks and retained-graphics boundary.

BOTW R/ZR touch feedback occurs on press and cancel-circle boundary crossings.
Releasing inside or outside the circle adds no UI haptic; native cancellation
still occurs only on outside release. UIKit's feedback spy checks these edges,
camera control/gesture coexistence and physical-controller suppression.

### The regression route (2026-10-29, current)

`smoke.tsv` takes the outdoors save (`saves/outdoors` in the NSP folder) with frame-numbered presses, `f300:A` to `f1700:A`; the Zora's Domain save it used before is no longer on the test Mac. Link stands in a field from about 50 s; with the window on screen (M4 Pro) frame 3,000 comes at 57 s and 6,000 at 107 s, while a covered window runs at 20 fps ([covered windows](../../../docs/reference/frame-rate.md)). `regress.py capture` records frame 5000 for `regress.py replay`: noise up to about 150 pixels with 5d2bf73f; one capture at chain `a31235713eee` differed from every replay in 1,603 pixels, a rare live outcome of the depth-EQUAL variation (Frame capture and replay, under Open); later captures replay within 0 to 246 pixels. The current one (chain `f3ceca86cac5`, 2026-10-30): no replay of 8 equals the live frame, noise 122 pixels; 4 of 8 and 113 pixels in the one before. In 2 of 6 `regress.py check` runs on 2026-10-29 the game stayed at 20 fps from the start (frame 2500 not reached by 60 s: NEW-FAIL): the frame step went from 1 to 3 vsyncs at presents 12–15 on three late frames costing 0.02 vsyncs and never came back. Resolved (2026-10-30): the window was behind another one in those runs ([a game window another process starts opens behind other windows](../../../docs/reference/frame-rate.md#a-game-window-another-process-starts-opens-behind-other-windows)); every 20 fps run of 2026-10-28 and 29 had 21 to 115 display link stalls, the 60 fps runs 0 to 7. With `DM_WINDOW_TOP` the window stays in front.

### Final synchronization and pass validation (2026-10-26, current)

#158 and #213 with the review fixes, on base `c6c4fac`, were tested in outdoor gameplay on a Mac M4 Pro, macOS 27.0.1, at the supported 60 fps target and docked 1600x900 rendering. The supplied outdoor save was copied into an isolated seed; each run copied that seed again. The modules were regenerated with that rewriter, and all 19,592 Mac shaders rebuilt for chain `8393d85a4eae`. Every measured run used one retained host binary and the same source/save hashes. No game or graphics code changed during measurement.

The primary comparison ran **off / on / on / off**: all three switches (`DM_NVN_FAST_WAKE`, `DM_NVN_SLICE_MERGE`, `DM_NVN_CS_HOIST`) at 0 or 1, with encoding thread and present snapshots both 1, cut 64, silent audio, and one shared warmed pipeline archive. Each run reached frame 6,000; the measured window was frames 3,001-5,700 (2,700 frames), including a stationary interval, camera turn, walking and a jump. The windows had no new shader loads or pipelines. Values below average the two runs' means, except the p95 row, which gives the two runs separately:

| Metric | Off | On |
|---|---:|---:|
| Frame interval mean | 16.667 ms | 16.673 ms |
| GPU time mean | 7.051 ms | 7.144 ms |
| GPU time p95, each run | 11.155 / 11.782 ms | 11.708 / 12.018 ms |
| Submission CPU mean | 3.456 ms | 3.653 ms |
| Render passes per frame | 158.55 | 146.94 |

**Result:** pass savings survive (about 7.3%), but these runs do not demonstrate a frame/GPU timing speedup. Submission CPU cost rose about 0.20 ms (5.7%). Both pass optimizations activated; a typical 300-frame on window recorded 2,280 merged passes/layer continuations and roughly 1,400-1,800 moved dispatches. Separate stationary and post-movement windows also showed no consistent GPU win.

Single-switch follow-ups, plus another off baseline, gave GPU means of 6.963 ms (wake only), 7.518 ms (slice only), 6.977 ms (hoist only), and 6.970 ms (off). Hoist-only submission CPU was 3.645 ms versus 3.432 ms off. These are single runs, with a few library/pipeline events in the wake/hoist windows, so they are attribution checks rather than repeated timing proof. A further **direct-encoding, snapshots-off** pair gave GPU means 7.331 → 7.199 ms and submission CPU 4.630 → 4.864 ms, both still 60 fps. Blocking SyncWaits were rare in these 60 fps scenes; sparse diagnostic windows showed wake delay 0.090 → 0.064 ms, insufficient to confirm the original GPU-bound wake gain. Segment publishing remained enabled throughout: it has no runtime off switch.

All ten measured BotW runs exited cleanly, with no red line or crash. Screenshots in both modes showed the outdoor scene and the changed camera/character position without an obvious rendering regression. Wind, animation and second-based input holds cause nonzero image differences, including between repeated runs in the same mode; these are not bit-exact pixel checks. GPU clocks were not fixed. This does **not** reproduce the earlier M2 Max/Zora's Domain/120 fps workload or establish its reported gains, and it is not an iPhone test.

Artifacts in the NSP work folder: `run/perf-final-gameplay-20261026/`, with `summary.json`, per-run `run.json`, `source.json`, `frames.tsv`, `host.log`, `analysis*.json`, screenshots, seed, rewritten modules, retained host and reproduction scripts. The earlier DLC-menu and shrine pilots are excluded from the timing comparison. The general correctness changes are linked under “Found on this game”.

Before publishing, the fixes were integrated with main's pipeline archive and GPU profiling changes (`7753b7b`). The full graphics suite, 37 ordering checks in three encoding/switch modes, 8 CPU completion checks under TSAN, 52 bundle / 57 archive checks, 28 profiler checks, both game host builds, documentation checks and all 133 iOS source compiles passed. Two additional on/off frame-loop checks reached frame 5,000 and exited without a red line or crash. Their display link stalled and dropped frames, and the requested screenshots were not produced; they are execution checks only, excluded from the gameplay/timing evidence above. Their source identities, hosts, saves and logs are retained separately in `run/perf-main-integration-20261026/`. Main's subsequent `dac7ba6` changes the rewriter's Taiko matcher, not these host sources.

### Routes

- From the title menu into the autosave: `DM_KEYS=f2500:A,f2800:A,f3100:A,f3400:A` (control at frame ~3900).
- For the copied outdoor save with the downloaded-DLC notices: `DM_KEYS=f300:A,f500:A,f700:A,f900:A,f1100:B,f1300:A,f1500:A,f1700:A`; gameplay is visible by frame 2,600. The measured route adds `f4100:RRight~0.15,f4250:LUp~0.4,f4400:X~0.15,f4600:LDown~0.4`.
- The frame step under load: `DM_TEST_PRESENT_LAG=1,12` (12 ms added to every frame: 30 fps at 1.000 of real time).

## Found on this game

- **Experimental, switch-controlled:** [File-backed guest heap](../../../docs/reference/memory.md#experimental-file-backed-guest-heap), on `experiment/file-backed-memory`. The launcher defaults the preset from available memory; a saved manual On/Off takes priority. Mac probes check actual page residency separately from memory-limit accounting, including real GPU reads/writes. The experiment note records the retained-graphics game comparison and the current-graphics/iPhone validation boundary.

- **Resolved in code and Mac gameplay, iPhone acceptance pending:** [Ordinary virtual sticks while relative look is enabled](../../../docs/reference/services.md#ordinary-virtual-sticks-while-relative-look-is-enabled). The pickup/backup-pad reproduction and runtime evidence are recorded above.

- **Resolved in code, iPhone acceptance pending:** [Guest calls made by observation callbacks](../../../docs/reference/threads.md#guest-calls-made-by-observation-callbacks). The iPhone inventory-category crash log from build `895cecbc` matches the current gate-stack CPU reproduction. It now passes with the same native category entry points retained. Before/after logs and the supplied iPhone log are in `inventory-category-crash-20261030/` in the game's work folder.

- **Implemented, cache equivalence validated:** [Operation-specific shader caches](../../../docs/reference/shaders.md#shader-caches-follow-each-operations-inputs) and [fixed Metal input names](../../../docs/reference/shaders.md#metal-cache-entries-require-a-fixed-compiler-input-name); the cache-validation note above records the real Mac/iOS output comparisons and the supported-toolchain/gameplay validation boundary.

- **Resolved: test shader preparation reported an ambiguous layout after selecting the extraction:** [Mac test shader preparation reports an ambiguous build layout](../../../docs/reference/packing.md#mac-test-shader-preparation-reports-an-ambiguous-build-layout).

- **Resolved: stray light/dark fringes during a widescreen loading wipe:** [Projected fullscreen fills keep texture and clip coordinates together](../../../docs/reference/rendering.md#projected-fullscreen-fills-keep-texture-and-clip-coordinates-together).

- **Resolved: the Mac launcher rejected the extracted image:** [Mac launchers accept RomFS files and directories](../../../docs/reference/packing.md#mac-launchers-accept-romfs-files-and-directories). Development launches now use `run_mac.py --test`; fixed Mac builds use `--release`.
- **Resolved: widescreen minimap clipped at the old 16:9 edge:** [Edge-anchored UI keeps open scissor edges](../../../docs/reference/rendering.md#edge-anchored-ui-keeps-open-scissor-edges).
- **Resolved: black Mac title and scene after the shader-chain update.** A manual shader build mixed an older package with the newer profile. Package records are now identity-checked before translation; [Shader package records match profile keys](../../../docs/reference/shaders.md#shader-package-records-match-profile-keys).

- **Resolved, two stale chain folders held 4.4 GB:** [Old shader library folders grew a game's build folder with each chain change](../../../docs/reference/shaders.md#old-shader-library-folders-grew-a-games-build-folder-with-each-chain-change).
- **Resolved build guard and cache isolation; rendering cause open:** [Tested tools and compiler-specific shader caches](../../../docs/reference/shaders.md#tested-tools-and-compiler-specific-shader-caches).

General host changes first needed here; each applies to every game:

- **Movies at twice their speed at 60 fps** (issue #636): [Movies hold 30 fps under the frame step](../../../docs/reference/frame-rate.md#movies-hold-30-fps-under-the-frame-step).
- **Frame captures under the standard thread policy** (`cap_policy_standard`; also on Pokemon Scarlet): [A frame capture runs under the standard thread policy](../../../docs/reference/nvn-objects.md#a-frame-capture-runs-under-the-standard-thread-policy).
- **Capture interface hashes of binding values** (also on Scarlet, Tears of the Kingdom and Wonder): [A capture refused after a change to the reflection structs](../../../docs/reference/nvn-objects.md#a-capture-refused-after-a-change-to-the-reflection-structs).
- **20 fps regression runs: the window behind another** (`DM_WINDOW_TOP`): [A game window another process starts opens behind other windows](../../../docs/reference/frame-rate.md#a-game-window-another-process-starts-opens-behind-other-windows).
- **The options' Labo VR mode answered as not permitted** (reported by MacNativeGames): [Hooks whose return type did not match the SDK](../../../docs/reference/services.md#hooks-whose-return-type-did-not-match-the-sdk).
- **Shared performance work, checked independently of prewarm data:** [CPU deswizzle copies use slice and row offsets](../../../docs/reference/nvn-objects.md#cpu-deswizzle-copies-use-slice-and-row-offsets) and [Host symbol indexes avoid repeated name scans](../../../docs/reference/services.md#host-symbol-indexes-avoid-repeated-name-scans). [PR #261](https://github.com/seedds/nxnative/pull/261) reports M2 iPad Pro gameplay on update 1.9.0; local verification covers synthetic correctness and CPU microbenchmarks, without a new game/device run.
- **Final #158/#213 gameplay validation:** [Current results](#final-synchronization-and-pass-validation-2026-10-26-current) distinguish the retained pass savings from the timing gains not demonstrated on this Mac.

- **Live controller motion** (`motion_fusion.h`, `motion_apple.h`, `dm_motion_set`): [Live controller motion](../../../docs/reference/services.md#live-controller-motion). Motion aiming works with Motion Controls on, on a Mac M3 Max, macOS 26, with a DualSense over Bluetooth (base game and 1.9.0).
- **Resolved: the IPA omitted pulling libraries with `pso_mtl4 on`, and explicitly including them failed under macOS Bash 3.2.** See [Pulling vertex inputs](../../../docs/reference/rendering.md#pulling-vertex-inputs).
- **Resolved: no rumble on Xbox and DualShock 4-style controllers (Mac)** (`haptics_apple.m`): [Controller haptic engines without advanced players](../../../docs/reference/services.md#controller-haptic-engines-without-advanced-players), [DualShock 4 rumble through its effects report](../../../docs/reference/services.md#dualshock-4-rumble-through-its-effects-report). The charged attack's 0.07 is still not felt on an Xbox controller's motors (open there).
- **No sound on an iPhone set to silent** (`front_ios_audio_session`): [The ring / silent switch muted the game on iOS](../../../docs/reference/audio.md#the-ring--silent-switch-muted-the-game-on-ios); the device check is open.
- **Upscaling in the present** (`fx_encode`, `DM_PRESENT_UPSCALE`): [The present upscales through MetalFX](../../../docs/reference/rendering.md#the-present-upscales-through-metalfx).
- **Thermal cap; resolved movie recovery and acquire/present races** (`thermal_capped`, `DM_THERMAL_CAP`): [A thermally serious iPhone holds 30 fps](../../../docs/reference/frame-rate.md#a-thermally-serious-iphone-holds-30-fps).
- **Resolved in the host: frame-step recovery after a 30 fps cap**: [The frame step after a 30 fps cap ends](../../../docs/reference/frame-rate.md#the-frame-step-after-a-30-fps-cap-ends). Modelled with the measured iPhone GPU times; recovery on the device has not been observed here.
- **Pipeline keys omit disabled blend factors** (`pso_key_norm`): [Pipeline keys omit unused colour state](../../../docs/reference/shaders.md#pipeline-keys-omit-unused-colour-state).
- **Resolved: GPU readback temporaries retained by a game thread's outer pool** (`mtl_read_texels`): [GPU readback without an autorelease pool](../../../docs/reference/memory.md#gpu-readback-without-an-autorelease-pool). Ported from MacNativeGames; checked here with a synthetic Metal readback lifetime test, without a new gameplay memory measurement.
- **Storage buffers bound with size 0 as the rest of their buffer** (`sbw_len`, interval writes in `sbw_note`): [A storage buffer bound with size 0 counted as a write anywhere](../../../docs/reference/rendering.md#a-storage-buffer-bound-with-size-0-counted-as-a-write-anywhere).
- **Compute dispatches ahead of their pass** (`cs_hoist_try`, `DM_NVN_CS_HOIST`): [Compute dispatches between the draws of a pass run ahead of it](../../../docs/reference/rendering.md#compute-dispatches-between-the-draws-of-a-pass-run-ahead-of-it).
- **Slice-merged passes** (`sm_plan`, `sm_amp_get`, `DM_NVN_SLICE_MERGE`): [Passes into other layers of one texture level run as one layered pass](../../../docs/reference/rendering.md#passes-into-other-layers-of-one-texture-level-run-as-one-layered-pass).
- **The host frame step in whole vsyncs** (`nvn_fstep.h`, `fstep_tick`, `FRAME_STEP` stubs, `fps_target`), explained in full under [Frame rate](#the-frame-step-current); its probes (`nvn_fstep_gpu_slowed`, `nvn_fstep_same`): [development.md, Power](../../../docs/development.md#power).
- **Real GPU timestamps per segment** (`gpu_timestamps`, `rep_ticks`), **submissions in segments** (`sub_cut`), **deferred texture binds** (`bh_fresh`), **duplicate colour slots** (`rt_dup_slot`), **cube textures as 2D arrays** (`tex_fit`), **compressed render targets through shadows** (`bcrt_attach` / `bcrt_flush`), **pool lookups** (`pool_find`), **memory fixes** (`defer_drain`'s pool, `g_ghost`, growing pool table), **`nvnTextureCompare` with the channel mapping**, **first-use fill of flushed storage** (`nvn_flushed`, `tex_init_fill`), **partial-cover uniform shadows** (`ubp_get`, `cb_extent.tsv`): [GPU timestamps per submission segment](../../../docs/reference/frame-rate.md#gpu-timestamps-per-submission-segment), [Submissions handed to the GPU in segments](../../../docs/reference/frame-rate.md#submissions-handed-to-the-gpu-in-segments), [Deferred texture binds read at execution](../../../docs/reference/shaders.md#deferred-texture-binds-read-at-execution), [The same texture attached at two colour slots](../../../docs/reference/rendering.md#the-same-texture-attached-at-two-colour-slots), [Cube textures held as 6-layer 2D arrays](../../../docs/reference/rendering.md#cube-textures-held-as-6-layer-2d-arrays), [Compressed textures as render targets through an uncompressed shadow](../../../docs/reference/rendering.md#compressed-textures-as-render-targets-through-an-uncompressed-shadow), [Address to memory pool lookups by binary search](../../../docs/reference/frame-rate.md#address-to-memory-pool-lookups-by-binary-search), [Deferred-release drain without an autorelease pool](../../../docs/reference/memory.md#deferred-release-drain-without-an-autorelease-pool), [Dead texture serials kept in a ghost table](../../../docs/reference/nvn-objects.md#dead-texture-serials-kept-in-a-ghost-table), [Memory-pool tracking table grows in blocks](../../../docs/reference/nvn-objects.md#memory-pool-tracking-table-grows-in-blocks), [`nvnTextureCompare` compares the channel mapping](../../../docs/reference/rendering.md#nvntexturecompare-compares-the-channel-mapping), [First-use fill of storage the game flushed](../../../docs/reference/nvn-objects.md#first-use-fill-of-storage-the-game-flushed), [Partial-cover uniform shadows keep passes open](../../../docs/reference/rendering.md#partial-cover-uniform-shadows-keep-passes-open).
- **Display-link waits per present interval** (`mtl_link_wait_tick`): [Frames of a dynamic present interval held on screen and at the acquire](../../../docs/reference/frame-rate.md#frames-of-a-dynamic-present-interval-held-on-screen-and-at-the-acquire).
- **Spin waits that take a spin lock** (`patch_nso.py` "Spin waits", `dm_spin_wait`) and **yields that make progress** (`thr_yield`): [development.md, Power](../../../docs/development.md#power).
- **`DT_RELR`** (`relr_apply`) and **halfword jump tables** (`half_count`): [Packed relative relocations (DT_RELR)](../../../docs/reference/rewriter.md#packed-relative-relocations-dt_relr), [Halfword jump table landing pads sized to the largest entry](../../../docs/reference/rewriter.md#halfword-jump-table-landing-pads-sized-to-the-largest-entry). **NVN calls on the big host stack** (`nvn_big_entry`): [NVN entry points on the big host stack](../../../docs/reference/nvn-objects.md#nvn-entry-points-on-the-big-host-stack).
- **SDK 20 service calls** and **record sizes against `GetCommandMemoryUsed`** (`draw_rec`): [SDK 20 six-axis sensor and amiibo (`nfp`) calls](../../../docs/reference/services.md#sdk-20-six-axis-sensor-and-amiibo-nfp-calls), [Applet resource user ID, launch parameters and VR mode](../../../docs/reference/services.md#applet-resource-user-id-launch-parameters-and-vr-mode), [Shared font load request](../../../docs/reference/services.md#shared-font-load-request), [Model heaps sized by the host's command record sizes](../../../docs/reference/memory.md#model-heaps-sized-by-the-hosts-command-record-sizes). **SDK 20's audio renderer layout** (`render_once`): [SDK 20's `AudioRenderSystem` layout](../../../docs/reference/audio.md#sdk-20s-audiorendersystem-layout). **Running a 30 fps game at 60**: [sead's dynamic present interval, `ksys::VFR` and the host's frame step](../../../docs/reference/frame-rate.md#seads-dynamic-present-interval-ksysvfr-and-the-hosts-frame-step).
- **Pipeline bases, hybrid pipelines, the prebuild and the prepare step** (`pso_build_ex`, `hybrid_get`, `pso_prebuild`, `warm_prepare`): [development.md, Hybrid pipelines](../../../docs/development.md#hybrid-pipelines), [Pulling vertex inputs](../../../docs/reference/rendering.md#pulling-vertex-inputs), [the prepare step](../../../docs/development.md#the-prepare-step); measured under [Pipelines on a cold start](#pipelines-on-a-cold-start).
- **The pipeline archive made offline** (`dm/gfx/tools/pso_offline.py`, `pso_bundle_open`, `pso_bundle_covers`): [development.md, The pipeline archive made offline](../../../docs/development.md#the-pipeline-archive-made-offline); measured under [Pipelines on a cold start](#pipelines-on-a-cold-start).
- **Resolved: a Mac app without its shader-pair tables**: [Shader-pair tables in a Mac app](../../../docs/reference/shaders.md#shader-pair-tables-in-a-mac-app); measured under [Pipelines on a cold start](#pipelines-on-a-cold-start).
- **Resolved in synthetic archive review checks:** truncated archive containers, zero-probe coverage, stale archives after library bytes change, and plans whose pairs all require device specialization: [Offline pipeline archive reuse and fallback](../../../docs/reference/shaders.md#offline-pipeline-archive-reuse-and-fallback). Checked with generated libraries on the Mac; no new gameplay or iPhone validation.
- **GPU measurement on the iPhone** (`DM_NVN_GPUPROF=every:n`, `DM_AB`, `DM_GPU_CAPTURE`, `dm/tools/gpuprof.py`) and **captures with pipelines built through the device** (`pso4_on`): [05, GPU time on the device](../../../docs/agents/05-debugging.md#gpu-time-on-the-device), [GPU frame captures need pipelines built through the device](../../../docs/reference/shaders.md#gpu-frame-captures-need-pipelines-built-through-the-device).
- **Resolved in synthetic profiling review checks:** [Periodic GPU profiles close at frame boundaries](../../../docs/reference/rendering.md#periodic-gpu-profiles-close-at-frame-boundaries). No new gameplay or iPhone validation.
- **Hitch dumps and guest thread names** (`DM_HITCH_DUMP`), **heap probes** (`DM_PROBE_HEAP*`), **autorelease leaks**: [05, Scripted input and thread scheduling](../../../docs/agents/05-debugging.md#scripted-input-and-thread-scheduling), [05, Memory growth](../../../docs/agents/05-debugging.md#memory-growth).
- **Resolved: type-compatible views read as not resident** (`tex_fit`): [Compatible views made from the texture under a view](../../../docs/reference/rendering.md#compatible-views-made-from-the-texture-under-a-view). Found by replaying the outdoors frame under shader validation; validation is clean after it, and the replayed digest without validation is unchanged.

## Open

- The shipped pipeline archive without the device's own earlier prebuild files (the test iPhone's `pso_archive/` still held them, [Pipelines on a cold start](#pipelines-on-a-cold-start)): the footprint against the app's memory limit and the frame times after it.

- Frame capture and replay ([development.md](../../../docs/development.md#frame-capture-and-replay), GitHub issue #402): a fresh replay does not always give the same digest, with or without segmented submission (open). Outdoors route, frame 4000, `DM_NVN_CUT=0` (2026-10-28, M4 Pro): the live digest in most fresh replays, another in 2 to 7 of 24, among about eight others. The replay has one segment then (nothing is committed before the frame's end), the per-draw pass dumps (state, vertex-stage uniform content, vertex streams) of a matching and a differing replay are identical, every texture the frame has by then is identical at every level after the G-buffer pass (pass 32), and so are that pass's depth and its colour targets 0 and 5; only colour targets 1 and 3 differ (the normal and material outputs of fragment shader `8d56b5cee7c434f6`), and each other digest follows from them. Dropping some of the pass's draws (a probe not kept) narrowed it to 2 pixels where draw 520 of the frame and a later draw both write, the later one usually winning; with depth compare `ALWAYS` for that shader it still varies. Ruled out, each by 16 to 30 fresh replays that still varied: pipelines through the `MTLDevice` (`DM_PSO_MTL4=0`), no prewarm, archive or prediction, the uniform copy worker (`DM_NVN_UB_COPY_THREAD=0`; its shadows also equal synchronous copies), a barrier between every operation of the copy encoder, waiting for every upload batch, a fill pattern in new arena blocks; Metal's API validation reports no error, and shader validation only the [non-resident views](../../../docs/reference/rendering.md#compatible-views-made-from-the-texture-under-a-view) (fixed; not the cause). The earlier reading of Zora's Domain, frame 3000 (one segment boundary between passes 38 and 39 changes the digest, `DM_NVN_CUT=0` always matches), fits this variation too. A second capture of the outdoors route (frame 4000, then frame 5000, same Mac and day) shows the same: with the default segmented submission every fresh replay differs from the live frame, in 97 to 124 pixels (two recurring sets, at most 46 of 255), and with `DM_NVN_CUT=0` between one and five in eight do, in 3 to 124 pixels (also with the `tex_fit` fix); the first difference is again in pass 32, four edge pixels one draw writes (vertex shader `d9670d25c6290936`, fragment `a331f28b1ddbc517`). Ending pass 32 after every draw, or every 100 draws, makes the frame repeat 16 times in 16; every 500 draws, or one break anywhere, does not. What varies is the outcome of depth-equal tests (2026-10-29, frame 5000, `DM_NVN_CUT=0`): pass 32 has draws with depth test `EQUAL` and no depth write (1208–1217 and 1394–1429 in frame 4000), and drawing every such draw with less-or-equal instead (a probe, not kept) makes 16 fresh replays of 16 give one digest, where the unchanged build gave the live one in 11 and another in 5. Nothing the GPU writes in the frame is read by pass 32 (`--writes`, with each writer and reader placed by draw), so its vertex and uniform inputs are the captured bytes in every replay; the depth an `EQUAL` draw compares against, or its own, is then not bit-reproducible from run to run inside a long pass on this GPU. Two more probes (10 fresh replays each): with the `EQUAL` draws' fragment output replaced by their fragment depth's bits in colour target 0 (and their test set to `ALWAYS`), those bits are identical in every replay wherever no later draw covers them; and pass 32's depth buffer at the end of the frame is identical in every replay, also in the two whose pass 32 differs (in 22 and 4 pixels, colour targets 1 and 3 only). The `EQUAL` draws use no depth bias or clamp (46 of 46 in frame 4000). So both operands of the test, as far as they can be read, are the same in every replay while its result is not: the depth the test reads at that moment, inside one long pass, is the remaining suspect, on the GPU's side (partial renders of a long pass are one candidate, not shown). A third replay of the ten differs only after pass 32, so a second varying spot exists later in the frame. Also ruled out there: the regions' addresses (mapped at fixed addresses), the order of separate commits (each waiting on a queue event for the one before), residency (`DM_RES_CHECK=1`) and the vertex / fragment interface. A cause on the GPU side in long passes is likely, not shown; a GPU capture of a matching and a differing replay is the next step. `nvn_replay --max-pixels` judges a change within this noise. A second replay in one process (`--warm`) also differs. Pool blocks after the frame match the live run except counter reports and the blocks the CPU writes during the frame. The variation is this game's, not the replay layer's in general: a frame of Super Mario Bros. Wonder's opening course (59 passes, 436 draws, segmented submission on) gives the live digest in 8 fresh replays of 8 (2026-10-29, M4 Pro). Fixed on the way: block-compressed textures (a 32x32 BC4) and transient render targets recorded under new serials, which share an earlier one's host texture and content, are captured. One capture at chain `a31235713eee` (2026-10-29, at 500aaf5e) differed from the live frame in 1,603 pixels in 8 replays of 8, on the foliage edges (largest byte difference 35). Three later captures of the same route replay within the usual variation: at 949a23bc (same chain) and with the capture fixes, 3 replays of 3 equal the live frame; at 32b12b4d, 1 of 3, the others within 246 pixels. The 949a23bc replayer still gives 1,603 pixels on the old capture, and once 1,742, so no code change removed it. That capture's live frame landed on an uncommon outcome of this variation, and the replays share the common one; the same pool blocks differ after the frame in that capture and in the exact ones (25 to 27 the CPU writes during the frame). The pass's inputs are now shown identical (2026-10-30, capture at chain `f3ceca86cac5`, `DM_NVN_CUT=0`, a probe not kept): with the G-buffer pass (pass 30 in this capture, 1,957 draws) ended before its first `EQUAL` draw (draw 855), its colour targets and depth at that point are byte-identical in 12 replays of 12, and the pass that continues from them loads them, runs the same 1,103 draws and ends with identical depth and colour targets 0 and 3 but colour targets 1 and 2 in three variants, one for each of the frame's three digests. So the same inputs to one pass give different results on the GPU. The pass's fragment shaders write no memory, but 21 of them discard, among them the pre-pass's (`251d810d6eb9f1bc`) and both `EQUAL` ones (`9a1c68baaf12189e`, `de813c8a3ad0e70d`); with `[[ early_fragment_tests ]]` added to the two `EQUAL` shaders by hand (exact for draws without depth or stencil writes) 16 replays gave one digest with `DM_NVN_CUT=0` and two with segmented submission, where the unchanged libraries gave two and one, so that does not settle it either. Tears of the Kingdom's frame varies on the GPU too since the early fragment tests ([its Open](../0100F2C0115B6000/README.md#open)).
- Shrine slowdown (GitHub issues #534, #598): the size-0 fix has not been run in a shrine with a slowdown. A save from before Oman Au's final gate would show whether the refusals end there, or whether another write is behind them (the `residency set` line's `other GPU writes` count).
- The GPU particles' compute dispatches and the G-buffer decals still split passes; about 800 MB of attachments a frame outdoors.
- `DM_RENDER_SCALE` does not change the Mac's GPU time; the sources give no iPhone measurement.
- The VFR override's `the game fixes its own step` path has not been reached on the Mac.
- `game.tsv` still says "In bring-up", and its memory comment "until measured".
- 05's `DM_PROBE_POLL` paragraph cites `PlacementMgr` in `main+0x5aaac0` as the one thread in guest code "for that flag" without naming the game; `PlacementMgr` is this game's.
- Motion on iOS (a controller's gyro, and the phone's own while no controller supplies fresh samples) has not been tested on a device. Source arbitration, concurrent startup and upright orientation were corrected during review and are covered by unit tests; see [Live controller motion](../../../docs/reference/services.md#live-controller-motion). Motion shrines from issue #389 still need a device gameplay check.

### Upstream integration (2026-10-28)

The SDK uses observation IDs 22–25 for address-region and allocator tracking.
BOTW camera observers now use 29–31 to keep the two sets independent. Rewrite
main with the merged tools before using a newly built host; the build input
checks detect this profile change. Controller motion uses the upstream transport
and fusion, while the BOTW phone path retains its neutral pose and landscape
rotation correction.

Merge validation: the Mac host and iOS entry sources compile; native input,
orientation, menu routing and UIKit regressions pass. The presentation regression
passes with Metal validation off. With `MTL_DEBUG_LAYER=1`, the unchanged upstream
MetalFX path asserts `_outputTextureBarrierStages not set` on macOS 26.5.2; that
optional validation-mode issue remains open. The merged chain is `a1f1209828b3`;
existing shader libraries must be rebuilt before launching this host. The regular
build script detects the chain change. Its upstream image workflow needs Python
3.12 or newer.
