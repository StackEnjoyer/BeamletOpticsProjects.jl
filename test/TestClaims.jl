module TestClaims

using BeamletOptics, BeamletOpticsProjects
using TOML
using Test

const P = BeamletOpticsProjects

const LENS = "SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)"
lens(id, y) = "@component $id = $LENS pos = (0.0, $y, 0.0) uid = \"$(lowercase(String(id)))\""

"""A project folder with the lenses L1, M1, N1 (uids `l1`, `m1`, `n1`)."""
function bench()
    dir = joinpath(mktempdir(), "Bench")
    mkpath(dir)
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n")
    write(joinpath(dir, "system.jl"), join([lens(:L1, 0.1), lens(:M1, 0.2), lens(:N1, 0.3)], "\n") * "\n")
    return dir
end

claim_file(dir, key) = joinpath(dir, ".bmo", "claims", key * ".toml")

"""Runs `code` in `n` new Julia processes at once (with `dir` as `ARGS[1]`), returns their outputs."""
function processes(code, dir, n)
    cmds = [`$(Base.julia_cmd()) --project=$(Base.active_project()) -e $code $dir $i` for i in 1:n]
    outs = [Pipe() for _ in 1:n]
    procs = [run(pipeline(c; stdout = o, stderr = devnull); wait = false) for (c, o) in zip(cmds, outs)]
    foreach(o -> close(o.in), outs)
    foreach(wait, procs)
    return [strip(read(o, String)) for o in outs]
end

@testset "claims of the live project" begin
    dir = bench()
    @testset "claim, hold, refuse, release" begin
        @test claim!(dir; by = "anna@pc2", ids = [:L1])
        c = TOML.parsefile(claim_file(dir, "l1"))
        @test c["by"] == "anna@pc2" && c["id"] == "L1" && c["key"] == "l1"
        @test claims(dir) == Dict("l1" => (by = "anna@pc2", id = :L1))
        # held already: true again
        @test claim!(dir; by = "anna@pc2", ids = [:L1])
        # another: refused, and none of its ids is claimed by this call
        @test !claim!(dir; by = "ben@pc3", ids = [:M1, :L1])
        @test !isfile(claim_file(dir, "m1"))
        @test claim!(dir; by = "ben@pc3", ids = [:M1])
        # release one, then all of a holder; never the claims of another
        release!(dir; by = "ben@pc3", ids = [:L1])
        @test isfile(claim_file(dir, "l1"))
        release!(dir; by = "anna@pc2")
        @test !isfile(claim_file(dir, "l1")) && isfile(claim_file(dir, "m1"))
        release!(dir; by = "ben@pc3")
        @test isempty(claims(dir))
    end

    @testset "a claim lives as long as its holder's presence" begin
        # an agent that announced: its presence is refreshed by the claim
        announce(dir; name = "w1", ttl = 5)
        beat = TOML.parsefile(P.presence_file(dir, "w1@agent"))["beat"]
        @test claim!(dir; by = "w1", ids = [:N1])
        @test TOML.parsefile(P.presence_file(dir, "w1@agent"))["beat"] == beat + 1
        @test haskey(claims(dir), "n1")
        # its presence is not refreshed for longer than its ttl: the claim is taken over
        sleep(5.5)
        @test !haskey(claims(dir), "n1")
        @test claim!(dir; by = "ben@pc3", ids = [:N1])
        @test claims(dir)["n1"].by == "ben@pc3"
        @test !any(f -> occursin(".gone-", f), readdir(joinpath(dir, ".bmo", "claims")))
        release!(dir; by = "ben@pc3")
        leave(dir; name = "w1")
    end

    @testset "a line without uid and a renamed line" begin
        write(joinpath(dir, "system.jl"), read(joinpath(dir, "system.jl"), String) *
            "@component K1 = $LENS pos = (0.0, 0.4, 0.0)\n")
        @test claim!(dir; by = "anna@pc2", ids = [:K1])
        @test haskey(claims(dir), "id:K1")
        # the claim of L1 is by its uid: a rename of the line keeps it
        @test claim!(dir; by = "anna@pc2", ids = [:L1])
        write(joinpath(dir, "system.jl"), replace(read(joinpath(dir, "system.jl"), String), "L1 =" => "L9 ="))
        @test !claim!(dir; by = "ben@pc3", ids = [:L9])
        release!(dir; by = "anna@pc2")
    end

    @testset "two processes race for one object: exactly one gets it" begin
        code = """
            using BeamletOpticsProjects
            print(claim!(ARGS[1]; by = "p" * ARGS[2] * "@pc", ids = [:M1]))
            """
        for round in 1:3
            out = processes(code, dir, 2)
            @test count(==("true"), out) == 1 && count(==("false"), out) == 1
            # no claim file without its holder
            for f in readdir(joinpath(dir, ".bmo", "claims"); join = true)
                endswith(f, ".toml") && @test haskey(TOML.parsefile(f), "by")
            end
            foreach(i -> release!(dir; by = "p$i@pc"), 1:2)
        end
        @test !any(endswith(".tmp"), readdir(joinpath(dir, ".bmo", "claims")))
    end

    @testset "two tasks race for overlapping objects" begin
        r = fetch.([Threads.@spawn(claim!(dir; by = "t$i@pc", ids = i == 1 ? [:L1, :M1] : [:M1, :L1])) for i in 1:2])
        @test count(r) == 1
        foreach(i -> release!(dir; by = "t$i@pc"), 1:2)
    end

    @testset "save_project refuses lines claimed by another" begin
        @test claim!(dir; by = "anna@pc2", ids = [:M1])
        p = load_project(dir)
        i = findfirst(e -> e.name === :M1, p.entries)
        e = p.entries[i]
        p.entries[i] = Entry(e.kind, e.name, e.code, e.object; pos = (0.0, 0.25, 0.0), e.rot, e.pose0,
            e.meta, e.label, e.uid)
        @test_throws r"M1 is claimed by anna@pc2" save_project(p; by = "ben@pc3")
        @test occursin("pos = (0.0, 0.2, 0.0) uid = \"m1\"", read(joinpath(dir, "system.jl"), String))
        # the holder writes; without `by` nothing is checked
        save_project(p; by = "anna@pc2")
        @test occursin("pos = (0.0, 0.25, 0.0) uid = \"m1\"", read(joinpath(dir, "system.jl"), String))
        # a line that is not claimed: written
        p = load_project(dir)
        j = findfirst(e -> e.name === :N1, p.entries)
        e = p.entries[j]
        p.entries[j] = Entry(e.kind, e.name, e.code, e.object; pos = (0.0, 0.35, 0.0), e.rot, e.pose0,
            e.meta, e.label, e.uid)
        save_project(p; by = "ben@pc3")
        @test occursin("pos = (0.0, 0.35, 0.0) uid = \"n1\"", read(joinpath(dir, "system.jl"), String))
        release!(dir; by = "anna@pc2")
    end

    @testset "refresh = false leaves the presence alone" begin
        announce(dir; name = "w2")
        beat = TOML.parsefile(P.presence_file(dir, "w2@agent"))["beat"]
        @test claim!(dir; by = "w2", ids = [:N1], refresh = false)
        @test TOML.parsefile(P.presence_file(dir, "w2@agent"))["beat"] == beat
        @test claim!(dir; by = "w2", ids = [:N1])
        @test TOML.parsefile(P.presence_file(dir, "w2@agent"))["beat"] == beat + 1
        release!(dir; by = "w2")
        leave(dir; name = "w2")
    end

    @testset "claims of a team draft" begin
        draft = fork_team(dir, "t1"; by = "lead")
        @test claim!(draft; by = "w1", ids = [:L9])
        @test isfile(joinpath(draft, "claims", "l1.toml"))
        @test !claim!(draft; by = "w2", ids = [:L9])
        @test isempty(claims(dir))
        release!(draft; by = "w1")
        @test isempty(claims(draft))
    end
