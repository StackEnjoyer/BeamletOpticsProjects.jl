---
name: beamletopticsprojects
description: Work on a project of BeamletOptics.jl with BeamletOpticsProjects.jl (Julia): a folder with system.jl (one line per component, source and system), src/<Name>.jl and Project.toml, which people open in the GUI while agents edit it. Use when a folder has a *.bmo file or a system.jl with @component, @source, @group or @system lines, or when the user asks to load, change, trace, inspect or version such a project, or to take part in it next to the people in their windows.
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
  (`using REPL; display(@doc trace)`: without `REPL` a script prints the raw `DocStr`) and install
  the matching skill as above.
- Use only documented API (`API.md`). **Do not invent functions or keywords.**
- Run Julia in the project environment (`julia --project=.` in the project folder) after any
  change: `load_project` must load, and `trace`/`look` show what the change did. Do not claim a
  change works when you did not run it. Loading the packages takes about 15 s per `julia` call:
  put loading, tracing, changing and tracing again into one script instead of many small calls.
- People and agents are participants alike: announce yourself before you change the project, claim
  the objects you change, and release them and leave when you are done (see "Taking part").
- **All work is live**, in the project that the people have open: also design studies, variants
  and optimizations. Each candidate goes into `system.jl` before you evaluate it (`trace`, `look`),
  never only into a script of yours, so that the people see what you try. A draft (see "Teams")
  only when the person asks for variants side by side.
- **Ask once, at the start of the work, whether you should keep a report on the tools** (see
  "Report on the tools"): where BeamletOptics, BeamletOpticsProjects and BeamletOpticsGUI got in
  your way and what you would have needed. It is how these packages are made easier to use for
  agents, one session at a time.

## The folder

