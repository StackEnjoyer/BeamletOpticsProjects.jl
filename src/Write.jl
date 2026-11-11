#=
Writing system.jl: the same project always gives the same text
=#

"""
    system_code(project) -> String

The text of `system.jl` of `project`: a header, then one line per `@component`, `@source`,
`@group` and `@system`, in this order and in the order of the entries (groups inner first).
Numbers are written exactly and as short as possible; a rotation given as a matrix is written as
angles in degrees if it can be, see [`rotation_matrix`](@ref).
"""
function system_code(p::Project)
    io = IOBuffer()
    println(io, "# BeamletOptics project \"", p.name, "\" (format ", FORMAT, "). Agents: see AGENTS.md.")
    for kind in (:component, :source)
        for e in p.entries
            e.kind === kind && println(io, _entry_line(e))
        end
    end
    for g in _inner_first(p.groups)
        println(io, _group_line(g))
    end
    for s in p.systems
        println(io, _system_line(s))
    end
    return String(take!(io))
end

function _entry_line(e::Entry)
    bad = _nonfinite(e.pos, e.rot)
    isnothing(bad) && return _entry_text(e)
    throw(ArgumentError("$bad of `$(e.name)` is not finite, the project is not written"))
end

function _entry_text(e::Entry)
    io = IOBuffer()
    print(io, "@", e.kind, " ", e.name, " = ", _code_string(e.code))
    e.pos === nothing || print(io, " pos = ", _tuple_string(e.pos))
    r = _rot_string(e.rot)
    r === nothing || print(io, " rot = ", r)
    for (k, v) in e.meta
        print(io, " ", k, " = ", _code_string(v))
    end
    _print_ids(io, e)
    return String(take!(io))
end

function _system_line(s::SystemEntry)
    io = IOBuffer()
    print(io, "@system ", s.name, " = [", join(s.members, ", "), "]")
    isempty(s.sources) || print(io, " sources = [", join(s.sources, ", "), "]")
    s.static && print(io, " static = true")
    _print_ids(io, s)
    return String(take!(io))
end

function _group_line(g::GroupEntry)
    bad = _nonfinite(g.pos, g.rot)
    isnothing(bad) ||
        throw(ArgumentError("$bad of `$(g.name)` is not finite, the project is not written"))
    io = IOBuffer()
    print(io, "@group ", g.name, " = [", join(g.members, ", "), "] pos = ", _tuple_string(g.pos))
    r = _rot_string(g.rot)
    r === nothing || print(io, " rot = ", r)
    _print_ids(io, g)
    return String(take!(io))
end

"""
The `groups` in their order, but each group after the groups among its members, so that a file
lists the inner groups first. A cycle is written in the order it has.
"""
function _inner_first(groups::Vector{GroupEntry})
    index = Dict(g.name => i for (i, g) in enumerate(groups))
    done = falses(length(groups))
    order = GroupEntry[]
    function visit(i)
        done[i] && return nothing
        done[i] = true
        for m in groups[i].members
            j = get(index, m, 0)
            j == 0 || visit(j)
        end
        push!(order, groups[i])
        return nothing
    end
    foreach(visit, eachindex(groups))
    return order
end

# The label (if any) and the machine id (if any) at the end of a line
function _print_ids(io, x)
    isnothing(x.label) || print(io, " label = ", repr(x.label))
    isnothing(x.uid) || print(io, " uid = ", repr(x.uid))
    return nothing
end

"""Code on one line: an expression as Julia prints it, a string of code parsed first."""
_code_string(code::AbstractString) = _code_string(Meta.parse(code))
function _code_string(@nospecialize(code))
    s = code isa Union{Expr, Symbol} ? string(normalize_code(code)) : repr(code)
    occursin('\n', s) && throw(ArgumentError("code does not fit on one line: $s"))
    return s
end

_float_string(x) = repr(iszero(x) ? 0.0 : Float64(x))
_tuple_string(t) = string("(", join(map(_float_string, t), ", "), ")")

_rot_string(::Nothing) = nothing
_rot_string(t::Tuple) = _tuple_string(t)
function _rot_string(R::AbstractMatrix)
    maximum(abs, R - I) ≤ _ROT_TOL && return nothing
    angles = euler_angles(R)
    angles === nothing && return string("[", join((join(map(_float_string, R[i, :]), " ")
                                                   for i in 1:3), "; "), "]")
    return _tuple_string(angles)
