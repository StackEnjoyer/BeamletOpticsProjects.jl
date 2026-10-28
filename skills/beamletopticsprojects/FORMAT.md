# The form of `system.jl`

One line per entry; components first, then sources, then groups, then systems:

```julia
@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, λ -> 1.5) pos = (0.0, 0.1, 0.0)
@component M1 = RightAnglePrismMirror(0.025, 0.025) pos = (0.0, 0.2, 0.0) rot = (0.0, 0.0, 90.0)
@source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6) pos = (0.0, -0.05, 0.0)
@system S1 = [L1, M1] sources = [B1]
```

- The name after `@component`/`@source`/`@group`/`@system` is the readable **id** (`L1`, `M2`, `D3`,
  `BS1`, `B1`, `G1`, `S1`: a prefix of the family and a number, see `id_prefix`). It is unique and stays; never
  rename an id. Give a new line the next free number of its prefix (`next_id(p, "L")`).
- `label = "…"` is the name that people see and change in the GUI; optional. When a person names an
  object ("the collimator"), find its id by the label (`look(p)` shows the labels).
- `uid = "…"` (always last) is the machine id by which the GUI recognizes the line. Never change or
  copy it; a new line has no `uid`, it gets one when the project is saved.
- The right-hand side is any expression that builds a BeamletOptics component, group or source, also
  a call of a function of `src/<Name>.jl` (its exported names). SI units: m, wavelengths in m.
- `pos` is the absolute position (m), `rot` the rotation since construction in degrees: first about
  the global x-axis, then y, then z. Both are optional.
- `catalog = (...)` belongs to the GUI (its page "Edit"); delete it when you change the constructor.
- `@system`: members are components; a component may be in several systems, a source in at most one.
  `static = true` makes a `StaticSystem`. Each system is traced on its own (`trace(p, :S1)`); a detector that is in several systems is the exception in the window, which adds up their hits.
- `@group G1 = [L1, M1] pos = (x, y, z) [rot = (a, b, c)]` is a group that moves as one in the
  window (`Ctrl+G`): an `ObjectGroup` of its members in this order, with the pivot `pos` (required)
  and the orientation `rot` of the group. The rules:
  1. The members are components or other groups (inner groups), never sources or systems.
  2. Each component and each group is a member of at most one group.
  3. A component inside a group is never itself a member of a system: the `@system` line lists the
     outermost group (`@system S1 = [G1, D1]`), and so all members of a group are in the same
     systems as the group.
  4. The members keep their own lines with their absolute poses; the `@group` line holds only the
     pivot and the orientation of the group. Loading moves no member. To move a group, move its
     members and its `pos` by the same amount.

  ```text
  @component L1 = SphericalLens(...) pos = (0.0, 0.1, 0.0)
  @component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0) rot = (0.0, 0.0, 45.0)
  @component D1 = Detector(0.02) pos = (0.0, 0.3, 0.0)
  @group G1 = [L1, M1] pos = (0.0, 0.15, 0.0) rot = (0.0, 0.0, 10.0) label = "Telescope"
  @system S1 = [G1, D1]
  ```
  A component `@component G2 = ObjectGroup([...])` is a group too, but its parts have no lines nor
  ids of their own; the window writes `@group` lines.
- Other lines (e.g. comments) are not kept: the GUI rewrites `system.jl` on every save.

In Julia, `p = load_project(".")` builds every line: `p[:L1]` is the object, `p[:S1]` the system,
`p.entries` the `Entry`s (`name`, `code`, `pos`, `rot`, `label`, `uid`), `p.groups` the
`GroupEntry`s (`name`, `members`, `pos`, `rot`) and `p.systems` the `SystemEntry`s (`name`,
`members`, `sources`); `p[:G1]` is the group.
