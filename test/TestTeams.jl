module TestTeams

using BeamletOptics, BeamletOpticsProjects
using TOML
using Test

const P = BeamletOpticsProjects

const LENS = "SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)"
lens(id, y; uid = lowercase(String(id))) =
    "@component $id = $LENS pos = (0.0, $y, 0.0)" * (isnothing(uid) ? "" : " uid = \"$uid\"")
beam(id) = "@source $id = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6) uid = \"$(lowercase(String(id)))\""
sys(id, members, sources = String[]) =
    "@system $id = [$(join(members, ", "))]" *
    (isempty(sources) ? "" : " sources = [$(join(sources, ", "))]") * " uid = \"$(lowercase(String(id)))\""

"""Writes `system.jl` of the project in `dir` from its `lines`."""
write_system(dir, lines...) = write(joinpath(dir, "system.jl"), join(lines, "\n") * "\n")

"""A project in a new folder from the `lines` of its `system.jl`, with own code in `src/`."""
function project_dir(lines...)
    dir = joinpath(mktempdir(), "Bench")
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n")
    write(joinpath(dir, "src", "Bench.jl"), "module Bench\nend\n")
    write_system(dir, lines...)
    return dir
end

entry(p, uid) = only(e for e in p.entries if e.uid == uid)
system(p, name) = only(s for s in p.systems if s.name === name)

@testset "fork_team and teams" begin
    dir = project_dir(lens(:L1, 0.1), beam(:B1), sys(:S1, ["L1"], ["B1"]))
    @test teams(dir) == String[]
    draft = fork_team(dir, "t1"; by = "anna", goal = "align L1")
    @test draft == joinpath(dir, ".bmo", "drafts", "t1")
    for f in ("system.jl", "Project.toml", joinpath("src", "Bench.jl"))
        @test read(joinpath(draft, f), String) == read(joinpath(dir, f), String)
        @test read(joinpath(draft, "base", f), String) == read(joinpath(dir, f), String)
    end
    @test isdir(joinpath(draft, "board")) && isdir(joinpath(draft, "claims"))
    team = TOML.parsefile(joinpath(draft, "team.toml"))
    @test team["by"] == "anna" && team["goal"] == "align L1" && haskey(team, "created")
    @test load_project(draft)[:L1] isa BeamletOptics.AbstractObject
    @test teams(dir) == ["t1"]
    @test_throws ArgumentError fork_team(dir, "t1"; by = "ben")
    @test_throws ArgumentError fork_team(dir, "../x"; by = "ben")
    # A draft that is not forked completely (no team.toml) is no team
    mkpath(joinpath(dir, ".bmo", "drafts", "half"))
    @test teams(dir) == ["t1"]
end

