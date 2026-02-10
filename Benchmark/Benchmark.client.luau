local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Compiled = require(ReplicatedStorage.Shared.NetRay.Client)
local Entities = require(ReplicatedStorage.Entities)
local Blink = require(ReplicatedStorage.Shared.Blink.Client)

local amountFrames = 3000
local firesPerFrame = 50
local runs = 5

local entityCount = #Entities

task.wait(2)

local BlinkEvent = Blink.MyEvent
local NetRayEvent = Compiled.Gameplay.CarsUpdateStruct

local function runBench(fireFn)
	local starttime = os.clock()
	local totalClock = 0

	for frame = 1, amountFrames do
		local t0 = os.clock()
		for i = 1, firesPerFrame do
			local idx = ((i - 1) % entityCount) + 1
			fireFn(Entities[idx])
		end
		totalClock += os.clock() - t0
		task.wait()
	end
	
	print("Total Send time: "..os.clock()-starttime)
	return totalClock / amountFrames
end

local function average(arr)
	local sum = 0
	for i = 1, #arr do
		sum += arr[i]
	end
	return sum / #arr
end

local function median(arr)
	local tmp = table.clone(arr)
	table.sort(tmp)
	local n = #tmp
	if n % 2 == 1 then
		return tmp[(n + 1) // 2]
	else
		return (tmp[n // 2] + tmp[n // 2 + 1]) * 0.5
	end
end

local blinkResults = table.create(runs)
local netrayResults = table.create(runs)

print("=== Benchmark Start (Struct Payload) ===")

for run = 1, runs do
	print(("-- Run %d --"):format(run))

	blinkResults[run] = runBench(function(car)
		BlinkEvent.Fire(car)
	end)
	print("Blink:", string.format("%.6f", blinkResults[run]))

	task.wait(2)

	netrayResults[run] = runBench(function(car)
		NetRayEvent.Fire(car)
		Compiled.Stats.GetReliableQueueSize()
	end)
	print("NetRay:", string.format("%.6f", netrayResults[run]))
	

	local function dump(label)
		local f = _G[label .. "_FLUSHES"] or 0
		local b = _G[label .. "_FLUSH_BYTES"] or 0
		print(label .. " flushes:", f, "avg bytes/flush:", f > 0 and (b / f) or 0)
	end
	
	dump("__BL")
	dump("__NR")

	task.wait(3)
end

print("=== Final Stats ===")
print("Blink Avg  :", string.format("%.6f", average(blinkResults)))
print("Blink Med  :", string.format("%.6f", median(blinkResults)))
print("NetRay Avg :", string.format("%.6f", average(netrayResults)))
print("NetRay Med :", string.format("%.6f", median(netrayResults)))