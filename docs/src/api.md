# API

```@meta
CurrentModule = BeamletOpticsProjects
```

```@docs
BeamletOpticsProjects
```

## Load and save

```@docs
load_project
save_project
new_project
Project
Entry
SystemEntry
GroupEntry
system_code
project_file
project_marker
project_dir
project_stamp
ProjectChanged
```

## The form of `system.jl`

```@docs
@component
@source
@group
@system
id_prefix
next_id
apply_pose!
rotation_matrix
```

## Change lines

Each function is one checked write: it respects the claims of the others and writes nothing when
the change is refused.

```@docs
add!
set!
move!
duplicate!
remove!
```

## Read lines

```@docs
members
sources
pose
moved
```

## Versions of the packages

```@docs
project_versions
check_versions
VersionCheck
```

## Trace and read

```@docs
trace
look
```

## Versions and changes

```@docs
save_version
versions
version_summary
diff_projects
EntryChange
SystemChange
GroupChange
copy_code
```

## Participants and claims

```@docs
announce
leave
claim!
release!
claims
```

## Teams

```@docs
fork_team
teams
post!
board
wait_for
merge_draft!
```

## Guards

```@docs
evaluate
```

## Public, not exported

```@docs
install_agent_skill
person
presence_file
session_file
write_presence
read_presences
alive
merge_plan
compose
project_name
module_name
normalize_code
EXTENSION
same_entry
same_system
same_group
new_uid
match_entries
```
