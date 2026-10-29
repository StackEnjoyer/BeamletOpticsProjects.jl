#=
The setup of a project as text: the versions, the participants, per system the chains of ids along
its beams with the distances and its detector readings, and the objects without a system
=#

"""How far from the object of `around` an object is shown by [`look`](@ref) [m]."""
const _AROUND = 0.05

"""How many different chains of ids [`look`](@ref) shows per source at most."""
const _MAX_CHAINS = 8

"""
    look(project; around = nothing, io = stdout) -> String

Prints the setup of `project` as text to `io` and returns the text, for agents that can not see
the window. Each system is traced as with [`trace`](@ref) (this changes the beams and detector
hits of the objects). The sections:

- **Environment**: the installed versions of BeamletOptics and BeamletOpticsProjects, with those
  the project pins in its `Project.toml`, the path of BeamletOptics and the Julia version.
- **Participants**: the people and agents in `.bmo/presence-*.toml` (see `read_presences`): id, name,
  kind, the id they work on and what they do. A file without an integer `beat` is not listed. Whether
  a participant is still there is not shown: that needs the time at which a reader saw its `beat`
  change (`alive`).
- **Systems**: per `@system` its members and sources, then one line per chain of ids along a
  branch of a beam, e.g. `B1 → L1 (50.0 mm) → M1 (50.0 mm) → D1 (20.0 mm)`: the distance to each
  object is measured from where the beam left the previous one (the path inside an object is not
  shown), `out` is a ray that leaves the system, `?` an object without an id. Branches with the
  same chain are one line (`×n`, with the distances of the first); at most $(_MAX_CHAINS) chains per
  source. Then the hits and the power of each detector (see `trace`; `rays, no power` for the hits of
  rays, which carry none). A source with a label is shown with it, e.g. `sources [B1 "Pump"]`. A
  detector in several systems shows in each only the hits of the sources of that system.
- **Free objects**: the components and sources that belong to no system, with their positions.

`around = :L3` restricts the output to the objects whose position is within 50 mm of the one of
`L3` (listed with their distances) and to the chains of beams through one of them. Throws a
`KeyError` if there is no object `around`.
"""
function look(p::Project; around::Union{Nothing, Symbol} = nothing, io::IO = stdout)
    near = isnothing(around) ? nothing : _near(p, around)
    buf = IOBuffer()
    println(buf, "Project ", p.name, " at ", p.path)
    _look_environment(buf, p)
    _look_participants(buf, p)
    if !isnothing(near)
        println(buf, "Around ", around, " (within ", _mm(_AROUND), ")")
        for (id, d) in near
            println(buf, "  ", id, " ", _label_text(p, id), "at ", _mm(d))
        end
    end
    # in the latest world, see `trace`
    Base.invokelatest(_look_systems, buf, p, isnothing(near) ? nothing : Set(first.(near)))
    _look_free(buf, p, isnothing(near) ? nothing : Set(first.(near)))
    text = String(take!(buf))
    print(io, text)
    return text
end

"""`d` [m] in mm with one decimal, e.g. `"50.0 mm"`."""
_mm(d::Real) = string(round(1e3 * d; digits = 1), " mm")

"""The power `P` [W] with 4 significant digits and a prefix, e.g. `"0.98 mW"`."""
function _power_text(P::Real)
    P = round(P; sigdigits = 4)
    P == 0 && return "0 W"
    for (f, unit) in ((1, "W"), (1e3, "mW"), (1e6, "µW"), (1e9, "nW"))
        abs(P) * f >= 1 && return string(round(P * f; sigdigits = 4), " ", unit)
    end
    return string(round(P * 1e12; sigdigits = 4), " pW")
end

"""The label of the entry, system or group `id` of `p` in quotes and a space, `""` if it has none."""
function _label_text(p::Project, id::Symbol)
    for x in Iterators.flatten((p.entries, p.systems, p.groups))
        x.name === id && return isnothing(x.label) ? "" : string(repr(x.label), " ")
    end
    return ""
end

"""
The readable ids `names` of `p` with each group replaced by its members, recursively: the
components that the names stand for.
"""
function _leaf_names(p::Project, names)
    out = Symbol[]
    for n in names
        i = findfirst(g -> g.name === n, p.groups)
        isnothing(i) ? push!(out, n) : append!(out, _leaf_names(p, p.groups[i].members))
    end
    return out