end

"""How close a written rotation must be to the matrix it stands for."""
const _ROT_TOL = 1e-13

"""
    euler_angles(R) -> Union{Nothing, NTuple{3, Float64}}

The angles `(a, b, c)` in degrees with `rotation_matrix((a, b, c)) ≈ R`, each the shortest
decimal that keeps the deviation within `1e-13`; `nothing` near gimbal lock (`b` close to ±90°).
"""
function euler_angles(R::AbstractMatrix)
    cb = hypot(R[1, 1], R[2, 1])
    cb < 1e-6 && return nothing
    angles = [rad2deg(atan(R[3, 2], R[3, 3])), rad2deg(atan(-R[3, 1], cb)),
              rad2deg(atan(R[2, 1], R[1, 1]))]
    for i in 1:3
        for digits in 1:17
            trial = copy(angles)
            trial[i] = round(angles[i]; sigdigits = digits)
            if maximum(abs, rotation_matrix(Tuple(trial)) - R) ≤ _ROT_TOL
                angles = trial
                break
            end
        end
    end
    return Tuple(a == 0 ? 0.0 : a for a in angles)
end

"""
    save_project(project; packages = Module[], force = false, by = nothing) -> String
    save_project(project, path; packages = Module[], force = false, by = nothing) -> String

Writes `system.jl` of `project` (in the folder `path`, which becomes the folder of the project)
and returns its path. A folder that is not a project yet (it has no `system.jl`) gets the files of
[`new_project`](@ref) and its first version (see [`save_version`](@ref)).

Every save raises the versions that the project file records (see [`project_marker`](@ref)): per
package the higher of the recorded version and the one of this session, for BeamletOptics,
BeamletOpticsProjects and `packages` (`[versions]`) and for the packages that the own code in
`src/` uses now (`[packages]`, found from its `using` and `import`). The project file is written
only if this changes it.

Throws [`ProjectChanged`](@ref) and writes nothing if the files changed since the project was
loaded or saved (its `stamp`, see [`project_stamp`](@ref)), unless `force` is `true`. Afterwards
the `stamp` of `project` is that of the written files. Saving to another folder (`path`) does not
check. With the participant `by` (see [`claim!`](@ref)), throws an `ArgumentError` and writes
nothing if the save changes a line claimed by another participant.

The check and the write happen under the lock `.bmo/write.lock`, so of two participants that save
at the same moment, the second sees the first's write and throws `ProjectChanged` instead of
overwriting it. A save waits for the lock of another writer for at most 2 s and then throws
`ProjectChanged` as well: that writer is writing, so load (or merge) and save again. A lock older
than 10 s is of a writer that died and is taken over. Its age is compared with the clock of this
machine: the clocks of the machines are assumed to agree within a few seconds (one Windows domain).
"""
function save_project(p::Project; packages::Vector{Module} = Module[], force::Bool = false,
        by = nothing)
    mkpath(joinpath(p.path, ".bmo"))
    fresh = false
    file = project_file(p, "system.jl")
    _with_write_lock(p.path) do
        files = _stamp_files(p.path)
        force || isnothing(p.stamp) || !isfile(file) ||
            _stamp(files) == p.stamp || throw(ProjectChanged(p.path))
        _give_uids!(p)
        fresh = !isfile(file)
        fresh && _scaffold(p.path, p.name, packages)
        # The code of a new project is part of its stamp
        fresh && (files = _stamp_files(p.path))
        text = system_code(p)
        isnothing(by) || _check_claims(p.path, String(by), text)
        # The versions of this session and the packages of `src/` (not part of the stamp)
        _update_marker(p.path, p.name, packages)
        # On a shared drive the others' reads can block the replace for a while (see
        # `_write_or_overwrite`); the write lock keeps other writers out meanwhile
        _write_or_overwrite(file, text; tries = 20, wait = 0.1)
        # The stamp of the text written, not of the files read again: agents edit the files
        # without the lock, and an edit right after this write is not part of it
        files["system.jl"] = Vector{UInt8}(text)
        p.stamp = _stamp(files)
    end
    # A new project: its first version
    fresh && _first_version(p.path)
    return file
