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

end
