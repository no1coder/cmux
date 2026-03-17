# Horizontal Workspace Pane Strip Design

## Summary

Each workspace becomes a horizontal strip of sibling panes. The top-level unit is a `pane`, not a nested split tree. Inside each pane, cmux still supports horizontal `surfaces` the same way Bonsplit does today.

This keeps the top level closer to niri while preserving cmux's existing surface model. Internally, the implementation can continue using `paperCanvas` and `viewport` concepts. Those are engine details, not the primary user-facing terms.

## Goals

- Make the top-level object inside a workspace discrete and easy to talk about.
- Keep `surface` tabs inside a pane.
- Separate `split the current pane` from `open a new pane to the right`.
- Keep shortcuts, menus, and command palette actions consistent.
- Reuse the existing paper-canvas engine instead of inventing a second layout system.

## Product Model

- `workspace`: the vertical-tab item in the sidebar
- `pane`: the top-level tile inside a workspace
- `surface`: a horizontal tab inside a pane

Internal-only implementation terms for this phase:

- `canvas`: the larger layout space that contains the pane strip
- `viewport`: the visible rect into that canvas

The future `page` concept remains separate and unclaimed by this feature.

## Scope

Phase 1 is horizontal-only at the top level.

- A workspace can contain multiple sibling panes laid out left to right.
- A pane can contain multiple surfaces.
- Top-level vertical pane creation is out of scope.
- Nested top-level split trees are out of scope.

Workspaces already provide the vertical dimension in the product model. If vertical pane strips are needed later, that should be a separate design pass.

## Top-Level Behavior

The workspace behaves like a strip of sibling panes with a small visible gutter between panes. The visible area snaps and reveals by pane, instead of behaving like a freeform continuous field.

Focus movement is pane-oriented. When focus changes, the visible area should move as needed to keep the focused pane visible and aligned to pane boundaries.

Opening a new pane should follow niri-style sizing semantics: creating a new top-level pane should not rebalance unrelated panes by default.

## Pane Actions

### Split Pane Right

`Split Pane Right` divides the focused pane's current width into two sibling panes.

- Default shortcut: `Cmd+D`
- Result: the current pane donates space to create a new pane to its right
- Mental model: true split

### Open Pane Right

`Open Pane Right` creates a new sibling pane to the right without treating it as a split of the current pane.

- Default shortcut: `Cmd+Opt+N`
- Result: the new pane is inserted to the right at about `66%` of the current viewport width
- Existing unrelated panes keep their widths
- After reveal, about `33%` of the previous pane should remain visible on the left when space allows
- The new pane becomes focused and is revealed
- Mental model: niri-style open new column

### New Surface

`New Surface` continues to create a new surface in the focused pane.

- Default shortcut: `Cmd+T`
- This action does not create or rearrange panes

### Unsupported Top-Level Vertical Split

`Split Pane Down` is not supported in this phase for the top-level pane strip.

- Existing shortcut: `Cmd+Shift+D`
- Behavior in pane-strip mode: reject or no-op with explicit feedback
- Public API behavior: return `not_supported`

## Menus and Command Palette

Both top-level pane creation actions must be first-class commands, not shortcut-only behavior.

Required exposure:

- app menu entry for `Split Pane Right`
- app menu entry for `Open Pane Right`
- command palette entry for `Split Pane Right`
- command palette entry for `Open Pane Right`

Both commands should show the same shortcut hint everywhere, sourced from `KeyboardShortcutSettings`, so customization stays coherent across the app.

The command palette should keep the two actions distinct in both title and search keywords. Searching for `split`, `open`, `pane`, `right`, or `new pane` should surface the appropriate command.

## Internal Architecture

Reuse the existing `paperCanvas` internals as the geometry engine.

- Keep the one-row pane strip as a constraint on top of the current model
- Keep pane gutters explicit
- Keep viewport movement pane-aligned
- Do not rename every internal `paperCanvas` or `viewport` symbol in this phase

This should be implemented as a constrained mode of the current engine, not as a second layout engine.

## Non-Goals

- top-level vertical pane strips
- nested pane split trees inside this new top-level model
- full terminology cleanup of existing internal symbols
- the future title-bar `page` concept

## Verification

The change should be covered by behavior-oriented tests:

- PaneKit geometry tests for one-row layout, pane gutters, and pane-aligned viewport anchors
- workspace tests for pane and surface behavior
- shortcut routing tests for `Cmd+D`, `Cmd+Opt+N`, `Cmd+T`, and rejected `Cmd+Shift+D`
- command palette tests for discoverability and shortcut hints
- socket or CLI tests for explicit `not_supported` vertical operations

UI automation can be added later once the interaction model is stable.