end

# How old the write lock of a project may be before another writer takes it over [s]
const _WRITE_LOCK_STALE = 10.0
# How long a save waits for the write lock of another writer before it gives up [s]
const _WRITE_LOCK_WAIT = 2.0

"""
Runs `f()` while this writer holds the write lock `.bmo/write.lock` of the project folder `dir`: a
file created exclusively (see `_create_exclusive`) with a token of this writer, taken away after
`f` if it is still this writer's. A lock written more than `_WRITE_LOCK_STALE` seconds ago (on the
clock of this machine) is of a writer that died and is taken away. Throws
[`ProjectChanged`](@ref) if another writer holds the lock for `wait` seconds: it is writing, so the
files will have changed.
"""
function _with_write_lock(f, dir; wait::Real = _WRITE_LOCK_WAIT)
    file = joinpath(dir, ".bmo", "write.lock")
    token = string(gethostname(), " ", getpid(), " ", uuid4())
    t0 = time()
    while !_create_exclusive(file, token)
        _lock_stale(file) && _take_away(file, _lock_stale) && continue
        time() - t0 >= wait && throw(ProjectChanged(dir))
        sleep(0.02)
    end
    try
        return f()
    finally
        _take_away(file, l -> _read_text(l) == token)
    end
end

# Whether the write lock `file` was written more than `_WRITE_LOCK_STALE` seconds ago
_lock_stale(file) = isfile(file) && time() - mtime(file) > _WRITE_LOCK_STALE

# The text of `file`, `nothing` if it can not be read
function _read_text(file)
    try
        return read(file, String)
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
end

"""
Creates `file` with `body` if it does not exist, such that it never exists without its body: the
body goes into a temporary file of this writer first, which is then linked to `file` (a hard link
fails if `file` exists). Falls back to an exclusive create where hard links are not supported.
`true` if it was created, `false` if it existed.
"""
function _create_exclusive(file, body)
    tmp = string(file, ".", getpid(), "-", rand(UInt32), ".tmp")
    write(tmp, body)
    try
        hardlink(tmp, file)
        return true
    catch e
        _exists_error(e) && return false
        e isa Base.IOError || rethrow()
        # No hard links on this file system: exclusive create, then write
        F = Base.Filesystem
        f = try
            F.open(file, F.JL_O_CREAT | F.JL_O_EXCL | F.JL_O_WRONLY, 0o644)
        catch e2
            _exists_error(e2) && return false
            rethrow()
        end
        try
            write(f, body)
        finally
            close(f)
        end
        return true
    finally
        rm(tmp; force = true)
    end
end

"""
Takes the file `file` (a claim or the write lock) away if it is the one expected,
`expected(path)` of the file at `path`, and returns whether it did. The file is checked after it
was moved to a name of this writer, not when it was read before: another writer may have replaced
it meanwhile (e.g. broken a stale claim and made its own), and that one is put back. Of several
writers that take it away at once, exactly one moves it. Also removes what writers that died left
of `file` this way, if it is expected.
"""
function _take_away(file, expected)
    prefix = string(basename(file), ".gone-")
    away = joinpath(dirname(file), string(prefix, getpid(), "-", rand(UInt32)))
    for attempt in 1:10
        try
            Base.rename(file, away)
            break
        catch e
            e isa Base.IOError || rethrow()
            # Gone (another writer moved it), or a sharing violation of a network drive that lasts
            (e.code == Base.UV_ENOENT || attempt == 10) && return false
            sleep(0.05)
        end
    end
    ok = expected(away)
    ok || _put_back(away, file)
    _rm_left(away)
    if ok
        for f in readdir(dirname(file); join = true)
            startswith(basename(f), prefix) && expected(f) && _rm_left(f)
        end
    end
    return ok
end

# Removes the file `f` that `_take_away` moved away, if it can: on Windows another writer may have
# it open right now (to check it as a leftover), then the next writer removes it
function _rm_left(f)
    try
        rm(f; force = true)
    catch e
        e isa Base.IOError || rethrow()
    end
    return nothing
end

