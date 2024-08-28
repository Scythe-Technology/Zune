export type ServerRequest = {
    method : string,
    path : string,
    headers : {[string] : string},
    body : string,
};

export type ServerResponse = string | {
    status : number,
    headers : {[string] : string},
    body : string,
}

export type ServerWebSocketHandlers = {
    --[[
        Function to check if the request should be upgraded to a websocket.
        Should return true if the request should be upgraded.
        @return boolean
    ]]
    upgrade : ((request: ServerRequest) -> boolean)?,

    --[[
        A function event for when a websocket is opened.
        
        *`WebSocket` class will keep the same reference per connection*.
    ]]
    open : ((websocket: NetWebSocket) -> ())?,
    --[[
        A function event for when a websocket receives a message.

        *`WebSocket` class will keep the same reference per connection*.
    ]]
    message : ((websocket: NetWebSocket, message: string) -> ())?,
    --[[
        A function event for when a websocket is closed.

        *`WebSocket` class will keep the same reference per connection*.
    ]]
    close : ((websocket: NetWebSocket) -> ())?,
};

export type ServeOptions = {
    --[[
        The port to bind to.
    ]]
    port : number,

    --[[
        The address to bind to.
        - Default: `0.0.0.0`
    ]]
    address : string?,

    --[[
        Whether to reuse the address.
        - Useful for multi-threaded servers.
        
        Default: `false`
    ]]
    reuseAddress : boolean?,

    --[[
        The function to handle requests.
    ]]
    request : (request: ServerRequest) -> ServerResponse,

    --[[
        Functions to handle websockets.
    ]]
    webhook : ServerWebSocketHandlers?,
};

export type Response = {
    ok : boolean,
    statusCode : number,
    statusReason : string,
    headers : {[string] : string},
    body : string,
};

type BareRequestOptions = {
    method : "GET",
    headers : {[string] : string}?,

    --[[
        Whether to follow redirects.
        - Default: `true`
    ]]
    allowRedirects : boolean?,
};

type BodyRequestOptions = {
    method : "POST" | "PUT" | "DELETE",
    headers : {[string] : string}?,
    body : string,
};

export type RequestOptions = BareRequestOptions & BodyRequestOptions;

local network = {};

--[[
    Starts a server on the specified port.

    @param options The options for the server.
    @return boolean Whether the server started successfully.
    @return string | NetServerHandle The error message, or the server handle.
]]
network.serve = (nil :: any) :: (options: ServeOptions) -> (boolean, string | NetServerHandle);

--[[
    Makes a request to the specified host.

    Optional options, defaults to GET request.

    *TLS is supported*.

    @param host The host to make the request to.
    @param options The options for the request.
    @return boolean Whether the request was successful.
    @return Response
]]
network.request = (nil :: any) :: (host: string, options: RequestOptions?) -> (boolean, string | Response);

--[[
    Creates a websocket client.

    *TLS is not supported, yet.*

    @param host The host to connect to.
    @param protocols The protocols to use.
    @return boolean Whether the connection was successful.
    @return NetClientWebSocket
]]
network.websocket = (nil :: any) :: (host: string, protocols: {string}?) -> (boolean, string | NetClientWebSocket);

return network;
