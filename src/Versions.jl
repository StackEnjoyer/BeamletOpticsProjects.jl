#=
Versions of a project: commits of the project folder in a git repository, via libgit2 (no git
install needed). The repository is the one that holds the folder, or a new one in the folder.
=#

"""
    save_version(dir; message = nothing) -> Union{Nothing, String}

Saves a version of the project in the folder `dir`: commits its files (respecting `.gitignore`,
also deleted files, never `.bmo/` or `.claude/skills/`) to the git repository that holds the folder, or to a new one in the folder if
there is none. Returns the id of the commit, or `nothing` if nothing changed since the last version.
`message = nothing` uses [`version_summary`](@ref), or `"Changed <files>"` if that is empty while
other files of the folder changed.

Only the files of the project folder are committed. Throws an `ArgumentError` naming them and
commits nothing if changes outside the folder are staged in the repository. Throws an
`ArgumentError` if the repository that holds the folder ignores it (e.g. by its `.gitignore`).

Known limits:

- If the folder is the root of an existing repository, all changes of that repository that are
  not ignored are committed, also files that do not belong to the project.
- On a file system that ignores case (Windows), a folder in a repository that was renamed only
  in case (e.g. `mysetup` to `MySetup`) is not found in the earlier commits: its versions are
  lost to [`versions`](@ref) and [`version_summary`](@ref).
"""
function save_version(dir::AbstractString; message::Union{Nothing, AbstractString} = nothing)
    dir = _realdir(dir)
    repo, rel = _open_repo(dir; create = true)
    try
        outside = _staged_outside(repo, rel)
        isempty(outside) || throw(ArgumentError(
            "changes outside the project folder are staged in the repository at \"" *
            LibGit2.path(repo) * "\": " * join(outside, ", ") *
            "; commit or unstage them first"))
        msg = isnothing(message) ? version_summary(dir) : String(message)
        spec = _pathspec(rel, "*")
        tree = _retry_locked(repo) do
            LibGit2.with(LibGit2.GitIndex, repo) do idx
                LibGit2.add!(idx, spec)
                LibGit2.update!(idx, spec)
                # The state of the open window (`.bmo/`) and the installed skills (`.claude/skills/`)
                # are never a part of a version, also in a project whose `.gitignore` does not
                # name them
                LibGit2.remove!(idx, _pathspec(rel, ".bmo/*"))
                LibGit2.remove!(idx, _pathspec(rel, ".claude/skills/*"))
                LibGit2.write!(idx)
                LibGit2.write_tree!(idx)
            end
        end
        head = _head(repo)
        if isnothing(head)
            LibGit2.with(LibGit2.GitTree(repo, tree)) do t
                LibGit2.count(t)
            end == 0 && return nothing
        else
            tree == LibGit2.with(LibGit2.GitCommit(repo, head)) do c
                LibGit2.with(o -> LibGit2.GitHash(o), LibGit2.GitTree(c))
            end && return nothing
        end
        isempty(strip(msg)) && (msg = "Changed " * join(_changed_files(repo, head, rel), ", "))
        sig = _signature(repo)
        id = LibGit2.commit(repo, msg; author = sig, committer = sig, tree_id = tree)
        return string(id)
    finally
        close(repo)
    end
end

"""
Runs `f()` while the index of `repo` is not locked (`index.lock`, e.g. by a save of another person
on a shared drive), trying again up to `tries` times `wait` seconds apart, also when libgit2
reports the lock; then throws an `ArgumentError`.
"""
function _retry_locked(f, repo; tries::Int = 10, wait::Real = 0.1)
    lock = joinpath(LibGit2.gitdir(repo), "index.lock")
    for attempt in 1:tries
        if !ispath(lock)
            try
                return f()
            catch e
                (e isa LibGit2.GitError && occursin("lock", lowercase(e.msg))) || rethrow()
            end
        end
        attempt < tries && sleep(wait)
    end
    throw(ArgumentError("the repository is locked by another save"))
end

