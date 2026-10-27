module TestParticipants

using BeamletOptics, BeamletOpticsProjects
using BeamletOpticsProjects: person, presence_file, session_file, write_presence, read_presences, alive
using TOML
using Test

@testset "person" begin
    withenv("BMO_PERSON" => "Ada Lovelace", "USERNAME" => "x", "USER" => "y") do
        me = person()
        @test me.name == "Ada Lovelace"
        @test me.host == gethostname()
        @test me.id == replace("Ada_Lovelace@$(gethostname())", r"[^A-Za-z0-9_.@-]" => "_")
        @test occursin(r"^[A-Za-z0-9_.@-]+$", me.id)
    end
    withenv("BMO_PERSON" => nothing, "USERNAME" => "ux", "USER" => "uy") do
        @test person().name == "ux"
    end
    withenv("BMO_PERSON" => nothing, "USERNAME" => nothing, "USER" => "uy") do
        @test person().name == "uy"
    end
    withenv("BMO_PERSON" => nothing, "USERNAME" => nothing, "USER" => nothing) do
        @test person().name == "someone"
    end
    withenv("BMO_PERSON" => "  ") do
        @test person().name == "someone"
    end
end

@testset "files of a participant" begin
    dir = mktempdir()
    @test presence_file(dir, "ada@pc") == joinpath(dir, ".bmo", "presence-ada@pc.toml")
    @test session_file(dir, "ada@pc") == joinpath(dir, ".bmo", "session-ada@pc.md")
end

@testset "write_presence" begin
    dir = mktempdir()
    file = presence_file(dir, "ada@pc")
    @test write_presence(dir, "ada@pc", Dict(:name => "Ada", "selected_id" => "L1", "beat" => 99)) == 1
    @test isfile(file) && !isfile(file * ".tmp")
    data = TOML.parsefile(file)
    @test data["name"] == "Ada" && data["selected_id"] == "L1" && data["beat"] == 1
    # The beat continues the counter of the file
    @test write_presence(dir, "ada@pc", Dict("name" => "Ada")) == 2
    @test TOML.parsefile(file)["beat"] == 2
    # A file that does not parse starts again at 1
    write(file, "beat = ")
    @test write_presence(dir, "ada@pc", Dict("name" => "Ada")) == 1
end

@testset "read_presences" begin
    dir = mktempdir()
    write_presence(dir, "ada@pc", Dict("name" => "Ada", "kind" => "person", "ttl" => 60, "extra" => 3))
    write_presence(dir, "bob@pc", Dict("ttl" => 1.0e6, "selected" => 5))
    write_presence(dir, "eve@pc", Dict("ttl" => -1))
    bmo = joinpath(dir, ".bmo")
    write(joinpath(bmo, "presence-half@pc.toml"), "name = \"Ha")       # half written
    write(joinpath(bmo, "presence-nobeat@pc.toml"), "name = \"N\"\n")  # no beat
    write(joinpath(bmo, "presence-strbeat@pc.toml"), "beat = \"1\"\n")
    write(joinpath(bmo, "session-ada@pc.md"), "hello")
    write(joinpath(bmo, "other.toml"), "beat = 1\n")
    ps = read_presences(dir)
    @test Set(keys(ps)) == Set(["ada@pc", "bob@pc", "eve@pc"])
    a = ps["ada@pc"]
    @test a["name"] == "Ada" && a["kind"] == "person" && a["ttl"] === 60.0 && a["beat"] === 1
    @test a["extra"] == 3
    @test a["selected"] == "" && a["selected_id"] == "" && a["doing"] == "" && a["written"] == "" &&
          a["host"] == ""
    b = ps["bob@pc"]
    @test b["name"] == "bob@pc" && b["kind"] == "person"  # defaults
    @test b["ttl"] === 3600.0                              # clamped
    @test b["selected"] == ""                              # not a string
    @test ps["eve@pc"]["ttl"] === 60.0                     # invalid: the default
    write_presence(dir, "tiny@pc", Dict("ttl" => 0.5))
    @test read_presences(dir)["tiny@pc"]["ttl"] === 5.0
    # Without the own file
    @test !haskey(read_presences(dir; except = "ada@pc"), "ada@pc")
    @test haskey(read_presences(dir; except = "ada@pc"), "bob@pc")
    # A folder without .bmo
    @test isempty(read_presences(mktempdir()))
end

@testset "alive" begin
    o = (; seen_at = 100.0, ttl = 60.0)
    @test alive(o, 100.0) && alive(o, 159.9)
    @test !alive(o, 160.0) && !alive(o, 1000.0)
    agent = (; seen_at = 100.0, ttl = 600.0)
    @test alive(agent, 400.0) && !alive(o, 400.0)
end

@testset "announce and leave" begin
    dir = mktempdir()
    new_project(dir; name = "Bench")
    id = announce(dir; name = "Claude (Opus 5.5)", doing = "aligning", selected_id = :L1)
    @test id == "Claude__Opus_5.5_@agent"
    file = presence_file(dir, id)
    @test isfile(file)
    d = read_presences(dir)[id]
    @test d["name"] == "Claude (Opus 5.5)" && d["kind"] == "agent" && d["ttl"] === 600.0
    @test d["selected_id"] == "L1" && d["doing"] == "aligning" && d["beat"] == 1
    @test d["host"] == gethostname()
    # Without a write, `written` is not claimed
    @test d["written"] == ""
    write(joinpath(dir, "src", "Extra.jl"), "f() = 1
")
    announce(dir; name = "Claude (Opus 5.5)", wrote = true)
    d = read_presences(dir)[id]
    @test d["beat"] == 2 && d["written"] == project_stamp(dir) && d["selected_id"] == ""
    # A later call without a write keeps the stamp of the own last write, not the files now
    stamp = d["written"]
    write(joinpath(dir, "src", "Other.jl"), "g() = 2
")
    @test project_stamp(dir) != stamp
    announce(dir; name = "Claude (Opus 5.5)", doing = "looking at L2")
    d = read_presences(dir)[id]
    @test d["beat"] == 3 && d["written"] == stamp && d["doing"] == "looking at L2"
    # The same for any kind
    pid = announce(dir; name = "Ada", kind = "person", ttl = 60, wrote = true)
    d = read_presences(dir)[pid]
    @test pid == "Ada@agent" && d["kind"] == "person" && d["ttl"] === 60.0 &&
          d["written"] == project_stamp(dir)
    leave(dir; name = "Claude (Opus 5.5)")
    @test !isfile(file) && haskey(read_presences(dir), pid)
    leave(dir; name = "Claude (Opus 5.5)")  # a missing file is fine
    @test !haskey(read_presences(dir), id)
end

end
