#=
Standard guards: what a change of a project did to the setup it started from, as measurements
=#

"""
    evaluate(project; base) -> @NamedTuple{deviations, foreign_hits, clearance}

Measures what `project` changed with respect to `base`, the project it started from (e.g. loaded
from `.bmo/drafts/<name>/base`). It reports numbers and does not judge: which deviation counts as
unchanged depends on the task, so there is no tolerance or threshold. Systems and objects are
matched by their machine id (`uid`), or by their id if they have none.

- `deviations`: a `Dict` by the id of every system of `base` (traced with [`trace`](@ref) in both
  projects) with `nothing` if `project` has no such system, otherwise a named tuple:
  - `position`: the largest distance [m] between the start points or the stop points of the
    segments of the same index (`0.0` without segments). The segments of a trace are
    deterministic, hence it is exactly `0.0` for a system that was not changed.
  - `segments`: `(base = n, project = m)`, the numbers of segments; those of the same index are
    compared, a difference of the numbers is reported here.
  - `objects`: the number of segments of the same index that end on another object (compared by
    id, `nothing` for a segment that ends on nothing; an object inside a group has the id of the
    group).
  - `detectors`: for every detector of the system in either project, by its id, the change
    (`project` minus `base`) of `hits` and `power` [W]; a detector that one project lacks counts
    as having no hits and no power there. `power` is `nothing` if either side has the hits of rays,
    which carry none (see [`trace`](@ref)). For a beam group as source traced with several threads
    the change of `power` of an unchanged system can be nonzero in the last bits.
- `foreign_hits`: the segments of the sources of the systems of `project` that are not in `base`
  that end on an object of a system of `base`, as a `Vector` of `(system, source, object, at)`
  with ids and the end point `at` [m] (in the order of the systems of `project` and their
  sources).
- `clearance`: for each object of `project` that is not in `base`, the smallest distance [m]
  between its bounding sphere (`BeamletOptics.bounding_sphere_of`) and those of the objects that
  are in `base`, as a `Vector` of `(object, nearest, distance)` sorted ascending by `distance`.
  It is the distance of the surfaces of the spheres, negative if they overlap. Objects without a
  bounding sphere (`NoBoundingSphere`, e.g. sources) are left out on either side.

Tracing solves the systems and changes their objects (beams, detector hits), as `trace` does.

# Examples

```julia
r = evaluate(load_project("."); base = load_project(".bmo/drafts/t1/base"))
r.deviations[:S1].position   # 0.0: the beam of S1 was not moved
first(r.clearance)           # the new object closest to an old one
```
"""
function evaluate(p::Project; base::Project)
    return (; deviations = _deviations(p, base), foreign_hits = _foreign_hits(p, base),
        clearance = _clearance(p, base))
end

# The key of an entry or system by which projects are matched: its uid, else "id:" and its id
_match_key(x) = isnothing(x.uid) ? "id:" * String(x.name) : x.uid

"""The system of `p` that is the one called `s` in `base` (same key), or `nothing`."""
function _counterpart(p::Project, s::SystemEntry)
    k = _match_key(s)
    i = findfirst(t -> _match_key(t) == k, p.systems)
    return isnothing(i) ? nothing : p.systems[i]
end

"""The id of `obj` in `ids` (see `_object_ids`; an object inside a group has its id), or `nothing`."""
_id_of(ids, @nospecialize(obj)) = isnothing(obj) ? nothing : get(ids, obj, nothing)

# The change of the power of a detector; `nothing` if one side has no power (hits of rays)
_power_change(a, b) = (isnothing(a) || isnothing(b)) ? nothing : b - a

function _deviations(p::Project, base::Project)
    out = Dict{Symbol, Union{Nothing, NamedTuple}}()
    for s in base.systems
        t = _counterpart(p, s)
        out[s.name] = isnothing(t) ? nothing : _deviation(base, s, p, t)
    end
    return out
end

function _deviation(base::Project, s::SystemEntry, p::Project, t::SystemEntry)
    a = trace(base, s.name)
    b = trace(p, t.name)
    n = min(length(a.segments), length(b.segments))
    ids_a, ids_b = _object_ids(base), _object_ids(p)
    position = 0.0
    objects = 0
    for i in 1:n
        sa, sb = a.segments[i], b.segments[i]
        position = max(position, norm(sb.start - sa.start), norm(sb.stop - sa.stop))
        _id_of(ids_a, sa.object) === _id_of(ids_b, sb.object) || (objects += 1)
    end
    detectors = Dict{Symbol, @NamedTuple{hits::Int, power::Union{Nothing, Float64}}}()
    none = (hits = 0, power = 0.0)
    for id in union(keys(a.detectors), keys(b.detectors))
        da, db = get(a.detectors, id, none), get(b.detectors, id, none)
        detectors[id] = (hits = db.hits - da.hits, power = _power_change(da.power, db.power))
    end
    return (; position, segments = (base = length(a.segments), project = length(b.segments)),
        objects, detectors)
end

function _foreign_hits(p::Project, base::Project)
    basekeys = Set(_match_key(s) for s in base.systems)
    # the objects of p that belong to a system of base
    old = Set{Symbol}()
    for s in base.systems, id in s.members
        i = findfirst(e -> e.name === id, base.entries)
        isnothing(i) && continue
        k = _match_key(base.entries[i])
        j = findfirst(e -> _match_key(e) == k, p.entries)
        isnothing(j) || push!(old, p.entries[j].name)
    end
    hits = @NamedTuple{system::Symbol, source::Symbol, object::Symbol, at::Vector{Float64}}[]
    ids = _object_ids(p)
    for s in p.systems
        _match_key(s) in basekeys && continue
        for (src, segments) in Base.invokelatest(_trace_sources, p, s; flen = 0.1)
            for seg in segments
                id = _id_of(ids, seg.object)
                (isnothing(id) || !(id in old)) && continue
                push!(hits, (system = s.name, source = src, object = id, at = Vector{Float64}(seg.stop)))
            end
        end
    end
    return hits
end

function _clearance(p::Project, base::Project)
    basekeys = Set(_match_key(e) for e in base.entries)
    old = Tuple{Symbol, Any}[]
    new = Tuple{Symbol, Any}[]
    for e in p.entries
        sphere = _sphere(e.object)
        isnothing(sphere) && continue
        push!(_match_key(e) in basekeys ? old : new, (e.name, sphere))
    end
    out = @NamedTuple{object::Symbol, nearest::Symbol, distance::Float64}[]
    for (id, a) in new, (other, b) in old
        d = norm(a.pos - b.pos) - a.radius - b.radius
        i = findfirst(r -> r.object === id, out)
        isnothing(i) ? push!(out, (object = id, nearest = other, distance = Float64(d))) :
        d < out[i].distance && (out[i] = (object = id, nearest = other, distance = Float64(d)))
    end
    return sort!(out; by = r -> r.distance)
end

"""The bounding sphere of `obj`, or `nothing` if it has none."""
function _sphere(@nospecialize(obj))
    applicable(BMO.bounding_sphere_of, obj) || return nothing
    sphere = BMO.bounding_sphere_of(obj)
    sphere isa BMO.NoBoundingSphere ? nothing : sphere
end
