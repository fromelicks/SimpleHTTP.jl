
using SimpleHTTP
using Test


include("server.jl")
include("client.jl")

import .ClientTest as App
server = Server.serve!(ServerTest.cfg)

@testset "basic tests" begin
    id = App.create_user("Dave", 40)
    user = App.get_user(id)
    @test user.name == "Dave"
    @test user.age == 40
    @test App.set_age(id, 20) === nothing
    @test App.get_user(id).age == 20
    @test App.delete_user(id) === nothing
end

