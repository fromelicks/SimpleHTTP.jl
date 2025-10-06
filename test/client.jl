
module ClientTest

using ..ServerTest: User, UserNotFoundError
using SimpleHTTP
using UUIDs: uuid4, UUID

const cfg = ClientConfig(
    url = "http://0.0.0.0:8080/api/v1/test",
)

const exceptions = Dict{Int, Type{<:Exception}}(
    404 => UserNotFoundError
)

Client.@post(
    cfg,
    "/users/create",
    create_user(name::JsonField{String}, age::JsonField{Int})::UUID,
    exceptions
)

Client.@delete(
    cfg,
    "/users/delete/{id}",
    delete_user(id::UUID)::Nothing,
    exceptions
)

Client.@post(
    cfg,
    "/users/set_age/{id}",
    set_age(id::UUID, age::Int)::Nothing,
    exceptions
)

Client.@get(
    cfg,
    "/users/get/{id}",
    get_user(id::UUID)::User,
    exceptions
)

end