# Puts the file at `away` back to `file`, unless a new `file` was made meanwhile
function _put_back(away, file)
    try
        hardlink(away, file)
    catch e
        _exists_error(e) && return nothing
        e isa Base.IOError || rethrow()
        # No hard links on this file system
        body = _read_text(away)
        isnothing(body) || _create_exclusive(file, body)
    end
    return nothing
end

function save_project(p::Project, path::AbstractString; packages::Vector{Module} = Module[],
        force::Bool = false, by = nothing)
    path = abspath(path)
    if path != p.path
        p.path = path
        p.stamp = nothing
    end
    return save_project(p; packages, force, by)
end

"""Gives every entry, system and group of `p` without a machine id a new one (a UUID)."""
function _give_uids!(p::Project)
    for (i, e) in enumerate(p.entries)
        isnothing(e.uid) || continue
        p.entries[i] = Entry(e.kind, e.name, e.code, e.object, e.pos, e.rot, e.pose0, e.meta, e.label,
            string(uuid4()))
    end
    for (i, s) in enumerate(p.systems)
        isnothing(s.uid) || continue
        p.systems[i] = SystemEntry(s.name, s.members, s.sources, s.static, s.object, s.label,
            string(uuid4()))
    end
    for (i, g) in enumerate(p.groups)
        isnothing(g.uid) || continue
        p.groups[i] = GroupEntry(g.name, g.members, g.pos, g.rot, g.object, g.label, string(uuid4()))
    end
    return p
end

"""
Writes `text` to a temporary file of this writer next to `file` and then renames it to `file`, which
replaces it at once. A rename that fails with an `IOError` or `SystemError` (a sharing violation of
a network drive) is tried again, up to `tries` times `wait` seconds apart; then the temporary file
is removed and the error thrown. `move` is the function that renames. Each writer has a temporary
file of its own, so two writers at the same time never write into one.
"""
function _write_atomic(file, text; move = _rename, tries::Int = 10, wait::Real = 0.05)
    tmp = string(file, ".", getpid(), "-", rand(UInt32), ".tmp")
    write(tmp, text)
    try
        for attempt in 1:tries
            try
                move(tmp, file; force = true)
                return file
            catch e
                (e isa Base.IOError || e isa SystemError) && attempt < tries || rethrow()
                sleep(wait)
            end
        end
    finally
        rm(tmp; force = true)
    end
end

# A rename that replaces `to` at once: never deletes it first or copies (as `mv` does after a
# failed rename), so `to` is always one whole file
_rename(from, to; force = true) = Base.rename(from, to)

"""
Writes `text` to `file` like `_write_atomic` (`tries` renames with `move`, `wait` seconds apart),
or overwrites `file` in place if all of them fail: Windows can not replace a file that another
process has open, also the client of a shared drive that keeps a file open for a while after it
read it, but it can write into it. The new text is written over the old one before the rest is cut
off, so a reader at that moment sees a mix that does not parse, never an empty file. A `file` that
does not exist is not created here: the error of the rename is thrown.
"""
function _write_or_overwrite(file, text; move = _rename, tries::Int = 10, wait::Real = 0.05)
    try
        _write_atomic(file, text; move, tries, wait)
    catch e
        (e isa Base.IOError || e isa SystemError) && isfile(file) || rethrow()
        open(file, "r+") do io
            n = write(io, text)
            truncate(io, n)
        end
    end
    return file
end

#=
The project file: the versions the project was saved with and the packages of its own code
=#