end

"""A member `m` of a system for `look`: its id and label, a group with its members in parentheses."""
function _member_text(p::Project, m::Symbol)
    text = rstrip(string(m, " ", _label_text(p, m)))
    i = findfirst(g -> g.name === m, p.groups)
    isnothing(i) && return text
    return string(text, " (", join((_member_text(p, x) for x in p.groups[i].members), ", "), ")")
end

"""The position of `obj` [m], `nothing` if it has none."""
_position(@nospecialize(obj)) = applicable(BMO.position, obj) ? Vector{Float64}(BMO.position(obj)) : nothing

"""
The ids of the entries of `p` whose position is within `_AROUND` of the object `id`, with their
distances, nearest first.
"""
function _near(p::Project, id::Symbol)
    center = _position(p[id])
    isnothing(center) && throw(ArgumentError("the object $id has no position"))
    out = Pair{Symbol, Float64}[]
    for e in p.entries
        pos = _position(e.object)
        isnothing(pos) && continue
        d = norm(pos - center)
        d <= _AROUND && push!(out, e.name => d)
    end
    return sort!(out; by = last)
end

"""The id of every object of `p` by identity, also of the objects inside a group (its id)."""
function _object_ids(p::Project)
    ids = IdDict{Any, Symbol}()
    add!(@nospecialize(obj), id) = begin
        ids[obj] = id
        obj isa BMO.AbstractObjectGroup && foreach(o -> add!(o, id), BMO.objects(obj))
    end
    foreach(e -> add!(e.object, e.name), p.entries)
    return ids
end

function _look_environment(io, p::Project)
    compat = Dict{String, Any}()
    toml = project_file(p, "Project.toml")
    isfile(toml) && (compat = get(TOML.parsefile(toml), "compat", compat))
    pinned(m) = (c = get(compat, string(nameof(m)), nothing); isnothing(c) ? "" : " (project: $c)")
    println(io, "Environment")
    println(io, "  BeamletOptics ", pkgversion(BMO), pinned(BMO), " at ", pkgdir(BMO))
    println(io, "  BeamletOpticsProjects ", pkgversion(@__MODULE__), pinned(@__MODULE__))
    println(io, "  Julia ", VERSION)
    return nothing
end

# The participants by `read_presences`, with the age of their presence file by its time of change
# and the clock of this machine (the windows instead note when they saw the `beat` change, see
# `alive`): one older than its `ttl` is likely gone, e.g. a window that was not closed
function _look_participants(io, p::Project; now::Real = time())
    println(io, "Participants")
    people = read_presences(p.path)
    for id in sort!(collect(keys(people)))
        d = people[id]
        line = string("  ", id, ": ", d["name"], " (", d["kind"], ")")
        selected = get(d, "selected_ids", nothing)
        if selected isa AbstractVector && length(selected) > 1
            line *= string(" at ", join(selected, ", "))
        elseif !isempty(d["selected_id"])
            line *= string(" at ", d["selected_id"])
        end
        isempty(d["doing"]) || (line *= string(" · ", d["doing"]))
        age = round(Int, max(0.0, now - mtime(presence_file(p.path, id))))
        line *= string(" · last beat ", age, " s ago", age > d["ttl"] ? " (likely gone)" : "")
        println(io, line)
    end
    isempty(people) && println(io, "  none")
    return nothing
end

"""The branches of `segments`: the indices of the segments from a root to each leaf."""
function _branches(segments)
    out = Vector{Int}[]
    for (i, s) in enumerate(segments)
        s.leaf || continue
        branch = Int[]
        j = i
        while j != 0
            push!(branch, j)
            j = segments[j].parent
        end
        push!(out, reverse!(branch))
    end
    return out
end

"""
The hops of a branch: the id of each object it hits (`"?"` without an id, `"out"` for a final ray)
with the distance from where it left the previous object [m]; consecutive hits of one object are
one hop.
"""
function _hops(segments, branch, ids)
    hops = Pair{String, Float64}[]
    d = 0.0
    prev = nothing
    for i in branch
        s = segments[i]
        if s.final
            push!(hops, "out" => NaN)
            break
        end
        obj = s.object
        if !isnothing(prev) && obj === prev
            d = 0.0     # inside the same object: measure from where the beam leaves it
            continue
        end
        d += s.s_stop - s.s_start
        push!(hops, (isnothing(obj) ? "?" : string(get(ids, obj, "?"))) => d)
        d = 0.0
        prev = obj
    end
    return hops