```text
Bench/
├── Bench.bmo        the project file that people open; it only marks the folder. Do not edit it.
├── system.jl        the setup: one line per component, source, group and system (FORMAT.md)
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

3) Announce yourself (`announce`, see "Taking part") with the id you work on, and claim the ids of
   the lines you are going to change: `claim!("."; by = "claude", ids = [:L2])`. On `false`
   someone else is working on one of them: choose other work or ask the person.
4) Change the setup with the writes of the package, not by editing `system.jl` as text. Each
   checks the changed lines before it writes (the code builds, poses are finite, ids are free,
   systems and groups stay whole; else an `ArgumentError` naming the id and nothing is written),
   writes once under the write lock, respects claims, and with `by` tells the windows that you
   wrote it ("claude: added M19"), without an `announce` of yours:
   - `id = add!(".", "RoundPlanoMirror(0.0254, 0.006)"; pos = (0.1, 0.2, 0), rot = (0, 0, 45),
     label = "fold", systems = [:S1], by = "claude")`: picks the next free id of its prefix in the
     same write (no other participant can take it meanwhile) and returns it; a source goes into
     the `sources` of one system.
   - `set!(".", :L9; pos, rot, code, label, by)` changes only the given fields of a line (a group:
     its label; move groups with `move!`).
   - `move!(".", [:G1, :FIOS1]; offset = (0.3, 0, 0), rot = (0, 0, 10), pivot = :center, by)` moves
     and rotates components, sources, groups with their members and systems with their members and
     sources by one rigid motion (rotation about the pivot, default the mean of the positions, then
     the offset); the window shows it as one move.
   - `new = duplicate!(".", [:M19, :L1]; rot = (0, 0, -90), pivot = :M19, offset, systems = :same,
     by)` copies lines (a group with its members) by the same rigid motion and returns the new ids.
   - `remove!(".", [:M20]; by)` removes lines with their places in systems and groups.
   Read with `members(p, :S1)`, `sources(p, :S1)` and `pose(p, :TM2)` (`pos`, `rot` as a matrix,
   as the line has it: `set!(".", :TM2; pos, rot)` puts a remembered pose back). Code in
   `src/<Name>.jl` and anything these do not cover (form: `FORMAT.md`) is edited as text: then
   give a new line `next_id(p, "L")` and no `uid`; a `@group` line lists its members, systems list
   the group, not its members.
5) Check: `p = load_project(".")`, then `r = trace(p, :S1)`: `r.detectors[:D1].hits`,
   `r.detectors[:D1].power` [W], `r.segments` (the `path_segments` of the sources: `start`, `stop`,
   `object`, ...) with `r.ids[i]`, the id of the object hit at the end of `r.segments[i]`
   (`nothing`: no hit), and `r.warnings`, what BeamletOptics warned about during the solve (e.g. a
   Lagrange invariant violation: the beamlet model is out of its range, the numbers are not to be
   trusted). `look(p)` again to see the chains. For a scan of many steps that nobody needs to
   watch, trace moved copies in memory instead of writing each step: `trace(moved(p, [:TM2];
   offset = (2e-8, 0, 0)), :S1)` writes nothing. Report the numbers; what counts as good is the
   user's decision. Two things to say when you report them: the hits of rays (`Beam`) have no power
   (`power` is `nothing`, `look` prints `rays, no power`), it is not 0 W; and `trace` solves only the
   sources of that system, so a detector that is a member of several systems shows only the hits of
   this system's sources, while the window superposes the hits of all systems that share it.
6) `release!` your claims and `leave` when you are done. Versions are the person's (see
   "Versions").

## The open windows

Several people may have the project open in their own windows while you work on it.

- The window saves every finished action of its person to `system.jl` within about a second, so
  `system.jl` is what the person sees. It reloads `system.jl` and `src/` when you change them, and it
  never overwrites your changes silently: if both changed the same line, it asks the person.
- Edit single lines of `system.jl`. Never rewrite the whole file from an older read: it would undo
  what the person did meanwhile. Read the file again after any failed edit.
- `save_project(p; by = "claude")` writes the whole `system.jl` from a loaded project; it throws
  `ProjectChanged` if the files changed since `p` was loaded, or if another participant is saving
  at that moment (it waits at most 2 s). Then load the project again and redo the change; never
  force it. With `by` (your `name`) it also throws an `ArgumentError` that names the line and its
  holder if the save would change a line that another participant claimed; then leave that line
  alone.
- Each window writes `.bmo/session-<person>.md`: the selection and the recent actions of its person.
  If Claude Code was started in the project folder, its hook (`.claude/settings.json`) shows them
  with every prompt; otherwise read `.bmo/session*.md` when a person refers to "this" or "what I just
  did". "Selected:" lists every object of a selection of several ("my selection"); the presence
  file has them in `selected_ids`. A session file of a window that was not closed properly stays:
  `look(p)` marks its participant "likely gone" when the presence file is older than its `ttl`,
  and the actions carry their date. The other files in `.bmo/` (`presence-*.toml`, `view-*.toml`, `claims/`) belong to their
  participants; do not edit those of others, and change claims only with `claim!` and `release!`.

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
- **Claims.** Whoever edits an object holds its claim, and the others do not change it meanwhile.
  `claim!("."; by = "claude", ids = [:L2, :M1])` before you change their lines (the ids are
  `Symbol`s; `by` is the `name` you announced with): `true` if all of them are yours now, `false`
  if another participant holds one of them; then none is claimed by this call. Of two
  participants that claim the same object at the same time exactly one gets it. A claim is kept
  by the machine id of the line, so it stays with its object. `release!("."; by = "claude", ids =
  [:L2])` releases those, `release!("."; by = "claude")` all of yours; release when you are done
  with an object.
- A claim lives as long as your presence: `ttl` seconds (default 120) after your last `announce`
  or `claim!`, which both refresh it. Call one of them at least that often while you work; the
  claims of a participant who is gone are taken over by the next one who claims.
- `claims(".")` lists the claims of the participants who are still there, by the machine id of the
  line: `(by, id)`. People claim too: their windows claim an object while the person drags, turns,
  edits, removes or groups it, until it is deselected or 30 s after the last gesture.
- The windows of people refuse a gesture on an object that someone else claimed and say who holds
  it ("claude is editing L2"); they show the holder's name and a lock at the object. A
  `save_project(p; by)` that changes a line claimed by another throws (see "The open windows").
- Optionally write `.bmo/session-<your id>.md` (see `BeamletOpticsProjects.session_file`): a few
  lines of what you do, for other agents.
- `look(p)` lists the participants of the presence files (not whether they are still there).

## Teams

A team (an orchestrator and its workers, people or agents alike) works **live**, in the project
that the people have open, like a single participant: the windows show every worker at its object.
Orchestrator and worker are roles, not kinds of participants. Each member announces itself with
its own unique name (`announce(".", name = "w1", …)`) and claims before it writes.

The orchestrator:

1. Splits the work so that every worker owns its lines (ids) and its place in `system.jl`. The ids
   of a task are those of components, sources and groups; the `@system` lines it edits itself,
   after the workers are done.
2. Posts the tasks on a board. The board belongs to a team folder: `team = fork_team(".", "t1";
   by = "lead", goal = "second beam path")` makes one (`.bmo/drafts/t1/`). In a live team only
   its board is used; the workers do not work in its copy of the project. Post a task with
   `post!(team; by = "lead", kind = :task, text = "…", data = Dict("worker" => "w1", "ids" =>
   ["B2", "BS2"]))`. An entry is visible on the board only when it is complete.
3. Waits for all workers: `e = wait_for(team; kind = :done, after = n, timeout = 600)` returns the
   first entry of the kind after the number `n` (`nothing` after the timeout), i.e. one worker.
   Call it in a loop, each time with `after = e["n"]` of the last entry, until every worker has
   posted `:done`. It looks only at the entries that follow `after` without a gap, so it never
   skips one that is not complete yet. `board(team)` lists every entry in order (`n`, `by`,
   `kind`, `text`, `data`).
4. Checks the result in the live project: `trace`, `look`, and `evaluate(load_project("."); base =
   …)` against the state before (numbers, no verdict: judge them by the task).

A worker:

- `claim!("."; by = "w1", ids = [:B2, :BS2])` before changing lines (the ids are `Symbol`s:
  `Symbol.(task["data"]["ids"])` for those of a task). Of two workers with overlapping ids one
  gets the contested id. `false`: someone else (also a person in a window) has one of them and
  none of yours is held; ask on the board. `release!("."; by = "w1")` when done.
- Edits only its lines of `system.jl` (and the code in `src/` it was asked to write), traces
  (`trace(load_project("."), :S2)`, `look`), and shares results on the board: `post!(team; by =
  "w1", kind = :data, text = "BS2 at y = 0.42 m", data = Dict(…))`, then `post!(…; kind = :done)`.
- Waits for what it needs instead of guessing: `wait_for(team; kind = :data, after = n)`.

**Variants in a draft.** Only when the person asks for variants (several versions of the setup
side by side, of which one or none goes in), the team works in the draft instead of the live
files:

1. `draft = fork_team(".", "v1"; by = "lead", goal = "…")` copies the live project once to
   `.bmo/drafts/v1/` (with its fork base in `base/`); the draft loads like a project
   (`load_project(draft)`). The workers claim, edit, trace and post in the draft
   (`claim!(draft; …)`, `draft/system.jl`, `trace(load_project(draft), :S2)`).
2. `evaluate(load_project(draft); base = load_project(joinpath(draft, "base")))` reports what the
   variant changed since the fork: how far the old systems deviate, foreign hits and clearances.
   What the people changed in the live project since the fork does not show here; `merge_draft!`
   reports it as conflicts.
3. Only when the participant who has the say over the project (usually the person) agrees:
   `merge_draft!(".", "v1")` takes the changes of the draft into the live project: `system.jl`, and
   the code of the draft's `src/` for the files that the live project did not change since the
   fork (the others are conflicts, listed as `src/<file>`). It saves a version "Team v1: …" that
   lists only what was taken and returns what was taken and the conflicts (not written). A new
   entry whose readable id the live project has already gets the next free id, in the draft too.
   Afterwards the draft is rebased onto the merged state (`base/` = the live state), so the team
   can go on and call `merge_draft!` again. The window shows the merge like any change of the
   files. Delete the draft folder when the team is done.

## Versions

A version is a git commit of the project folder (libgit2, no git install needed). `versions(".")`
lists them, newest first; `version_summary(".")` says what changed since the last one. Versions are
the person's: `Ctrl+S` in the window saves one. Call `save_version(".")` only when the person asks.
`.bmo/` and `.claude/skills/` are never part of a version.

## Report on the tools

The packages of BeamletOptics are improved for agents from what agents run into while they use
them. At the start of the work, ask the person once: "Shall I keep a report on where the tools got
in my way?" Only if they say yes:

- Keep it in `.bmo/reports/<your name>-<date>.md` (e.g. `claude-2026-10-29.md`), and write each
  point when it happens, not from memory at the end. Tell the person the path when you are done.
- One point per friction, most costly first at the end: what you wanted to do; what you tried
  (the call, the error message in its first line, the file and line of the docs or skill you
  followed); what it cost (failed attempts, a workaround, guessing, waiting); and what would have
  helped (a function, a keyword, an error message that names the cause, a sentence in a skill, a
  return value you could use directly). Name the package: BeamletOptics, BeamletOpticsProjects or
  BeamletOpticsGUI.
- Also what was missing in the skills, wrong in them, or hard to find; and what worked well, so it
  stays.
- Facts only, about the tools, not about the person or the task. No secrets or data of the
  project beyond what a point needs.
- The report does not replace your work: do the task first, write the point in a few lines.

## Local references bundled with this Skill

- The form of `system.jl` (ids, labels, uids, poses, systems): `FORMAT.md`
- Export table and the functions in short: `API.md`
