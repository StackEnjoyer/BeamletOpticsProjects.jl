#=
Tracing a system of a project without a window: its declared sources, the segments of their beams
and what its detectors received
=#

"""
    trace(project, system::Symbol; flen = 0.1) ->
        @NamedTuple{segments::Vector, detectors::Dict{Symbol, @NamedTuple{hits::Int, power::Union{Nothing, Float64}}}}

Solves the system with the id `system` of `project` (e.g. `:S1`) with the sources declared in its
`@system` line and returns what it measured:

- `segments`: the `path_segments` of each source, concatenated in the order of the sources
  (`BeamletOptics.PathSegment`: `start`, `stop` [m], `s_start`, `s_stop`, `object`, ...). A final
  ray without an intersection is `flen` [m] long.
- `detectors`: for every member of the system that is a `Detector`, by its id, the number of its
  hits (`BeamletOptics.hit_count`) and its `optical_power` [W] (`0.0` without hits). The hits of
  rays (`Beam`) carry no power: `power` is `nothing` for them, not `0.0`.

The objects keep nothing of an earlier solve: the system is initialized first (`initialize!`, which
empties its detectors), then the sources are solved one after the other, so their hits superpose
on the detectors. Only the sources of `system` are solved: a `Detector` that is also a member of
another system holds only the hits of the sources of this one, while the window traces all systems
that share a detector together and superposes their hits. Tracing again gives the same segments and
hit counts. The `power` too, except for a beam group as source (e.g. `CollimatedSource`) traced with
several threads: BeamletOptics adds the hits in the order in which its threads finish, so `power`
can differ in the last bits. The objects of the project are changed by the solve (beams, detector
hits) as with `solve_system!`.

Throws a `KeyError` if the project has no system `system`.

# Examples

```julia
p = load_project("Bench")
r = trace(p, :S1)
r.detectors[:D1]        # (hits = 1, power = 0.001)
r.segments[end].object  # the object hit at the end of the last segment
```
"""
function trace(p::Project, system::Symbol; flen::Real = 0.1)
    s = _system_entry(p, system)
    # The objects may call functions that were defined after this call started, e.g. the
    # refractive index `λ -> 1.5` of a lens in `trace(load_project("."), :S1)`
    return Base.invokelatest(_trace, p, s, flen)
end

function _trace(p::Project, s::SystemEntry, flen::Real)
    segments = reduce(vcat, (segs for (_, segs) in _trace_sources(p, s; flen));
        init = BMO.PathSegment{Float64}[])
    return (; segments, detectors = _detector_readout(p, s))
end

"""The entry of the system `name` of `p`; throws a `KeyError` if there is none."""
function _system_entry(p::Project, name::Symbol)
    for s in p.systems
        s.name === name && return s
    end
    throw(KeyError(name))
end

"""
Initializes the system of the entry `s` of `p` and solves its sources one after the other; returns
the id of each source with its path segments.
"""
function _trace_sources(p::Project, s::SystemEntry; flen::Real)
    sys = s.object
    BMO.initialize!(sys)
    out = Pair{Symbol, Vector}[]
    for id in s.sources
        src = p[id]
        BMO.solve_system!(sys, src)
        push!(out, id => BMO.path_segments(src; flen))
    end
    return out
end

"""The hits and the power of every member of the system entry `s` of `p` that is a `Detector`, by id."""
function _detector_readout(p::Project, s::SystemEntry)
    out = Dict{Symbol, @NamedTuple{hits::Int, power::Union{Nothing, Float64}}}()
    for id in s.members
        d = p[id]
        d isa BMO.Detector || continue
        n = BMO.hit_count(d)
        # the hits of rays have no power (their sum is a count without a unit)
        power = n == 0 ? 0.0 :
                eltype(BMO.hits(d)) <: BMO.AbstractRayHit ? nothing :
                Float64(BMO.optical_power(d; progress = false))
        out[id] = (hits = n, power = power)
    end
    return out
end