end

"""Sets the time of `file` to `s` seconds ago."""
function age!(file, s)
    F = Base.Filesystem
    f = F.open(file, F.JL_O_WRONLY)
    t = time() - s
    F.futime(f, t, t)
    close(f)
end

"""Moves the line of `id` in the project folder `dir` to `y` and saves it as `by`."""
function move_line!(dir, id, y; by)
    p = load_project(dir)
    i = findfirst(e -> e.name === id, p.entries)
    e = p.entries[i]
    p.entries[i] = Entry(e.kind, e.name, e.code, e.object; pos = (0.0, y, 0.0), e.rot, e.pose0,
        e.meta, e.label, e.uid)
    return save_project(p; by)
end

@testset "a line written by hand is compared by value" begin
    dir = bench()
    hand = """
        @component K1 = $LENS pos = (0.1, 0, 0) rot = (0, 0, 90) uid = "k1"
        @component K2 = $LENS pos = (0.2, 0, -0) rot = (0, -90, 0) uid = "k2"
        @component K3 = $LENS pos = (0.3, 0, 0) rot = [1 0 0; 0 1 0; 0 0 1] uid = "k3"
        @component K4 = $LENS pos = [0.4, 0, 0] rot = [0 -1 0; 1 0 0; 0 0 1] uid = "k4"
        """
    write(joinpath(dir, "system.jl"), read(joinpath(dir, "system.jl"), String) * hand)
    old = read(joinpath(dir, "system.jl"), String)
    @test claim!(dir; by = "w1", ids = [:K1, :K2, :K3, :K4])
    # Another moves M1: the save writes the lines of K1...K4 in its own way, which is no change
    move_line!(dir, :M1, 0.25; by = "ben@pc3")
    new = read(joinpath(dir, "system.jl"), String)
    @test occursin("K1 = $LENS pos = (0.1, 0.0, 0.0) rot = (0.0, 0.0, 90.0)", new)
    @test occursin("K2 = $LENS pos = (0.2, 0.0, 0.0) rot = (0.0, -90.0, 0.0)", new)
    # a matrix as angles, none for no rotation
    @test occursin("K3 = $LENS pos = (0.3, 0.0, 0.0) uid", new)
    @test occursin("K4 = $LENS pos = (0.4, 0.0, 0.0) rot = (0.0, 0.0, 90.0)", new)
    @test P._changed_keys(old, new) == Set(["m1"])
    # A change of the value is one
    @test_throws r"K1 is claimed by w1" move_line!(dir, :K1, 0.15; by = "ben@pc3")
    turned = replace(new, "90.0) uid = \"k1\"" => "91.0) uid = \"k1\"")
    @test P._changed_keys(new, turned) == Set(["k1"])
    @test P._changed_keys(new, replace(new, "(0.1, 0.0, 0.0)" => "(0.1, 0.0, 0.001)")) == Set(["k1"])
    release!(dir; by = "w1")
