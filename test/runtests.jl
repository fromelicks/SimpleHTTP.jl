
using SimpleHTTP
using Test


include("server.jl")
include("client.jl")

import UUIDs: uuid4, UUID
import .ServerTest: UserNotFoundError
import .ClientTest as App
server = Server.serve!(ServerTest.cfg)

struct UnexpectedSuccess <: Exception
    msg::String
end

macro exception(expr)
    return esc(:(
        try
            $expr
            throw(UnexpectedSuccess("Exception expected!"))
        catch e
            e isa UnexpectedSuccess && rethrow()
            e
        end
    ))
end

@testset "basic tests" begin
    invalid_id = UUID(0)
    server_ex = @exception ServerTest.get_user(invalid_id)
    client_ex = @exception App.get_user(invalid_id)
    @test server_ex == client_ex
    @test server_ex.msg == "User id $invalid_id not found"
    id = App.create_user("Dave", 40)
    user = App.get_user(id)
    @test user.name == "Dave"
    @test user.age == 40
    @test App.get_all_users() == Dict(id => user)
    @test App.set_age(id, 20) === nothing
    @test App.get_user(id).age == 20
    @test App.delete_user(id) === nothing
end

