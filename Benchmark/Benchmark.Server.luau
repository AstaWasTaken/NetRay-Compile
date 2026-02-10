local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Compiled = require(ReplicatedStorage.Shared.NetRay.Server)
local Blink = require(ReplicatedStorage.Shared.Blink.Server)

Compiled.Gameplay.CarsUpdate.On(function()
end)

Blink.MyEvent.On(function()
end)