@testset "fork_team: two processes, one wins" begin
    dir = project_dir(lens(:L1, 0.1))
    go = joinpath(dir, "go")
    code = """
    using BeamletOpticsProjects
    write(ARGS[2] * "-" * ARGS[3], "")
    while !isfile(ARGS[2]); sleep(0.01); end
    try
        fork_team(ARGS[1], "race"; by = ARGS[3])
        print("won")
    catch e
        e isa ArgumentError || rethrow()
        print("lost")
    end
    """
    cmd(by) = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code $dir $go $by`
    tasks = [Threads.@spawn read(cmd(by), String) for by in ("anna", "ben")]
    # Both start forking when both have loaded the package
    t = time()
    while !(isfile(go * "-anna") && isfile(go * "-ben")) && time() - t < 300
        sleep(0.05)
    end
    write(go, "")
    @test sort(fetch.(tasks)) == ["lost", "won"]
    @test teams(dir) == ["race"]
end

@testset "board" begin
    draft = fork_team(project_dir(lens(:L1, 0.1)), "t1"; by = "anna")
    @test board(draft) == Dict{String, Any}[]
    @test post!(draft; by = "anna", kind = :task, text = "move L1", data = Dict(:ids => [:L1])) == 1
    @test post!(draft; by = "worker 2", kind = :done) == 2
    @test isfile(joinpath(draft, "board", "1-anna-task.toml"))
    @test isfile(joinpath(draft, "board", "2-worker_2-done.toml"))
    b = board(draft)
    @test [e["n"] for e in b] == [1, 2]
    @test b[1]["by"] == "anna" && b[1]["kind"] == "task" && b[1]["text"] == "move L1"
    @test b[1]["data"] == Dict("ids" => ["L1"])
    @test b[2]["by"] == "worker 2" && b[2]["text"] == ""
    # A file that does not parse is left out
    write(joinpath(draft, "board", "3-x-data.toml"), "not toml = = ")
    @test length(board(draft)) == 2
    rm(joinpath(draft, "board", "3-x-data.toml"))
    # Two tasks post at the same time: every number once
    tasks = [Threads.@spawn [post!(draft; by, kind = :data) for _ in 1:15] for by in ("a", "b")]
    ns = reduce(vcat, fetch.(tasks))
    @test sort(ns) == 3:32
    @test [e["n"] for e in board(draft)] == 1:32
end

@testset "claim! and release!" begin
    draft = fork_team(project_dir(lens(:L1, 0.1)), "t1"; by = "anna")
    @test claim!(draft; by = "anna", ids = [:L1, :L2])
    @test TOML.parsefile(joinpath(draft, "claims", "l1.toml"))["by"] == "anna"
    # Held by another: fails, and claims none of its ids
    @test !claim!(draft; by = "ben", ids = [:L3, :L2])
    @test !isfile(joinpath(draft, "claims", "id_L3.toml"))
    @test claim!(draft; by = "ben", ids = [:L3])
    # Its own claims again
    @test claim!(draft; by = "anna", ids = [:L1, :L4])
    release!(draft; by = "anna")
    @test sort(readdir(joinpath(draft, "claims"))) == ["id_L3.toml"]
    @test claim!(draft; by = "ben", ids = [:L1, :L2])
    # Two tasks claim the same id at the same time: one gets it
    for i in 1:10
        id = Symbol("X", i)
        tasks = [Threads.@spawn claim!(draft; by, ids = [id]) for by in ("a", "b")]
        @test count(fetch.(tasks)) == 1
    end
end

@testset "wait_for" begin
    draft = fork_team(project_dir(lens(:L1, 0.1)), "t1"; by = "anna")
    t = time()
    @test wait_for(draft; kind = :done, timeout = 0.3) === nothing
    @test time() - t >= 0.3
    post!(draft; by = "ben", kind = :done, text = "first")
    @test wait_for(draft; kind = :done, timeout = 0)["text"] == "first"
    # Only entries after `after`, and of the kind
    poster = @async (sleep(0.6); post!(draft; by = "ben", kind = :data);
                     post!(draft; by = "ben", kind = :done, text = "second"))
    e = wait_for(draft; kind = :done, after = 1, timeout = 10)
    @test e["text"] == "second" && e["n"] == 3
    wait(poster)
    # A number that is taken but whose entry is not written yet: the entries after it wait for it
    mkdir(joinpath(draft, "board", ".seq", "4"))
    @test post!(draft; by = "ben", kind = :done, text = "fifth") == 5
    @test wait_for(draft; kind = :done, after = 3, timeout = 0) === nothing
    write(joinpath(draft, "board", "4-anna-done.toml"), "by = \"anna\"\nkind = \"done\"\ntext = \"fourth\"\n")
    @test wait_for(draft; kind = :done, after = 3, timeout = 0)["text"] == "fourth"
    @test wait_for(draft; kind = :done, after = 4, timeout = 0)["text"] == "fifth"
    # An entry that does not parse is on the board, though not returned: the run goes on after it
    mkdir(joinpath(draft, "board", ".seq", "6"))
    write(joinpath(draft, "board", "6-x-done.toml"), "not toml = = ")
    @test wait_for(draft; kind = :done, after = 5, timeout = 0) === nothing
    @test post!(draft; by = "ben", kind = :done, text = "seventh") == 7
    @test wait_for(draft; kind = :done, after = 5, timeout = 0)["text"] == "seventh"
end

@testset "claim!: ids in sorted order" begin
    # Two that claim overlapping ids in other orders meet at the first of them in sorted order: a
    # claim that fails there leaves no claim of its own (only its temporary file came and went)
    draft = fork_team(project_dir(lens(:L1, 0.1)), "t1"; by = "anna")
    @test claim!(draft; by = "ben", ids = [:A1])
    dir = joinpath(draft, "claims")
    @test !claim!(draft; by = "anna", ids = [:Z9, :A1])
    @test readdir(dir) == ["id_A1.toml"]
end

@testset "merge_draft!" begin
    base = (lens(:L1, 0.1), lens(:L2, 0.2), lens(:L5, 0.5), beam(:B1), sys(:S1, ["L1", "L2", "L5"], ["B1"]))
    dir = project_dir(base...)
    save_version(dir; message = "start")
    draft = fork_team(dir, "t1"; by = "anna")
    # Nothing changed: nothing taken, no version
    @test merge_draft!(dir, "t1") == (; taken = String[], conflicts = String[])
    @test length(versions(dir)) == 1
    # The team moves L1 and L2, adds L3 (its id is taken meanwhile) to S1, removes L5, adds L6 (a
    # line without uid) and the system S2
    write_system(draft, lens(:L1, 0.15), lens(:L2, 0.25), lens(:L3, 0.3; uid = "team-l3"),
        lens(:L6, 0.6; uid = nothing), beam(:B1), sys(:S1, ["L1", "L2", "L3"], ["B1"]),
        sys(:S2, ["L1", "L6"]))
    # Meanwhile the project moves L2 otherwise and adds an own L3 to S1
    write_system(dir, lens(:L1, 0.1), lens(:L2, 0.22), lens(:L5, 0.5), lens(:L3, 0.33), beam(:B1),
        sys(:S1, ["L1", "L2", "L5", "L3"], ["B1"]))
    r = merge_draft!(dir, "t1")
    @test r.conflicts == ["l2"]
    @test r.taken == sort(["l1", "l5", "team-l3", "id:L6", "s1", "s2"])
    p = load_project(dir)
    @test entry(p, "l1").pos == (0.0, 0.15, 0.0)
    # The conflict is not written
    @test entry(p, "l2").pos == (0.0, 0.22, 0.0)
    @test !any(e -> e.uid == "l5", p.entries)
    @test entry(p, "l3").name === :L3
    new = entry(p, "team-l3")
    @test !(new.name in (:L1, :L2, :L3, :L5, :L6)) && new.pos == (0.0, 0.3, 0.0)
    l6 = only(e for e in p.entries if e.name === :L6)
    @test !isnothing(l6.uid)
    @test Set(system(p, :S1).members) == Set([:L1, :L2, :L3, new.name])
    @test system(p, :S1).sources == [:B1]
    @test system(p, :S2).members == [:L1, :L6]
    @test startswith(versions(dir)[1].message, "Team t1: ")
    # The draft stays
    @test teams(dir) == ["t1"] && occursin("team-l3", read(joinpath(draft, "system.jl"), String))
    @test_throws ArgumentError merge_draft!(dir, "t2")
end

@testset "merge_draft!: readable ids that both give" begin
    # Both add a system S2
    dir = project_dir(lens(:L1, 0.1), lens(:L2, 0.2), sys(:S1, ["L1"]))
    save_version(dir; message = "start")
    draft = fork_team(dir, "t1"; by = "anna")
    write_system(draft, lens(:L1, 0.1), lens(:L2, 0.2), sys(:S1, ["L1"]),
        "@system S2 = [L2] uid = \"team-s2\"")
    write_system(dir, lens(:L1, 0.1), lens(:L2, 0.2), sys(:S1, ["L1"]), "@system S2 = [L1] uid = \"live-s2\"")
    r = merge_draft!(dir, "t1")
    @test r.taken == ["team-s2"] && isempty(r.conflicts)
    p = load_project(dir)
    @test only(s for s in p.systems if s.uid == "live-s2").name === :S2
    s = only(s for s in p.systems if s.uid == "team-s2")
    @test s.name !== :S2 && s.members == [:L2]
    # The draft has the id of the project, so the next merge takes nothing
    @test only(s for s in load_project(draft).systems if s.uid == "team-s2").name === s.name
    @test merge_draft!(dir, "t1") == (; taken = String[], conflicts = String[])

    # The draft renames L2 to L7 while the project adds an L7
    dir = project_dir(lens(:L1, 0.1), lens(:L2, 0.2), sys(:S1, ["L1", "L2"]))
    save_version(dir; message = "start")
    draft = fork_team(dir, "t1"; by = "anna")
    write_system(draft, lens(:L1, 0.1), lens(:L7, 0.2; uid = "l2"), sys(:S1, ["L1", "L7"]))
    write_system(dir, lens(:L1, 0.1), lens(:L2, 0.2), lens(:L7, 0.7; uid = "live-l7"), sys(:S1, ["L1", "L2"]))
    r = merge_draft!(dir, "t1")
    @test r.taken == ["l2"] && isempty(r.conflicts)
    p = load_project(dir)
    @test entry(p, "live-l7").name === :L7
    l2 = entry(p, "l2").name
    @test !(l2 in (:L1, :L2, :L7))
    @test Set(system(p, :S1).members) == Set([:L1, l2])
    # Also in the draft, where its system names it
    d = load_project(draft)
    @test entry(d, "l2").name === l2 && system(d, :S1).members == [:L1, l2]
end

@testset "merge_draft!: again" begin
    dir = project_dir(lens(:L1, 0.1), lens(:L2, 0.2), lens(:L5, 0.5), sys(:S1, ["L1", "L2"]))
    save_version(dir; message = "start")
    draft = fork_team(dir, "t1"; by = "anna")
    # The team adds L3 (the project has an own L3 meanwhile) and moves L1 and L2; the project moves
    # L2 otherwise and L5
    write_system(draft, lens(:L1, 0.15), lens(:L2, 0.25), lens(:L3, 0.3; uid = "team-l3"),
        lens(:L5, 0.5), sys(:S1, ["L1", "L2", "L3"]))
    write_system(dir, lens(:L1, 0.1), lens(:L2, 0.22), lens(:L3, 0.33), lens(:L5, 0.55),
        sys(:S1, ["L1", "L2"]))
    r = merge_draft!(dir, "t1")
    @test r.taken == ["l1", "s1", "team-l3"] && r.conflicts == ["l2"]
    new = entry(load_project(dir), "team-l3").name
    @test new !== :L3
    # Nothing changed since: nothing taken, the conflict stays
    n = length(versions(dir))
    @test merge_draft!(dir, "t1") == (; taken = String[], conflicts = ["l2"])
    @test length(versions(dir)) == n
    # The team moves its L3 again: only that is taken, and the project keeps its L5
    write_system(draft, replace(read(joinpath(draft, "system.jl"), String),
        "pos = (0.0, 0.3, 0.0)" => "pos = (0.0, 0.31, 0.0)"))
    @test merge_draft!(dir, "t1") == (; taken = ["team-l3"], conflicts = ["l2"])
    p = load_project(dir)
    @test entry(p, "team-l3").name === new && entry(p, "team-l3").pos == (0.0, 0.31, 0.0)
    @test entry(p, "l5").pos == (0.0, 0.55, 0.0) && entry(p, "l2").pos == (0.0, 0.22, 0.0)
    @test entry(p, "l1").pos == (0.0, 0.15, 0.0)
    @test versions(dir)[1].message == "Team t1: moved $new"
    # Both agree on L2 now: no conflict any more, nothing to take
    write_system(dir, replace(read(joinpath(dir, "system.jl"), String),
        "pos = (0.0, 0.22, 0.0)" => "pos = (0.0, 0.25, 0.0)"))
    @test merge_draft!(dir, "t1") == (; taken = String[], conflicts = String[])
end

@testset "merge_draft!: again, with lines without a machine id" begin
    dir = project_dir(lens(:L1, 0.1), sys(:S1, ["L1"]))
    save_version(dir; message = "start")
    draft = fork_team(dir, "t1"; by = "anna")
    # The team adds L6 and S2 without uid; the project gives them one when it saves them
    write_system(draft, lens(:L1, 0.1), lens(:L6, 0.6; uid = nothing), sys(:S1, ["L1", "L6"]),
        "@system S2 = [L1]")
    @test merge_draft!(dir, "t1").taken == ["id:L6", "id:S2", "s1"]
    # The draft gets the machine ids that the project gave them
    p, d = load_project(dir), load_project(draft)
    l6(q) = only(e for e in q.entries if e.name === :L6)
    @test !isnothing(l6(p).uid) && l6(d).uid == l6(p).uid
    @test !isnothing(system(p, :S2).uid) && system(d, :S2).uid == system(p, :S2).uid
    # Nothing changed since: nothing taken, the project is not written again
    stamp = project_stamp(dir)
    @test merge_draft!(dir, "t1") == (; taken = String[], conflicts = String[])
    @test project_stamp(dir) == stamp
    # The project moves L6 meanwhile: it keeps that, and nothing is taken
    write_system(dir, replace(read(joinpath(dir, "system.jl"), String),
        "pos = (0.0, 0.6, 0.0)" => "pos = (0.0, 0.66, 0.0)"))
    @test merge_draft!(dir, "t1") == (; taken = String[], conflicts = String[])
    @test only(e for e in load_project(dir).entries if e.name === :L6).pos == (0.0, 0.66, 0.0)
end

@testset "merge_draft!: own code" begin
    dir = project_dir(lens(:L1, 0.1))
    write(joinpath(dir, "src", "Optics.jl"), "# optics\n")
    save_version(dir; message = "start")
    draft = fork_team(dir, "t1"; by = "anna")
    # The team writes a function in its code and a line that calls it, and changes Optics.jl,
    # which the project changes too
    write(joinpath(draft, "src", "Bench.jl"),
        "module Bench\nusing BeamletOptics\nexport team_lens\nteam_lens() = $LENS\nend\n")
    write(joinpath(draft, "src", "Optics.jl"), "# team\n")
    write(joinpath(dir, "src", "Optics.jl"), "# person\n")
    write_system(draft, lens(:L1, 0.1), "@component L2 = team_lens() pos = (0.0, 0.2, 0.0) uid = \"l2\"")
    r = merge_draft!(dir, "t1")
    @test r.taken == ["l2", "src/Bench.jl"] && r.conflicts == ["src/Optics.jl"]
    @test read(joinpath(dir, "src", "Bench.jl"), String) == read(joinpath(draft, "src", "Bench.jl"), String)
    @test read(joinpath(dir, "src", "Optics.jl"), String) == "# person\n"
    @test entry(load_project(dir), "l2").object isa BeamletOptics.AbstractObject
    @test versions(dir)[1].message == "Team t1: added L2; own code changed"
    # A draft that changes only code
    write(joinpath(draft, "src", "Bench.jl"),
        "module Bench\nusing BeamletOptics\nexport team_lens\nteam_lens() = $LENS # v2\nend\n")
    @test merge_draft!(dir, "t1") == (; taken = ["src/Bench.jl"], conflicts = ["src/Optics.jl"])
    @test occursin("# v2", read(joinpath(dir, "src", "Bench.jl"), String))
    @test versions(dir)[1].message == "Team t1: own code changed"
end

@testset "merge_draft!: the version names only the team's changes" begin
    dir = project_dir(lens(:L1, 0.1), lens(:L2, 0.2))
    save_version(dir; message = "start")
    draft = fork_team(dir, "t1"; by = "anna")
    write_system(draft, lens(:L1, 0.1), lens(:L2, 0.2), lens(:L3, 0.3; uid = "l3"))
    # The person moves L1 and saves no version
    write_system(dir, lens(:L1, 0.12), lens(:L2, 0.2))
    @test merge_draft!(dir, "t1").taken == ["l3"]
    @test versions(dir)[1].message == "Team t1: added L3"
end

end
