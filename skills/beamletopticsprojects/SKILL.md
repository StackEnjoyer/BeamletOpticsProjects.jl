---
name: beamletopticsprojects
description: Work on a project of BeamletOptics.jl with BeamletOpticsProjects.jl (Julia): a folder with system.jl (one line per component, source and system), src/<Name>.jl and Project.toml, which people open in the GUI while agents edit it. Use when a folder has a *.bmo file or a system.jl with @component, @source or @system lines, or when the user asks to load, change, trace, inspect or version such a project, or to take part in it next to the people in their windows.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
metadata:
  beamletopticsprojects-version: "0.1"
---

You are helping the user with a **project** of BeamletOptics: an optical setup saved as a folder that
people open in the GUI (BeamletOpticsGUI) and that you edit as code at the same time. The package
BeamletOpticsProjects reads, writes, traces and versions it, also without a window.

When this Skill is active:

- **The optics comes from the `beamletoptics` skill** (units, +y optical axis, constructors,
  `solve_system!`, detectors), the window from the `beamletopticsgui` skill. Install the missing
  ones from the packages, in the project folder and with the project environment
  (`julia --project=.`, so that the versions the project pins are loaded): `using BeamletOptics; BeamletOptics.install_agent_skill()`,
  `using BeamletOpticsProjects; BeamletOpticsProjects.install_agent_skill()`,
  `using BeamletOpticsGUI; BeamletOpticsGUI.install_agent_skill()`. They come from the installed
  packages in the versions the project pins, never from a copy in the versions of the project.
- This skill describes BeamletOpticsProjects **0.1** (`beamletopticsprojects-version` above). Check
  the installed version with `julia --project=. -e 'using BeamletOpticsProjects; println(pkgversion(BeamletOpticsProjects))'`.
  If its major or minor version differs, confirm every function with its docstring
  (`display(@doc trace)`) and install the matching skill as above.
- Use only documented API (`API.md`). **Do not invent functions or keywords.**
- Run Julia in the project environment (`julia --project=.` in the project folder) after any
  change: `load_project` must load, and `trace`/`look` show what the change did. Do not claim a
  change works when you did not run it.
- People and agents are participants alike: announce yourself before you change the project, and
  leave when you are done (see "Taking part").

## The folder

```text
Bench/
├── Bench.bmo        the project file that people open; it only marks the folder. Do not edit it.
├── system.jl        the setup: one line per component, source and system (FORMAT.md)
├── src/Bench.jl     own code (module Bench): functions that build components, own types. The GUI never writes it.
├── Project.toml     the exact versions of the packages ([compat]); [beamletoptics] format
├── view.toml        the view of the GUI (camera, colors, clip planes). Do not edit it.
├── AGENTS.md        what is specific to this project (CLAUDE.md points to it)
├── .claude/skills/  the skills, installed from the packages (not versioned)
└── .bmo/            written by the participants, not versioned (see "The open windows")
```

## Default workflow

1) Read `AGENTS.md` of the project and `.bmo/session*.md` (what the people selected and did).
2) Load and look:

   ```julia
   using BeamletOptics, BeamletOpticsProjects
   p = load_project(".")     # throws with the line of system.jl on errors
   look(p)                   # versions, participants, per system the chains of ids, distances, detectors
   look(p; around = :L3)     # only the objects within 50 mm of L3 and the beams through them
   ```

3) Announce yourself (`announce`, see "Taking part") with the id you work on.
4) Change single lines of `system.jl` (form: `FORMAT.md`) or code in `src/<Name>.jl`. Give a new line
   the next free id of its prefix (`next_id(p, "L")`), without `uid`.
5) Check: `p = load_project(".")`, then `r = trace(p, :S1)`: `r.detectors[:D1].hits`,
   `r.detectors[:D1].power` [W], `r.segments` (the `path_segments` of the sources: `start`, `stop`,
   `object`, ...). `look(p)` again to see the chains. Report the numbers; what counts as good is the
   user's decision. Two things to say when you report them: the hits of rays (`Beam`) have no power
   (`power` is `nothing`, `look` prints `rays, no power`), it is not 0 W; and `trace` solves only the
   sources of that system, so a detector that is a member of several systems shows only the hits of
   this system's sources, while the window superposes the hits of all systems that share it.
6) `leave` when you are done. Versions are the person's (see "Versions").

## The open windows

Several people may have the project open in their own windows while you work on it.

- The window saves every finished action of its person to `system.jl` within about a second, so
  `system.jl` is what the person sees. It reloads `system.jl` and `src/` when you change them, and it
  never overwrites your changes silently: if both changed the same line, it asks the person.
- Edit single lines of `system.jl`. Never rewrite the whole file from an older read: it would undo
  what the person did meanwhile. Read the file again after any failed edit.
- `save_project(p)` writes the whole `system.jl` from a loaded project; it throws `ProjectChanged`
  if the files changed since `p` was loaded. Then load the project again and redo the change; never
  force it.
