module TestWriteLock

using BeamletOptics, BeamletOpticsProjects
using Test

const LENS = "SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)"
lens(id, y) = "@component $id = $LENS pos = (0.0, $y, 0.0) uid = \"$(lowercase(String(id)))\""

@testset "two processes save at the same time: no lost update" begin
    dir = joinpath(mktempdir(), "Bench")
    mkpath(dir)
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n")
    write(joinpath(dir, "system.jl"), join([lens(:L1, 0.1), lens(:M1, 0.2)], "\n") * "\n")
    # Each process moves its own lens 30 times; a save that finds the files changed loads again
    code = """
        using BeamletOptics, BeamletOpticsProjects
        id = Symbol(ARGS[2])
        y0 = id === :L1 ? 0.1 : 0.2
        for k in 1:30
            while true
                p = load_project(ARGS[1])
                i = findfirst(e -> e.name === id, p.entries)
                e = p.entries[i]
                p.entries[i] = Entry(e.kind, e.name, e.code, e.object; pos = (0.0, y0 + k * 1e-3, 0.0),
                    e.rot, e.pose0, e.meta, e.label, e.uid)
                try
                    save_project(p)
                    break
                catch err
                    err isa ProjectChanged || rethrow()
                end
            end
        end
        print("done")
        """
    cmds = [`$(Base.julia_cmd()) --project=$(Base.active_project()) -e $code $dir $id` for id in ("L1", "M1")]
    outs = [Pipe() for _ in cmds]
    procs = [run(pipeline(c; stdout = o, stderr = devnull); wait = false) for (c, o) in zip(cmds, outs)]
    foreach(o -> close(o.in), outs)
    foreach(wait, procs)
    @test all(o -> read(o, String) == "done", outs)
    text = read(joinpath(dir, "system.jl"), String)
    # the last move of each is in the file: neither overwrote the other
    @test occursin("L1 = $LENS pos = (0.0, 0.13, 0.0)", text)
    @test occursin("M1 = $LENS pos = (0.0, 0.23, 0.0)", text)
    # each writer had its own temporary file, none is left
    @test !any(endswith(".tmp"), readdir(dir))
    @test !isfile(joinpath(dir, ".bmo", "write.lock"))
end

"""Sets the time of `file` to `s` seconds ago."""
function age!(file, s)
    F = Base.Filesystem
    f = F.open(file, F.JL_O_WRONLY)
    t = time() - s
    F.futime(f, t, t)
    close(f)
end

@testset "the write lock of another writer" begin
    dir = joinpath(mktempdir(), "Bench")
    mkpath(joinpath(dir, ".bmo"))
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n")
    write(joinpath(dir, "system.jl"), lens(:L1, 0.1) * "\n")
    lock = joinpath(dir, ".bmo", "write.lock")
    p = load_project(dir)
    # compiled before the times are measured
    save_project(p)
    before = read(joinpath(dir, "system.jl"), String)
    # held (e.g. by a writer on another machine): the save waits about 2 s, then ProjectChanged
    write(lock, "pc3 1234 x")
    t = @elapsed err = try
        save_project(p)
        nothing
    catch e
        e
    end
    @test err isa ProjectChanged && err.path == dir
    @test 1.9 < t < 4
    @test read(joinpath(dir, "system.jl"), String) == before
    @test read(lock, String) == "pc3 1234 x"
    # released while the save waits: it saves
    task = @async (sleep(0.3); rm(lock))
    save_project(p)
    wait(task)
    @test !isfile(lock) && p.stamp == project_stamp(dir)
    # of a writer that died: taken over after 10 s, also from another machine
    write(lock, "pc3 1234 x")
    age!(lock, 11)
    @test (@elapsed save_project(p)) < 1.5
    @test !isfile(lock)
    @test !any(f -> occursin("write.lock", f), readdir(joinpath(dir, ".bmo")))
    # a fresh lock that another put in place after a writer found the old one stale: kept
    write(lock, "pc2 5678 y")
    @test !BeamletOpticsProjects._take_away(lock, BeamletOpticsProjects._lock_stale)
    @test read(lock, String) == "pc2 5678 y"
    @test !any(f -> occursin("write.lock.gone-", f), readdir(joinpath(dir, ".bmo")))
end

end