"""
    version_summary(dir) -> String

What changed in the project in the folder `dir` since its last version, e.g.
`"moved L1, L3; added M4; removed D2; own code changed"`, by the lines of `system.jl` (paired by
their `uid`, else by their id) without loading the project. The kinds are `added`, `removed`,
`renamed` (same uid, other id), `moved` (only `pos` or `rot` differ), `changed` (other code,
label or further keywords) and `own code changed` (a file in `src/` that git does not ignore);
more than 6 ids of a kind are counted (`"moved 9 objects"`). `"first version"` if there is no
version yet, `""` if neither `system.jl` nor a file in `src/` changed: other files of the project
(e.g. `view.toml`, `Project.toml`) are not looked at, though [`save_version`](@ref) commits them.
Throws an `ArgumentError` if the repository that holds the folder ignores it.
"""
function version_summary(dir::AbstractString)
    dir = _realdir(dir)
    file = joinpath(dir, "system.jl")
    new = isfile(file) ? read(file, String) : ""
    r = _open_repo(dir; create = false)
    isnothing(r) && return "first version"
    repo, rel = r
    old = nothing
    oldsrc = newsrc = Dict{String, String}()
    try
        head = _head(repo)
        isnothing(head) && return "first version"
        old = _blob_text(repo, head, _subpath(rel, "system.jl"))
        oldsrc = _tree_texts(repo, head, _subpath(rel, "src"))
        newsrc = _src_texts(dir, repo, rel)
    finally
        close(repo)
    end
    isnothing(old) && return "first version"
    parts = _system_changes(old, new)
    newsrc == oldsrc || push!(parts, "own code changed")
    return join(parts, "; ")
end

"""
    versions(dir) -> Vector{@NamedTuple{id::String, time::DateTime, message::String}}

The versions of the project in the folder `dir`, newest first: the commits that change a file of
the folder, with their id, time (of the author, UTC) and message. Empty if the folder is in no
repository; throws an `ArgumentError` if the repository that holds the folder ignores it.
"""
function versions(dir::AbstractString)
    T = @NamedTuple{id::String, time::DateTime, message::String}
    out = T[]
    r = _open_repo(_realdir(dir); create = false)
    isnothing(r) && return out
    repo, rel = r
    try
        isnothing(_head(repo)) && return out
        oids = LibGit2.with(LibGit2.GitRevWalker(repo)) do walker
            # Children before their parents, also of the same second (the time of a commit has
            # whole seconds); the time only orders branches
            LibGit2.map((oid, _) -> oid, walker;
                by = LibGit2.Consts.SORT_TOPOLOGICAL | LibGit2.Consts.SORT_TIME)
        end
        for oid in oids
            LibGit2.with(LibGit2.GitCommit(repo, oid)) do c
                mine = _folder_id(repo, oid, rel)
                before = LibGit2.parentcount(c) == 0 ? nothing :
                         _folder_id(repo, LibGit2.parent_id(c, 1), rel)
                isequal(mine, before) && return nothing
                push!(out, (; id = string(oid),
                    time = unix2datetime(LibGit2.author(c).time),
                    message = String(rstrip(LibGit2.message(c)))))
                return nothing
            end
        end
    finally
        close(repo)
    end
    return out
end

# The folder as an absolute path with its real name (temporary folders on Windows have short names)
_realdir(dir) = (d = abspath(dir); isdir(d) ? realpath(d) : d)

"""
The repository that holds `dir` (searching upward) and the path of `dir` in it (`""` for its
root, `/` as separator); a new one in `dir` if there is none and `create`, else `nothing`. Throws
an `ArgumentError` if the repository ignores `dir`: nothing of it could be committed.
"""
function _open_repo(dir; create::Bool)
    repo = try
        LibGit2.GitRepoExt(dir)
    catch e
        e isa LibGit2.GitError || rethrow()
        nothing
    end
    if !isnothing(repo) && LibGit2.isbare(repo)
        close(repo)
        repo = nothing
    end
    if isnothing(repo)
        create || return nothing
        repo = LibGit2.init(dir)
    end
    # The working directory, not `path`: that is the git directory of a worktree or submodule
    root = _realdir(LibGit2.workdir(repo))
    rel = relpath(dir, root)
    rel = rel == "." ? "" : replace(rel, '\\' => '/')
    if !isempty(rel) && _ignored(repo, rel * "/")
        close(repo)
        throw(ArgumentError("the repository at \"" * root * "\" ignores the project folder \"" *
            rel * "\"; its versions can not be saved there"))
    end
    return repo, rel
end

_subpath(rel, path) = isempty(rel) ? path : rel * "/" * path

# The pathspec of `pattern` in the folder `rel`, whose glob characters are escaped
_pathspec(rel, pattern) = isempty(rel) ? pattern : _glob_escape(rel) * "/" * pattern
_glob_escape(s) = replace(s, r"([\[\]*?\\])" => s"\\\1")

