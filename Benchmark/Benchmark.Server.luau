local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Compiled = require(ReplicatedStorage.Shared.NetRay.Server)
local Blink = require(ReplicatedStorage.Shared.Blink.Server)

Compiled.MyEvent.On(function()
end)

Blink.MyEvent.On(function()
end)

Blink.Ping.On(function(player, t0)
	return t0
end)

Compiled.Ping.On(function(player, t0)
	return t0	
end)