end

@testset "a claim by readable id holds after the line got a machine id" begin
    dir = bench()
    write(joinpath(dir, "system.jl"), read(joinpath(dir, "system.jl"), String) *
        "@component K1 = $LENS pos = (0.0, 0.4, 0.0)\n")
    @test claim!(dir; by = "w1", ids = [:K1])
    @test isfile(claim_file(dir, "id_K1"))
    # Another save gives K1 a machine id
    move_line!(dir, :N1, 0.35; by = "ben@pc3")
    uid = P._line_uids(dir)[:K1]
    @test claims(dir) == Dict(uid => (by = "w1", id = :K1))
    @test !claim!(dir; by = "ben@pc3", ids = [:K1])
    @test_throws r"K1 is claimed by w1" move_line!(dir, :K1, 0.45; by = "ben@pc3")
    # The holder claims it again, by its machine id now, and releases both by the readable id
    @test claim!(dir; by = "w1", ids = [:K1])
    @test isfile(claim_file(dir, uid))
    release!(dir; by = "w1", ids = [:K1])
    @test !isfile(claim_file(dir, "id_K1")) && !isfile(claim_file(dir, uid))
    @test isempty(claims(dir))
end

@testset "a claim of an agent whose name has other characters" begin
    dir = bench()
    name = "Claude (Opus 5.5)"
    id = announce(dir; name)
    @test id == "Claude__Opus_5.5_@agent"
    beat = TOML.parsefile(P.presence_file(dir, id))["beat"]
    @test claim!(dir; by = name, ids = [:L1])
    # the claim refreshed the presence of the agent
    @test TOML.parsefile(P.presence_file(dir, id))["beat"] == beat + 1
    # alive by its presence, also long after the claim was written
    age!(claim_file(dir, "l1"), 2 * P._CLAIM_GRACE)
    @test haskey(claims(dir), "l1")
    @test !claim!(dir; by = "ben@pc3", ids = [:L1])
    @test_throws r"L1 is claimed by Claude" move_line!(dir, :L1, 0.15; by = "ben@pc3")
    release!(dir; by = name)
    leave(dir; name)
end

@testset "a claim is taken away only if it is still the one read" begin
    dir = bench()
    file = claim_file(dir, "l1")
    # The claim of x, who is gone
    @test claim!(dir; by = "x@pc9", ids = [:L1])
    age!(file, 2 * P._CLAIM_GRACE)
    @test P._claim_stale(dir, file)
    # b takes it over; a, which found it stale before, comes late
    @test claim!(dir; by = "b@pc2", ids = [:L1])
    @test !P._take_away(file, f -> P._claim_stale(dir, f))
    @test claims(dir)["l1"].by == "b@pc2"
    # nor does a release of another take it
    @test !P._take_away(file, f -> P._claim_by(f) == "a@pc1")
    @test claims(dir)["l1"].by == "b@pc2"
    @test !claim!(dir; by = "a@pc1", ids = [:L1])
    release!(dir; by = "b@pc2")
    @test !isfile(file)
    @test !any(f -> occursin(".gone-", f), readdir(joinpath(dir, ".bmo", "claims")))
end

@testset "an unreadable claim file becomes stale" begin
    dir = bench()
    file = claim_file(dir, "m1")
    mkpath(dirname(file))
    # a writer that died between the exclusive create and the write (no hard links)
    write(file, "")
    @test !claim!(dir; by = "ben@pc3", ids = [:M1])
    @test isempty(claims(dir))
    age!(file, 2 * P._CLAIM_UNREADABLE)
    @test claim!(dir; by = "ben@pc3", ids = [:M1])
    @test claims(dir)["m1"].by == "ben@pc3"
    release!(dir; by = "ben@pc3")
end

end