"""
Writes the project file of the project in the folder `dir` (see [`project_marker`](@ref); a new one
is `<folder name>.bmo`), keeping what it has: `format`, `name` (the module name `name` if it has
none), `[versions]` raised to the versions of BeamletOptics, BeamletOpticsProjects and `packages` in
this session (the higher of the recorded and the installed version per package), and `[packages]`
the packages that the own code in `src/` uses now (see `_used_packages`), each with the higher of
its recorded and its installed version. Writes the file only if its content changes, so that the
watchers of the folder see no change of a save that changed no version. Returns its path.
"""
function _update_marker(dir, name, packages)
    file = project_marker(dir)
    old = _read_marker(dir)
    data = Dict{String, Any}(old)
    get!(data, "format", FORMAT)
    own = get(data, "name", nothing)
    (own isa AbstractString && !isempty(own)) || (data["name"] = own = String(name))
    versions = _string_table(get(data, "versions", nothing))
    for m in unique!(Module[BMO, @__MODULE__, packages...])
        v = pkgversion(m)
        isnothing(v) && continue
        k = string(nameof(m))
        versions[k] = _raised(get(versions, k, ""), string(v))
    end
    data["versions"] = versions
    recorded = _string_table(get(data, "packages", nothing))
    data["packages"] = Dict{String, String}(k => _raised(get(recorded, k, ""), _used_version(k))
                                            for k in _used_packages(dir, (own, String(name))))
    (isfile(file) && data == old) && return file
    _write_or_overwrite(file, _marker_text(file, data); tries = 20, wait = 0.1)
    return file
end

# The higher of the versions `a` and `b` (strings); one that is no version (e.g. `""`) loses
function _raised(a::AbstractString, b::AbstractString)
    va, vb = _version_or_nothing(a), _version_or_nothing(b)
    isnothing(va) && return isnothing(vb) ? String(a) : String(b)
    isnothing(vb) && return String(a)
    return vb > va ? String(b) : String(a)
end

"""
The version of the package `name` in this session as a string, `""` if it is not known: of a loaded
package of that name, else of the package that the active environment has (see
`_installed_version`).
"""
function _used_version(name::AbstractString)
    for m in Base.loaded_modules_array()
        string(nameof(m)) == name || continue
        v = pkgversion(m)
        isnothing(v) || return string(v)
    end
    _, v = _installed_version(name)
    return isnothing(v) ? "" : string(v)
end

# Names in `using` and `import` that are no packages of `[packages]`
const _NOT_PACKAGES = ("Base", "Core", "Main")

"""
The file of `src/` that holds the project's code for the window (e.g. `card_rows` of its own
types): the GUI includes it into the module of the project after the rest, [`load_project`](@ref)
never does, and the packages it uses (the GUI, Makie) are not the project's `[packages]`. It counts
for [`project_stamp`](@ref) like any file of `src/`.
"""
const _GUI_FILE = "gui.jl"

"""
The names of the packages that the own code of the project in the folder `dir` uses: the first name
of every `using` and `import` in the `.jl` files of `src/` (without files and folders whose name
starts with `.`, as for [`project_stamp`](@ref), and without `src/gui.jl`, the window's part, see
`_GUI_FILE`), without relative ones (`using .X`), `Base`, `Core`, `Main`, BeamletOptics,
BeamletOpticsProjects and the names `own` (the project's own module). A file that does not parse is
skipped.
"""
function _used_packages(dir, own)
    names = Set{String}()
    src = joinpath(dir, "src")
    isdir(src) || return names
    for (root, dirs, files) in walkdir(src)
        filter!(d -> !startswith(d, '.'), dirs)
        for f in files
            (startswith(f, '.') || !endswith(f, ".jl")) && continue
            (root == src && f == _GUI_FILE) && continue
            ex = try
                Meta.parseall(read(joinpath(root, f), String); filename = f)
            catch e
                e isa InterruptException && rethrow()
                continue
            end
            _collect_imports!(names, ex)
        end
    end
    setdiff!(names, (_NOT_PACKAGES..., string(nameof(BMO)), string(nameof(@__MODULE__)), own...))
    return names
end

# Adds the first name of every `using` and `import` in the expression `ex` to `names`
function _collect_imports!(names, ex)
    ex isa Expr || return names
    if ex.head === :using || ex.head === :import
        for a in ex.args
            root = _import_root(a)
            isnothing(root) || push!(names, root)
        end
    elseif ex.head !== :quote
        foreach(a -> _collect_imports!(names, a), ex.args)
    end
    return names
end

# The first name of the path of one argument of `using`/`import` (`A.B: c`, `A as B`), `nothing`
# for a relative path (`.X`)
function _import_root(a)
    a isa Expr || return nothing
    (a.head === :(:) || a.head === :as) && return _import_root(a.args[1])
    (a.head === :. && !isempty(a.args)) || return nothing
    r = a.args[1]
    return r isa Symbol && r !== :. ? String(r) : nothing
end
