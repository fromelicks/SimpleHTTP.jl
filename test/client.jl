
module ClientTest

using ..ServerTest: User, UserNotFoundError
using SimpleHTTP
using UUIDs: uuid4, UUID

cfg = ClientConfig(
    url = "http://0.0.0.0:8080/api/v1/test",
    exceptions = Dict{Int, Type{<:Exception}}(
        404 => UserNotFoundError
    )
)

Client.@post(
    cfg,
    "/users/create",
    create_user(name::JsonField{String}, age::JsonField{Int})::UUID
)

Client.@delete(
    cfg,
    "/users/delete/{id}",
    delete_user(id::UUID)::Nothing,
)

Client.@post(
    cfg,
    "/users/set_age/{id}",
    set_age(id::UUID, age::Int)::Nothing
)

Client.@get(
    cfg,
    "/users/get/{id}",
    get_user(id::UUID)::User
)

end