# Whether git ignores `path` (relative to the root of `repo`; a folder ends with `/`)
function _ignored(repo, path)
    ignored = Ref{Cint}(0)
    LibGit2.@check ccall((:git_ignore_path_is_ignored, LibGit2.libgit2), Cint,
        (Ref{Cint}, Ptr{Cvoid}, Cstring), ignored, repo, path)
    return ignored[] == 1
end
_inside(path, rel) = isempty(rel) || startswith(path, rel * "/")

# The commit HEAD points to, `nothing` in a repository without commits
function _head(repo)
    try
        return LibGit2.GitHash(repo, "HEAD")
    catch e
        e isa LibGit2.GitError || rethrow()
        return nothing
    end
end

# The paths of the changes staged outside the folder `rel` (HEAD to index)
function _staged_outside(repo, rel)
    opts = LibGit2.StatusOptions(; show = LibGit2.Consts.STATUS_SHOW_INDEX_ONLY,
        flags = LibGit2.Consts.STATUS_OPT_SORT_CASE_SENSITIVELY)
    paths = String[]
    LibGit2.with(LibGit2.GitStatus(repo; status_opts = opts)) do st
        GC.@preserve st for i in 1:length(st)
            e = st[i]
            e.head_to_index == C_NULL && continue
            d = unsafe_load(e.head_to_index)
            for f in (d.old_file, d.new_file)
                f.path == C_NULL && continue
                p = unsafe_string(f.path)
                _inside(p, rel) || p in paths || push!(paths, p)
            end
        end
    end
    return paths
end

# The paths of the files of the folder `rel` whose staged version differs from HEAD (`nothing`)
function _changed_files(repo, head, rel)
    opts = LibGit2.StatusOptions(; show = LibGit2.Consts.STATUS_SHOW_INDEX_ONLY,
        flags = LibGit2.Consts.STATUS_OPT_SORT_CASE_SENSITIVELY)
    paths = String[]
    LibGit2.with(LibGit2.GitStatus(repo; status_opts = opts)) do st
        GC.@preserve st for i in 1:length(st)
            e = st[i]
            e.head_to_index == C_NULL && continue
            f = unsafe_load(e.head_to_index).new_file
            f.path == C_NULL && continue
            p = unsafe_string(f.path)
            _inside(p, rel) && push!(paths, isempty(rel) ? p : p[(length(rel) + 2):end])
        end
    end
    return isempty(paths) ? ["files"] : paths
end

# Author and committer: from the git config, else (for the parts it lacks) the user name of the
# system
function _signature(repo)
    try
        return LibGit2.Signature(repo)
    catch e
        e isa LibGit2.GitError || rethrow()
    end
    name = email = ""
    try
        LibGit2.with(LibGit2.GitConfig(repo)) do cfg
            name = LibGit2.get(cfg, "user.name", "")
            email = LibGit2.get(cfg, "user.email", "")
        end
    catch e
        e isa LibGit2.GitError || rethrow()
    end
    isempty(name) && (name = get(ENV, "USERNAME", get(ENV, "USER", "")))
    isempty(name) && (name = "BeamletOptics")
    isempty(email) && (email = replace(name, r"\s+" => "") * "@localhost")
    return LibGit2.Signature(name, email)
end

# The id of the tree of the folder `rel` in the commit `oid`, `nothing` if it has none
function _folder_id(repo, oid, rel)
    spec = isempty(rel) ? string(oid) * "^{tree}" : string(oid) * ":" * rel
    try
        return LibGit2.with(o -> LibGit2.GitHash(o), LibGit2.GitObject(repo, spec))
    catch e
        e isa LibGit2.GitError || rethrow()
        return nothing
    end
end

# The text of the file `path` in the commit `head`, `nothing` if it has none
function _blob_text(repo, head, path)
    try
        return LibGit2.with(LibGit2.GitBlob(repo, string(head) * ":" * path)) do b
            _text(String(LibGit2.rawcontent(b)))
        end
    catch e
        e isa LibGit2.GitError || rethrow()
        return nothing
    end
end

_text(s) = replace(s, "\r\n" => "\n")

# The texts of the files under the folder `path` of the commit `head`, by their path in the folder
function _tree_texts(repo, head, path)
    texts = Dict{String, String}()
    files = String[]
    try
        LibGit2.with(LibGit2.GitTree(repo, string(head) * ":" * path)) do tree
            LibGit2.treewalk(tree) do root, entry
                LibGit2.entrytype(entry) == LibGit2.GitBlob &&
                    push!(files, root * LibGit2.filename(entry))
                return Cint(0)
            end
        end
    catch e
        e isa LibGit2.GitError || rethrow()
        return texts
    end
    for f in files
        texts[f] = something(_blob_text(repo, head, path * "/" * f), "")
    end
    return texts
