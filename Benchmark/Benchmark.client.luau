local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Compiled = require(ReplicatedStorage.Shared.NetRay.Client)
local Entities = require(ReplicatedStorage.Entities)
local Blink = require(ReplicatedStorage.Shared.Blink.Client)

local BlinkEvent = Blink.MyEvent
local NetRayEvent = Compiled.MyEvent

local BlinkPing = Blink.Ping
local NetRayPing = Compiled.Ping

local amountFrames = 3000
local firesPerFrame = 50

local CFG = {
	runs = 5,

	durationSec = 8,
	firesPerStep = 200,
	yieldEverySteps = 1,

	pingSamples = 60,
	pingWarmup = 5,
	pingGapSec = 0.02,
}

local entityCount = #Entities

local function avg(a)
	local s = 0
	for i = 1, #a do s += a[i] end
	return #a > 0 and (s / #a) or 0
end

local function med(a)
	local t = table.clone(a)
	table.sort(t)
	local n = #t
	if n == 0 then return 0 end
	if n % 2 == 1 then
		return t[(n + 1) // 2]
	end
	return (t[n // 2] + t[n // 2 + 1]) * 0.5
end

local function pctl(a, p)
	local t = table.clone(a)
	table.sort(t)
	local n = #t
	if n == 0 then return 0 end
	local k = math.clamp(math.floor((n - 1) * p + 1.5), 1, n)
	return t[k]
end

local function fmtBytesPerSec(bps)
	local mb = 1024 * 1024
	local kb = 1024
	if bps >= mb then
		return string.format("%.2f MB/s", bps / mb)
	elseif bps >= kb then
		return string.format("%.2f KB/s", bps / kb)
	end
	return string.format("%.0f B/s", bps)
end

local function fmtMbps(bps)
	return string.format("%.2f Mbps", (bps * 8) / 1e6)
end

local function snapBL()
	return (_G.__BL_FLUSHES or 0), (_G.__BL_FLUSH_BYTES or 0)
end

local function snapNR()
	return (_G.__NR_FLUSHES or 0), (_G.__NR_FLUSH_BYTES or 0)
end

local function runLoad(label, fireFn, snapFn)
	local f0, b0 = snapFn()
	local tStart = os.clock()

	local cpu = 0
	local steps = 0
	local sent = 0

	while (os.clock() - tStart) < CFG.durationSec do
		local t0 = os.clock()
		for _ = 1, CFG.firesPerStep do
			local idx = ((sent % entityCount) + 1)
			fireFn(Entities[idx])
			sent += 1
		end
		cpu += (os.clock() - t0)

		steps += 1
		if CFG.yieldEverySteps > 0 and (steps % CFG.yieldEverySteps == 0) then
			RunService.Heartbeat:Wait()
		end
	end

	local elapsed = os.clock() - tStart
	local f1, b1 = snapFn()

	local flushes = f1 - f0
	local bytes = b1 - b0
	local bytesPerSec = elapsed > 0 and (bytes / elapsed) or 0
	local msgsPerSec = elapsed > 0 and (sent / elapsed) or 0
	local cpuPerMsg = sent > 0 and (cpu / sent) or 0

	print(("%s Throughput: %.0f msg/s  BW: %s (%s)  CPU/msg: %.6f ms  flushes: %d")
		:format(label, msgsPerSec, fmtBytesPerSec(bytesPerSec), fmtMbps(bytesPerSec), cpuPerMsg * 1000, flushes))

	return {
		msgsPerSec = msgsPerSec,
		bytesPerSec = bytesPerSec,
		cpuPerMsg = cpuPerMsg,
	}
end

local function runFrames(label, fireFn, snapFn, amountFrames, firesPerFrame)
	local f0, b0 = snapFn()
	local start = os.clock()

	local cpu = 0
	local sent = 0

	for _ = 1, amountFrames do
		local t0 = os.clock()
		for i = 1, firesPerFrame do
			local idx = ((sent % entityCount) + 1)
			fireFn(Entities[idx])
			sent += 1
		end
		cpu += (os.clock() - t0)
		RunService.Heartbeat:Wait()
	end

	local elapsed = os.clock() - start
	local f1, b1 = snapFn()

	local bytes = b1 - b0
	local flushes = f1 - f0
	local msgsPerSec = sent / elapsed
	local bytesPerSec = bytes / elapsed
	local cpuPerMsg = cpu / sent

	print(("%s Throughput: %.0f msg/s  BW: %s (%s)  CPU/msg: %.0f ns  flushes: %d")
		:format(label, msgsPerSec, fmtBytesPerSec(bytesPerSec), fmtMbps(bytesPerSec), cpuPerMsg * 1e9, flushes))

	return { msgsPerSec = msgsPerSec, bytesPerSec = bytesPerSec, cpuPerMsg = cpuPerMsg }
end


local function runPing(label, callFn)
	for _ = 1, CFG.pingWarmup do
		pcall(function()
			local t0 = os.clock()
			callFn(t0)
		end)
		task.wait(CFG.pingGapSec)
	end

	local rtts = table.create(CFG.pingSamples)
	for i = 1, CFG.pingSamples do
		local t0 = os.clock()
		local ok = pcall(function()
			callFn(t0)
		end)
		rtts[i] = ok and (os.clock() - t0) or 0
		task.wait(CFG.pingGapSec)
	end

	local a = avg(rtts)
	local m = med(rtts)
	local p95 = pctl(rtts, 0.95)
	local p99 = pctl(rtts, 0.99)

	print(("%s RTT: avg %.2f ms  med %.2f ms  p95 %.2f ms  p99 %.2f ms")
		:format(label, a * 1000, m * 1000, p95 * 1000, p99 * 1000))
end


task.wait(2)

local lp = Players.LocalPlayer
if lp then
	print(("Roblox Ping (GetNetworkPing): %.2f ms"):format(lp:GetNetworkPing() * 1000))
end

print("=== Latency (RTT) ===")
runPing("Blink (Coroutine)", function(t0)
	return BlinkPing.Invoke(t0)
end)

runPing("NetRay (SingleSync)", function(t0)
	return NetRayPing.Call(t0)
end)

local bl = { msgsPerSec = {}, bytesPerSec = {}, cpuPerMsg = {} }
local nr = { msgsPerSec = {}, bytesPerSec = {}, cpuPerMsg = {} }

print("=== CPU / Throughput / Bandwidth ===")
for run = 1, CFG.runs do
	print(("-- Run %d --"):format(run))

	local blRes = runFrames("Blink", function(car) 
		BlinkEvent.Fire(car) 
	end, snapBL, amountFrames, firesPerFrame)


	bl.msgsPerSec[run] = blRes.msgsPerSec
	bl.bytesPerSec[run] = blRes.bytesPerSec
	bl.cpuPerMsg[run] = blRes.cpuPerMsg

	task.wait(1)

	local nrRes = runFrames("NetRay", function(car) 
		NetRayEvent.Fire(car) 
	end, snapNR, amountFrames, firesPerFrame)


	nr.msgsPerSec[run] = nrRes.msgsPerSec
	nr.bytesPerSec[run] = nrRes.bytesPerSec
	nr.cpuPerMsg[run] = nrRes.cpuPerMsg

	task.wait(2)
end

print("=== Summary ===")
local function dump(label, t)
	print(label .. " msg/s   avg: " .. string.format("%.0f", avg(t.msgsPerSec)) .. "  med: " .. string.format("%.0f", med(t.msgsPerSec)))
	print(label .. " BW avg : " .. fmtBytesPerSec(avg(t.bytesPerSec)) .. " (" .. fmtMbps(avg(t.bytesPerSec)) .. ")")
	print(label .. " BW med : " .. fmtBytesPerSec(med(t.bytesPerSec)) .. " (" .. fmtMbps(med(t.bytesPerSec)) .. ")")
	print(label .. " CPU/msg avg: " .. string.format("%.6f µs", avg(t.cpuPerMsg) * 1e6 ))
end

dump("Blink", bl)
dump("NetRay", nr)