- Each window writes `.bmo/session-<person>.md`: the selection and the recent actions of its person.
  If Claude Code was started in the project folder, its hook (`.claude/settings.json`) shows them
  with every prompt; otherwise read `.bmo/session*.md` when a person refers to "this" or "what I just
  did". The other files in `.bmo/` (`presence-*.toml`, `view-*.toml`) belong to their participants;
  do not edit those of others.

## Taking part

The windows show every participant at the object it works on, people and agents alike.

- `announce(".", name = "claude", doing = "aligning L2", selected_id = "L2")` writes your presence
  file `.bmo/presence-<name>@agent.toml` (see the docstring of `announce` for its fields). `name` is
  your id and must be unique among the participants (`"claude-w1"` for a worker of a team): the same
  `name` is the same file. Call it again when you go to another object. After you wrote the files,
  call it with `wrote = true`: only then it publishes the stamp of the files (`written`), by which
  the windows name you as the writer of a change, also if they merged the change before your call;
  without `wrote = true` the `written` of the file before is kept.
- `leave(".", name = "claude")` deletes it when you are done.
- Optionally write `.bmo/session-<your id>.md` (see `BeamletOpticsProjects.session_file`): a few
  lines of what you do, for other agents.
- `look(p)` lists the participants of the presence files (not whether they are still there).

## Teams

A team (an orchestrator and its workers, people or agents alike) works in one shared draft of
the project instead of the live files: variants and half-done work stay out of the windows, and
the result goes in at once. Orchestrator and worker are roles, not kinds of participants. Each
member announces itself with its own unique name (`announce(".", name = "w1", …)`).

The orchestrator:

1. `draft = fork_team(".", "t1"; by = "lead", goal = "second beam path")` copies the live project
   once to `.bmo/drafts/t1/` (with its fork base in `base/`); the draft loads like a project
   (`load_project(draft)`).
2. Splits the work so that every worker owns its lines (ids) and its place in `system.jl`, and
   posts the tasks: `post!(draft; by = "lead", kind = :task, text = "…", data = Dict("worker" =>
   "w1", "ids" => ["B2", "BS2"]))`. The ids of a task are those of components and sources. The
   `@system` lines have no ids for workers: the orchestrator edits them itself, after the workers
   are done. An entry is visible on the board only when it is complete.
3. Waits for all workers: `e = wait_for(draft; kind = :done, after = n, timeout = 600)` returns the
   first entry of the kind after the number `n` (`nothing` after the timeout), i.e. one worker.
   Call it in a loop, each time with `after = e["n"]` of the last entry, until every worker has
   posted `:done`. It looks only at the entries that follow `after` without a gap, so it never
   skips one that is not complete yet. `board(draft)` lists every entry in order (`n`, `by`,
   `kind`, `text`, `data`).
4. Checks what the team changed since the fork: `evaluate(load_project(draft); base =
   load_project(joinpath(draft, "base")))` reports how far the old systems deviate, foreign hits
   and clearances (numbers, no verdict: judge them by the task). What the people changed in the
   live project since the fork does not show here; `merge_draft!` reports it as conflicts.
5. Only when the participant who has the say over the project (usually the person) agrees:
   `merge_draft!(".", "t1")` takes the changes of the draft into the live project: `system.jl`, and
   the code of the draft's `src/` for the files that the live project did not change since the
   fork (the others are conflicts, listed as `src/<file>`). It saves a version "Team t1: …" that
   lists only what was taken and returns what was taken and the conflicts (not written). A new
   entry whose readable id the live project has already gets the next free id, in the draft too.
   Afterwards the draft is rebased onto the merged state (`base/` = the live state), so the team
   can go on and call `merge_draft!` again. The window shows the merge like any change of the
   files. Delete the draft folder when the team is done.

A worker:

- `claim!(draft; by = "w1", ids = [:B2, :BS2])` before changing lines (the ids are
  `Symbol`s: `Symbol.(task["data"]["ids"])` for those of a task). The ids are claimed in sorted order,
  so two workers with overlapping ids never block each other: one of them gets the contested id.
  `false`: someone else has one of them and none of yours is held; ask on the board.
  `release!(draft; by = "w1")` when done.
- Edits only its lines of `draft/system.jl` (and the code in `draft/src/` it was asked to write),
  traces in the draft (`trace(load_project(draft), :S2)`, `look`), and shares results on the
  board: `post!(draft; by = "w1", kind = :data, text = "BS2 at y = 0.42 m", data = Dict(…))`, then
  `post!(…; kind = :done)`.
- Waits for what it needs instead of guessing: `wait_for(draft; kind = :data, after = n)`.

A team of one (one agent with a person) works the same way when it explores or optimizes; small,
targeted changes the person asked for go into the live files directly.

## Versions

A version is a git commit of the project folder (libgit2, no git install needed). `versions(".")`
lists them, newest first; `version_summary(".")` says what changed since the last one. Versions are
the person's: `Ctrl+S` in the window saves one. Call `save_version(".")` only when the person asks.
`.bmo/` and `.claude/skills/` are never part of a version.

## Local references bundled with this Skill

- The form of `system.jl` (ids, labels, uids, poses, systems): `FORMAT.md`
- Export table and the functions in short: `API.md`
