#=
Poses: `pos` is the absolute position, `rot` the rotation since construction
=#

"""
    rotation_matrix(rot) -> Matrix{Float64}

The rotation matrix of `rot`: `(x, y, z)` angles in degrees mean `Rz(z)·Ry(y)·Rx(x)` (first about
the global x-axis, then y, then z), a matrix is taken as it is, `nothing` is the identity.
Multiples of 90° give exact matrices.
"""
rotation_matrix(::Nothing) = Matrix{Float64}(I, 3, 3)
rotation_matrix(R::AbstractMatrix) = Matrix{Float64}(R)
function rotation_matrix(rot::Tuple)
    length(rot) == 3 || throw(ArgumentError("rot needs three angles, got $(length(rot))"))
    sa, ca = sincosd(Float64(rot[1]))
    sb, cb = sincosd(Float64(rot[2]))
    sc, cc = sincosd(Float64(rot[3]))
    Rx = [1.0 0.0 0.0; 0.0 ca -sa; 0.0 sa ca]
    Ry = [cb 0.0 sb; 0.0 1.0 0.0; -sb 0.0 cb]
    Rz = [cc -sc 0.0; sc cc 0.0; 0.0 0.0 1.0]
    return Rz * Ry * Rx
end

"""
    apply_pose!(obj, pos, rot) -> obj

Poses the just constructed `obj`: rotates it by `rot` (see [`rotation_matrix`](@ref)) about its
position and moves it to `pos`. `pos` is reached exactly: the object is first moved to the
origin, which is exact, and then by `pos`. `nothing` leaves the position or orientation as it is.
"""
function apply_pose!(@nospecialize(obj), pos, rot)
    pos === nothing || reset_translation3d!(obj)
    rot === nothing || rotate3d!(obj, rotation_matrix(rot))
    pos === nothing || translate3d!(obj, Float64[pos[1], pos[2], pos[3]])
    return obj
end

"""
    frame(x) -> Matrix{Float64}

The orientation of `x`; for things with only a direction (beams) a right-handed orthonormal
frame with the local y-axis along the direction, the same as the GUI's poses.
"""
frame(@nospecialize(x)) = frame(BMO.kinematic_trait_of(x), x)
frame(::Any, @nospecialize(x)) = Matrix{Float64}(BMO.orientation(x))
frame(::BMO.Movable{BMO.Directed}, @nospecialize(x)) = direction_frame(BMO.direction(x))

"""Returns a right-handed orthonormal frame with the local y-axis along `d`."""
function direction_frame(d)
    y = normalize(Vector{Float64}(d))
    x = normalize(cross(y, abs(y[3]) < 0.9 ? [0.0, 0, 1] : [1.0, 0, 0]))
    return hcat(x, y, cross(x, y))
end

"""The pose `(position, frame)` of `x`, see [`Entry`](@ref)."""
pose_of(@nospecialize(x)) = (Vector{Float64}(BMO.position(x)), frame(x))
