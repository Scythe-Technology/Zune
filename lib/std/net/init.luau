--!strict
--!native
--!optimize 2

local udp = require("./udp");
local tcp = require("./tcp");

local net = {};

net.udp = udp;
net.tcp = tcp;

return net;
