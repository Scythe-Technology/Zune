--!strict
--!native
--!optimize 2

local udp = require("@self/udp");
local tcp = require("@self/tcp");

local net = {};

net.udp = udp;
net.tcp = tcp;

return net;