end

"""The first line of the message of `err`, of the error inside it for an error of a task."""
function _first_line(err)
    while err isa CompositeException || err isa TaskFailedException
        err = err isa CompositeException ? first(err.exceptions) : err.task.result
    end
    return first(split(sprint(showerror, err), '\n'))
end

_hop_text(h::Pair{String, Float64}) = isnan(h.second) ? h.first : string(h.first, " (", _mm(h.second), ")")

function _look_systems(io, p::Project, near)
    println(io, "Systems")
    isempty(p.systems) && println(io, "  none")
    ids = _object_ids(p)
    near_ids = isnothing(near) ? nothing : Set(String.(near))
    for s in p.systems
        shown = isnothing(near) || any(in(near), _leaf_names(p, s.members)) || any(in(near), s.sources)
        lines = String[]
        result = try
            _trace_sources(p, s; flen = 0.1)
        catch err
            push!(lines, string("    trace failed: ", _first_line(err)))
            nothing
        end
        if !isnothing(result)
            for (src, segments) in result
                chains = Dict{Vector{String}, Tuple{Vector{Pair{String, Float64}}, Int}}()
                order = Vector{String}[]
                for b in _branches(segments)
                    hops = _hops(segments, b, ids)
                    key = first.(hops)
                    isnothing(near) || String(src) in near_ids || any(in(near_ids), key) || continue
                    if haskey(chains, key)
                        chains[key] = (chains[key][1], chains[key][2] + 1)
                    else
                        chains[key] = (hops, 1)
                        push!(order, key)
                    end
                end
                for key in first(order, _MAX_CHAINS)
                    hops, n = chains[key]
                    line = join([String(src); _hop_text.(hops)], " → ")
                    push!(lines, string("    ", line, n > 1 ? "   ×$n" : ""))
                end
                length(order) > _MAX_CHAINS &&
                    push!(lines, string("    … ", length(order) - _MAX_CHAINS, " more chains of ", src))
            end
            for (id, r) in sort!(collect(_detector_readout(p, s)); by = first)
                isnothing(near) || id in near || continue
                push!(lines, string("    ", id, ": hits ", r.hits, " · ", isnothing(r.power) ? "rays, no power" : _power_text(r.power)))
            end
        end
        shown || !isempty(lines) || continue
        members = join((_member_text(p, m) for m in s.members), ", ")
        head = string("  ", s.name, " ", _label_text(p, s.name), "= [", members, "]")
        head *= isempty(s.sources) ? ", no sources" : string(", sources [", join((rstrip(string(b, " ", _label_text(p, b))) for b in s.sources), ", "), "]")
        println(io, head, s.static ? ", static" : "")
        foreach(l -> println(io, l), lines)
    end
    return nothing
end

function _look_free(io, p::Project, near)
    used = Set{Symbol}()
    for s in p.systems
        union!(used, s.members, _leaf_names(p, s.members), s.sources)
    end
    # Inside a group: shown with the outermost group
    inside = Set{Symbol}(m for g in p.groups for m in g.members)
    free = [e for e in p.entries if !(e.name in used) && !(e.name in inside) && (isnothing(near) || e.name in near)]
    groups = [g for g in p.groups if !(g.name in used) && !(g.name in inside) &&
              (isnothing(near) || any(in(near), _leaf_names(p, g.members)))]
    println(io, "Free objects")
    isempty(free) && isempty(groups) && println(io, "  none")
    at_text(pos) = isnothing(pos) ? "" : string("at (", join(round.(1e3 .* pos; digits = 1), ", "), ") mm")
    for e in free
        println(io, "  ", e.name, " ", _label_text(p, e.name), e.kind, " ", at_text(_position(e.object)))
    end
    for g in groups
        println(io, "  ", _member_text(p, g.name), " group, pivot ", at_text(collect(g.pos)))
    end
    return nothing
end
