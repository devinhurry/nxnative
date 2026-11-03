# BOTW touch internals

How BOTW's own pause-menu inventory works, and what the host may and may not do to it. Written
after the 2026-11-03 investigation of "switching category, then tapping an item shows the
previous category's action (Eat on a weapon)". Read this before changing the inventory touch
path; the answers below were established by reading the 1.9.0 `main` module, and re-deriving
them costs hours.

Addresses are relative to the `main` module base of the 1.9.0 build
(`cd57b23fa4bbad65803d9788c01821ee`). The module image and a full disassembly live in the
game's work folder (`01007EF00011E000-work/analysis-main.elf`); the checked build id is
recorded in the profile's `patches.py` `validate_main`.

## The inventory screen object

The pause-menu inventory screen has its vtable at `main+0x1cf9ad8`. The host finds it through
the same screen registry it uses for every other menu. Its fields:

| Field | Meaning |
|---|---|
| `screen+0x3628` | the UI manager (the pause menu's widget tree) |
| `screen+0x3638` | category restriction copied from `manager+0x44500`; `-1` in the ordinary inventory |
| `screen+0x3650` | absolute id of the selected item widget |
| `screen+0x3658` | the category-request flag (the screen's update acts on it) |
| `screen+0x365c` | current page number |
| `screen+0x3660` | pending page number |
| `screen+0x3664` | pending item index within the page |
| `screen+0x368c` | carousel transition flag |
| `screen+0x3a10` | current category id |
| `screen+0x3a18` / `+0x3a20` / `+0x3a28` | the three item-list widgets |
| `screen+0x3a30` | which of the three lists holds the current page (0..2) |
| `screen+0x3b98` | item id queued for native selection |
| `screen+0x3690 + category*0x80` | per-category block; `+0x78` in it is that category's first page |

Each list widget carries its own current page at `+0x130` and its base item id at `+0x134`.
The three lists own **disjoint** id ranges, taken from the global table at `main+0x1e2e828`
(a count and an array of three int32): the values are `{9, 29, 49}`, so the lists own
`9..28`, `29..48` and `49..68`. The game's own focus handler accepts only ids in `9..68`
(`main+0xe3bacc`, `main+0xe3bb24`), which confirms the split.

**The base table is indexed by the carousel slot, not by the page.** The index is
`screen+0x3a30`, the list that holds the current page (`main+0xe3e2b0` .. `main+0xe3e2c8`,
`main+0xe3f9d4` .. `main+0xe3f9f4`). So the item ids of the visible page depend on which
of the three lists holds it: a page shown in slot 1 owns ids `29..48`.

## The game's own category change

The game reads the requested category from the tab row and copies it into the screen on every
update (`main+0xe3aa84` .. `main+0xe3aa9c`: `screen+0x3638 = manager+0x44500`). A separate
screen method (`main+0xe3ce58`) handles the request itself; the screen's update calls it when
the request flag `screen+0x3658` is set (`main+0xe40870` .. `main+0xe40874`). That method
takes the category, updates the per-category widgets and asks the UI manager to publish the
new tab selection.

The page switch itself happens in the screen's update (`main+0xe3a964`):

1. `page = main+0xe71160(category)` — the category's first page.
2. `screen+0x365c = screen+0x3660 = page` — **both** page fields, not only the pending one.
3. `main+0xe3af74(screen)` — re-lay out the three lists. This writes `list+0x130` for the
   current page and its two neighbours, and it **keeps** `screen+0x3a30` as the carousel has
   it: the current page stays in the slot it already occupied.
4. `main+0xe3b20c(screen, page)` — the only writer of `screen+0x3a10`
   (`main+0xe3b228`, `main+0xe3b230`: `0x3a10 = main+0xe71080(page)`), plus the per-category
   widget blocks.
5. The remaining update stages native selection through `screen+0x3b98` and refreshes
   category controls through `main+0xe3b550(screen)`.

The change is a single-frame state change: the pages move and the lists are re-laid out. It
is **not** the animated path — the animation that tweens across every intervening page
belongs to the shared category widget's animated mode (`main+0xd6c244`), which the touch
path does not use. A direct category tap through the game's own contract therefore stays as
fast as the host's hand-rolled one.

## How the game selects an item

`main+0xe3dd14(screen, itemIndex)` is the game's "select an item" call: it deactivates the
currently focused item widget, writes `screen+0x3664`, clears `screen+0x3650` and
`screen+0x3648`, and calls `main+0xe3e284`.

`main+0xe3e284(screen, page, itemIndex)` computes the absolute item id and focuses it. The
base offset comes from the global table, indexed by **which list widget's `+0x130` page
equals the requested page** (`main+0xe3e294` .. `main+0xe3e2c8`). If no list matches the
page, the function returns 0 and touches nothing (`main+0xe3e374`): there is no fallback
base, so `screen+0x3650` keeps its old value.

Before it applies the item, the function compares values from a bound parameter and the
manager at `main+0x1e2f148` (`main+0xe3e2d4` .. `main+0xe3e304`). If they differ, it queues
the id in `screen+0x3b98` (`main+0xe3e38c`). These values must not be assumed to be tab
category ids. In the captured ordinary inventory, the screen's binding resolves to that
same manager: `screen+0x188` points to the embedded binding at `screen+0x158`, whose
`+0x10` target is `main+0x1e2f148` (`main+0x13eeff0`).

**Do not write the object behind `main+0x1d6b540`.** That slot points to the shared
fallback integer object at `main+0x1db1708`, initialized to `-1`; the generic resolver
`main+0x14039bc` returns it for an unbound parameter. It is not an inventory category
setter. An initial attempt wrote category ids there; live testing disproved that fix,
and the write was removed.

`screen+0x3650` is written by the game's focus handler (`main+0xe3bacc`, `main+0xe3bb24`) and
by the re-resolve routine below. The focus handler maps an id to a list and calls
`main+0xdc7248` to obtain its item row; the list's `+0x130` is the page passed to
`main+0xd992ac(manager, page, row)` (`main+0xe3bb88` .. `main+0xe3bc18`). The page a list
shows is therefore part of an item's identity.

`main+0xe3f924(screen)` is the game's "the layout changed, re-derive the selection" routine.
One branch of the screen's update calls it when a selection exists and no transition is in
flight (`main+0xe40614` .. `main+0xe40648`): it re-reads the category from the current page, sets the
tab selection, re-lays out the lists and recomputes `screen+0x3650` as
`base(slot) + row` (`main+0xe3f9d4` .. `main+0xe3fa00`).

## What the host did, and why it was wrong

`selector_request_category` in `dm/host/hle_botw_touch_menu.c` changed the category by hand:

```c
memcpy((void *)(screen + 0x3660), &first_page, 4);   // pending page only
native_flag_setter(screen, 1);                        // main+0xe39c08 → screen+0x368c = 1
native_refresh(screen, 0);                            // main+0xe3ddcc
memcpy((void *)(screen + 0x3664), &selected_slot, 4);  // pending item = 0
native_commit(screen);                                // main+0xe3b9f0
```

The old sequence omits the complete native selection refresh:

**The "refresh" does nothing.** `main+0xe3ddcc` is a *page* mover inside the current
category. Its first check compares `category(page + delta)` against `screen+0x3638` and
returns early on a mismatch (`main+0xe3de10` .. `main+0xe3de28`). The host never updates
`screen+0x3638`, so the check fails and the call is a no-op.

**The "commit" forces the carousel.** `main+0xe3b9f0` sets `screen+0x3a30 = 1`
(`main+0xe3ba88`) before re-laying out the lists (`main+0xe3af74` at `main+0xe3ba94`), so the
pages land in slots 0/1/2 relative to slot 1 rather than relative to the slot the carousel
had. Because the base-id table is indexed by that slot, the visible page's item ids move to
another range, and every id the game still holds from the previous category now names a
different list.

**Changing the page fields and widgets alone is insufficient.** A live Mac test of that
partial fix still showed the new category's grid with "Simmered Fruit" in the item card.
The test's `screen-food.bin`, `screen-weapon.bin` and screenshots are in
`01007EF00011E000-work/category-item-fix-20261103/`. Reusing a carousel slot can retain
the focused cursor entry, so the host must refresh native item selection as part of the
category change instead of relying on a subsequent focus change or a conditional update
branch to refresh the card and its actions.

## The fix

The switch now runs the game's own sequence, in the game's order:

1. write **both** `screen+0x3660` and `screen+0x365c` with the category's first page;
2. `main+0xe3af74(screen)` — re-lay out the lists, keeping `screen+0x3a30`;
3. `main+0xe3b20c(screen, page)` — update `screen+0x3a10` and the per-category widgets;
4. `main+0xe3f924(screen)` — resolve selection immediately for the new page. The routine
   refreshes the item pointer at `screen+0x3648` through `main+0xd992ac` and passes it to
   the native item-card update at `main+0xe33fe4` (`main+0xe3faa4` .. `main+0xe3fb14`).
5. `main+0xe39c08(screen, 0)` — activate the rebuilt current page's native buttons.
   This is the unguarded body of the transition-state setter; its public entry at
   `main+0xe39bfc` would return immediately because the transition is already zero.

Relayout updates row contents and visibility but keeps the buttons' prior input flags.
Switching from shields to bows reproduced a visible arrow with `owner+0x3a = 0x202f`,
missing the selectable `0x10` bit. Both touch and controller Down then ignored it. The
activation body calls `main+0xdc7040(current_list, true)`, which applies native button
eligibility to all 20 rows. This restores newly filled rows without enabling empty cells
or writing cursor flags directly.

`main+0xe3ddcc` and `main+0xe3b9f0` are the wrong tools for a category change: the first is
a page mover guarded by `screen+0x3638`, the second forces the carousel slot. The host does
not stage a pending item either: the game's own select call clears `screen+0x3650` and
re-derives it, and staging it by hand left the two out of step.

The native addresses (`main+0xe3af74`, `main+0xe3b20c`, `main+0xe3f924`, `main+0xe39c08`) and the
selection resolver's item lookup are
checked in the profile's `validate_main` with their exact instruction bytes, like every
other build-gated address.

## Equipment taps and the 150 ms item menu

Only swords, bows, arrows and shields use direct equipment taps. Their native `PouchItem`
types are 0, 1, 2 and 3 at `item+0x18`; arrows share the Bow category but remain a separate
item type. Armor and other item types retain the normal menu. The public
[BOTW decompilation](https://github.com/zeldaret/botw/blob/master/src/Game/UI/uiPauseMenuDataMgr.h)
documents these types; the 1.9.0 instructions and offsets are checked independently.

Touch-down requests native focus without A. A release before 150 ms calls
`main+0xe3f378(screen, true)` on the guest UI thread after the native cursor has acknowledged
the entry. This is the game's Equip action (`main+0xe40c10` .. `main+0xe40c18`), including
the native data-manager, player, list and item-card updates. Its `false` argument removes
equipment and must never be used for a short tap. Already-equipped items and items with
zero durability/count stay unchanged.

The host checks the screen vtable, the owner's item id at `owner+0x44`, the screen's
acknowledged id at `screen+0x3650`, and the live item pointer at `screen+0x3648` before
dispatch. `item+0x24` is the equipped flag and `+0x25` is inventory membership. The native
entry, Equip/Remove caller, id range and item-field instructions are build-checked in
`validate_main`.

A stationary press reaching 150 ms uses the existing native A/menu path while the finger
is still down. Time comes from `CLOCK_MONOTONIC`, independently of game frames. Once the
menu is requested, the press is consumed so release cannot equip or choose a popup action.
Dragging, cancellation, stale page/popup ownership and changed selected items invalidate
the pending action.
The game ignores A on an already-equipped arrow stack; long press preserves that native
behavior rather than creating an action menu the game does not offer.

## The tests, and what they miss

`dm/host/tests/t_botw_touch_menu.c` covers the inventory category flow. It asserts the
staged pages, the native call order
(`re-lay out the lists → current category → resolve selection → activate buttons`), the skip while a transition is in flight, and
that the current category follows the switch.
Equipment checks cover all ten item types, release just below 150 ms, opening the menu
at exactly 150 ms while held, no duplicate on release, already-equipped and depleted items,
delayed native focus, cancellation and changed page ownership.

`DM_TEST_HOOKS` replaces native calls with recorders, so this test verifies the host's
contract and cannot prove what the game shows. Live acceptance must switch between food
and equipment, select items (including a cursor entry reused across pages), and inspect
both the item card and action list in each direction. Use `scripts/run_mac.py --test`
with current code, matching shaders and a copied save.

The 2026-11-03 Mac acceptance results and screenshot paths are recorded in the
[game's touch note](../../dm/games/01007EF00011E000/notes/touch.md#direct-categories-and-gameplay-hud-prompts).

## Where the game's own records are

The game's work folder holds the earlier decompilation of these functions
(`01007EF00011E000-work/category-instant-20261030/`, with `inventory-commit.dis.txt`,
`inventory-refresh.dis.txt`, `inventory-focus.dis.txt`, `inventory-update-category.dis.txt`
and the rest). They describe the same code; this page records what the 2026-11-03
investigation concluded from it.
