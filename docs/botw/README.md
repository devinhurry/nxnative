# BOTW documentation

The BOTW-specific documents:

- [Touch implementation checklist](touch-implementation.md): every required action group, its
  implementation status and its verification evidence. Generated from the editable inventory
  (`dm/games/01007EF00011E000/touch_ui_inventory.json`).
- [Touch resource disposition](touch-resources.md): every scanned layout, its role and the
  actions it needs. Generated from the same inventory.
- [Touch internals](touch-internals.md): how the game's own pause-menu inventory works, which
  fields the host may write, and the category-change contract. Read it before changing the
  inventory touch path.
- [Acceptance progress](touch-progress.md): the runtime evidence for each change, and what
  is still pending on a device.
- [UI coverage and regression workflow](ui-coverage.md): the resource scanner, the gap
  report and the replay route format.

The game's own note is `dm/games/01007EF00011E000/README.md`, with its findings split into
`dm/games/01007EF00011E000/notes/`.
