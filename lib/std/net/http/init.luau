--!strict
--!native
--!optimize 2

local Server = require("@self/server");

export type ServerRequest = Server.Request;
export type ServerResponse = Server.Response;

local http = {};

http.serve = Server.serve;

return http;
