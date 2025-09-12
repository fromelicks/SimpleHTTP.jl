
module ServerTest

using SimpleHTTP

using UUIDs: uuid4, UUID
cfg = ServerConfig(
    ip = ip"0.0.0.0",
    port = 8080,
    path = "/api/v1/test",
)

mutable struct User
    id::UUID
    age::Int
    name::String
end

struct CreateUserRequest
    name::String
    age::Int
end

const users = Dict{UUID, User}()

Server.@post(
    cfg,
    "/users/create",
    function create_user(data::Json{CreateUserRequest})::UUID
        id = uuid4()
        users[id] = User(
            id,
            data.age,
            data.name,
        )
        return id
    end
)

Server.@delete(
    cfg,
    "/users/delete/{id}",
    function delete_user(id::UUID)::Nothing
        delete!(users, [id])
        return nothing
    end
)

Server.@post(
    cfg,
    "/users/set_age/{id}",
    function set_age(id::UUID, age::Int)::Nothing
        users[id].age = age
        return nothing
    end
)

Server.@get(
    cfg,
    "/users/get/{id}",
    function get_age(id::UUID)::User
        return users[id]
    end
)

end