end

# The texts of the files in `src/` of the folder `dir` (at `rel` in `repo`), like `_tree_texts`;
# without the files that git ignores and does not track, which `save_version` does not commit
function _src_texts(dir, repo, rel)
    texts = Dict{String, String}()
    src = joinpath(dir, "src")
    isdir(src) || return texts
    LibGit2.with(LibGit2.GitIndex, repo) do idx
        for (root, _, files) in walkdir(src), f in files
            endswith(f, ".tmp") && continue
            path = joinpath(root, f)
            name = replace(relpath(path, src), '\\' => '/')
            p = _subpath(rel, "src/" * name)
            # A tracked file is committed even if it is ignored
            isnothing(findall(p, idx)) && _ignored(repo, p) && continue
            texts[name] = _text(read(path, String))
        end
    end
    return texts
end

"""One line of `system.jl`, parsed without evaluating it."""
struct _Line
    macroname::Symbol
    name::Symbol
    uid::Union{Nothing, String}
    code::String
    pose::Dict{Symbol, String}
    rest::Dict{Symbol, String}
end

const _LINE_MACROS = (Symbol("@component"), Symbol("@source"), Symbol("@system"), Symbol("@group"))

"""
The lines `@component`, `@source`, `@system` and `@group` of `text` and its other lines (without comments
and blank lines); `nothing` if a line does not parse.
"""
function _parse_lines(text)
    lines = _Line[]
    other = String[]
    for l in split(text, '\n')
        s = strip(l)
        (isempty(s) || startswith(s, "#")) && continue
        ex = try
            Meta.parse(s; raise = false)
        catch
            return nothing
        end
        ex isa Expr && ex.head in (:error, :incomplete) && return nothing
        if ex isa Expr && ex.head === :macrocall && ex.args[1] in _LINE_MACROS
            args = filter(a -> !(a isa LineNumberNode), ex.args[2:end])
            isempty(args) && return nothing
            all(a -> a isa Expr && a.head === :(=) && a.args[1] isa Symbol, args) ||
                return nothing
            pose = Dict{Symbol, String}()
            rest = Dict{Symbol, String}()
            uid = nothing
            for a in args[2:end]
                k, v = a.args[1]::Symbol, a.args[2]
                if k === :uid
                    uid = v isa AbstractString ? String(v) : string(v)
                elseif k in (:pos, :rot)
                    pose[k] = string(v)
                else
                    rest[k] = string(v)
                end
            end
            push!(lines, _Line(ex.args[1], args[1].args[1], uid, _line_code(args[1].args[2]),
                pose, rest))
        else
            push!(other, s)
        end
    end
    return lines, other
end

"""The parts of the summary of the changes from the text `old` of `system.jl` to `new`."""
function _system_changes(old, new)
    old, new = _text(old), _text(new)
    old == new && return String[]
    a, b = _parse_lines(old), _parse_lines(new)
    (isnothing(a) || isnothing(b)) && return ["system.jl changed"]
    pairs, added, removed = _pair(a[1], b[1])
    found = Dict{Symbol, Vector{String}}(k => String[] for k in _SUMMARY_KINDS)
    append!(found[:added], [string(x.name) for x in added])
    append!(found[:removed], [string(x.name) for x in removed])
    for (o, n) in pairs
        o.name == n.name || push!(found[:renamed], string(o.name, " to ", n.name))
        if o.macroname != n.macroname || o.code != n.code || o.rest != n.rest
            push!(found[:changed], string(n.name))
        elseif o.pose != n.pose
            push!(found[:moved], string(n.name))
        end
    end
    parts = String[]
    for k in _SUMMARY_KINDS
        ids = found[k]
        isempty(ids) && continue
        push!(parts, string(k, " ", length(ids) > 6 ? "$(length(ids)) objects" : join(ids, ", ")))
    end
    # Other statements, or only the order, comments or blank lines differ
    (sort(a[2]) == sort(b[2]) && !isempty(parts)) || push!(parts, "system.jl changed")
    return parts
end

_line_code(@nospecialize(ex)) = ex isa Union{Expr, Symbol} ? string(normalize_code(ex)) : repr(ex)

const _SUMMARY_KINDS = (:added, :removed, :renamed, :moved, :changed)
