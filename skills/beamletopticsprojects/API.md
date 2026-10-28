# BeamletOpticsProjects API primer

```julia
using BeamletOptics, BeamletOpticsProjects

p = load_project(".")            # or the path of the folder or of its *.bmo file
p[:L1]                           # the object with the id L1; p[:S1] the system S1
r = trace(p, :S1)                # solves S1 with its sources, fresh (initialize! first)
r.detectors[:D1]                 # (hits = 120, power = 0.00098)  [W]
r.segments                       # the path_segments of the sources, concatenated
look(p)                          # the setup as text; look(p; around = :L3)
announce(".", name = "claude", doing = "aligning L2", selected_id = "L2")   # wrote = true after writing
claim!("."; by = "claude", ids = [:L2])   # before changing the line of L2; release! after
leave(".", name = "claude")
versions(".")                    # the versions, newest first
```

Print the docstring of a function before you use it: `display(@doc trace)`. Names that are public
but not exported are qualified: `BeamletOpticsProjects.install_agent_skill()`.

## Exported names

| Category | Names |
|---|---|
| Load and save | `load_project`, `save_project`, `new_project`, `Project`, `Entry`, `SystemEntry`, `GroupEntry`, `system_code`, `project_file`, `project_marker`, `project_dir`, `project_stamp`, `ProjectChanged` |
| The form of `system.jl` | `@component`, `@source`, `@group`, `@system`, `id_prefix`, `next_id`, `apply_pose!`, `rotation_matrix`, `move!` |
| Trace and read | `trace`, `look` |
| Versions and changes | `save_version`, `versions`, `version_summary`, `diff_projects`, `EntryChange`, `SystemChange`, `GroupChange`, `copy_code` |
| Participants and claims | `announce`, `leave`, `claim!`, `release!`, `claims` |
| Teams | `fork_team`, `teams`, `post!`, `board`, `wait_for`, `merge_draft!` |
| Guards | `evaluate` |

## Public, not exported (frequent)

| Name | Meaning |
|---|---|
| `install_agent_skill(dest = ".claude/skills")` | copies this skill from the installed package |
| `person()`, `presence_file`, `session_file`, `write_presence`, `read_presences`, `alive` | the files of the participants in `.bmo/` |
| `merge_plan` | which changes of two copies of a project can be merged |
| `compose(base, mine, theirs, keys)` | the state of `mine` with that of `theirs` at `keys` (widened by the rules of systems and groups), `(; project, keys)` |

## `trace` and `look`

- `trace(p, :S1; flen = 0.1)` initializes the system (its detectors are emptied), solves each source
  of its `@system` line and returns `segments` and `detectors` (`hits`, `power` [W] per member that
  is a `Detector`; `power` is `nothing` for the hits of rays, which carry none: not 0 W). Only the
  sources of that system are solved: a detector in several systems holds only their hits, while the
  window superposes the hits of all systems that share it. Tracing again gives the same segments
  and hit counts, and the same `power` except for a beam group as source (e.g. `CollimatedSource`)
  traced with several threads, where `power` can differ in the last bits. Measurements only: no
  tolerances, no verdicts.
- `look(p)` prints and returns: the versions (installed and pinned) and the path of BeamletOptics,
  the participants, per system one line per chain of ids along the beams with the distances in mm
  (`B1 → L1 (50.0 mm) → D1 (20.0 mm)`, `out` leaves the system, `?` has no id) and the detector
  readings (`rays, no power` for the hits of rays), and the objects without a system. Sources are
  shown with their label. `around = :L3` keeps the objects within 50 mm of L3
  and the beams through them.

## Participants and teams

- `announce(dir; name, doing = "", selected_id = "", ttl = 120, kind = "agent", wrote = false)`
  writes `.bmo/presence-<name>@agent.toml` and returns the id. `name` must be unique per participant
  (`"claude-w1"`); `announce` does not invent ids. `written` (the stamp of the files, by which the
  windows name the writer of a change) is published only with `wrote = true`, right after writing;
  otherwise the earlier `written` is kept. `leave(dir; name)` deletes the file.
- `claim!(dir; by, ids::Vector{Symbol}) -> Bool` claims the objects of the ids in the live project
  (`dir = "."`) or in a draft, in sorted order; of two participants that want the same object one
  gets it; on `false` none of the ids is held. Kept by the machine id of the line; alive as long
  as the presence of `by` (the announced `name`), which `claim!` refreshes. `release!(dir; by,
  ids = nothing)` releases those ids, or all of `by`. `claims(dir)` lists the alive claims, machine
  id => `(by, id)`.
- `save_project(p; by)` throws an `ArgumentError` (and writes nothing) if it changes a line that
  another participant claimed.
- `post!(team; by, kind, text, data)` makes an entry visible on the `board` only when complete.
  `wait_for(team; kind, after = 0, timeout = 60)` looks only at the contiguous run of entries after
  `after` (never skips one that is not visible yet) and returns the first of the kind, or `nothing`.
  For several workers loop with `after = e["n"]`. `team` is the folder of `fork_team`.
- `fork_team(dir, name; by, goal)` makes the team folder with its board, and copies the live
  project once into it (the draft) and its `base/`. A team works live and uses only the board;
  the draft is for variants that the person asked for.
- `merge_draft!(dir, name)` applies renames to the entries and systems of the draft and all their
  references, takes the draft's `src/` files that the live project did not change since the fork
  (the others are conflicts, `src/<file>`), saves the version "Team <name>: <taken>" that lists
  only the taken changes, rebases the draft (`base/` = the merged live state) so that a second
  call works, and returns `(; taken, conflicts)`.
- `evaluate(project; base)` measures what a project changed; for a team `base =
  load_project(joinpath(draft, "base"))`. Objects inside a group have the id of the group; the
  change of `power` is `nothing` where a side has the hits of rays.
