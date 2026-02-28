--!strict
-- Name: Runtime
-- Purpose: Runtime code generation (queues, listeners, dispatch, preamble)
local Version = "0.1.1"
local Ast = require(script.Parent.Parent.idl.Ast)
local Analyzer = require(script.Parent.Parent.idl.Analyzer)
local Types = require(script.Parent.Types)
local Utilities = require(script.Parent.Utilities)
local Emitters = require(script.Parent.Emitters)

type MessageInfo = Types.MessageInfo
type EmitState = Types.EmitState
type WidthInfo = Types.WidthInfo
type DecodeStructMode = Types.DecodeStructMode

local addLine = Utilities.addLine
local appendLines = Utilities.appendLines
local concat = Utilities.concat
local join = Utilities.join
local indent = Utilities.indent
local sanitizeIdentifier = Utilities.sanitizeIdentifier
local normalizeTypeKind = Utilities.normalizeTypeKind
local isValidateFull = Utilities.isValidateFull
local isValidateBasicOrFull = Utilities.isValidateBasicOrFull
local emitError = Utilities.emitError
local nextTemp = Utilities.nextTemp
local splitParams = Utilities.splitParams
local paramNames = Utilities.paramNames
local toLuauType = Utilities.toLuauType
local typedParamList = Utilities.typedParamList
local returnTypeExpr = Utilities.returnTypeExpr
local callbackTypeExpr = Utilities.callbackTypeExpr
local callableTypeExpr = Utilities.callableTypeExpr
local callbackSignatureTypeExpr = Utilities.callbackSignatureTypeExpr
local messageClientCallbackTypeName = Utilities.messageClientCallbackTypeName
local messageServerCallbackTypeName = Utilities.messageServerCallbackTypeName
local messageClientApiTypeName = Utilities.messageClientApiTypeName
local messageServerApiTypeName = Utilities.messageServerApiTypeName
local collectMessages = Utilities.collectMessages
local buildScopeTables = Utilities.buildScopeTables
local getPassthroughTypeName = Utilities.getPassthroughTypeName
local canSendEvent = Utilities.canSendEvent
local canReceiveEvent = Utilities.canReceiveEvent
local getMessageIdWidthInfo = Utilities.getMessageIdWidthInfo
local widthForBound = Utilities.widthForBound
local resolveTypeBranding = Utilities.resolveTypeBranding
local resolveDecodeStruct = Utilities.resolveDecodeStruct
local expandDecodeParams = Utilities.expandDecodeParams
local buildDecodedParamPlans = Utilities.buildDecodedParamPlans
local collectDecodedLeafNames = Utilities.collectDecodedLeafNames
local getStringBoundComment = Utilities.getStringBoundComment
local fieldAccessExpr = Utilities.fieldAccessExpr
local paramsHaveVariableLength = Utilities.paramsHaveVariableLength
local fixedBytesForCanonicalParams = Utilities.fixedBytesForCanonicalParams

local emitCodecFunctions = Emitters.emitCodecFunctions
local emitSkipFunction = Emitters.emitSkipFunction
local emitPassthroughValidator = Emitters.emitPassthroughValidator
local emitCanonicalSizeForType = Emitters.emitCanonicalSizeForType
local emitFlatTopLevelSize = Emitters.emitFlatTopLevelSize
local emitSizeForType = Emitters.emitSizeForType
local emitWriteCanonicalForType = Emitters.emitWriteCanonicalForType
local emitWriteParamsWithFixedBlocks = Emitters.emitWriteParamsWithFixedBlocks
local canEmitFlatTopLevelSize = Emitters.canEmitFlatTopLevelSize

local EMPTY_PARAMS: { Ast.Param } = {}

local function tokenPattern(name: string): string
    return ("%%f[%%w_]%s%%f[^%%w_]"):format(name)
end

local function countTokenUsages(lines: { string }, name: string): number
    local pattern = tokenPattern(name)
    local count = 0
    for index = 1, #lines do
        if string.find(lines[index], pattern) then
            count += 1
        end
    end
    return count
end

local function removeLocalAliasLine(lines: { string }, name: string)
    local pattern = ("^local %s = "):format(name)
    for index = #lines, 1, -1 do
        if string.match(lines[index], pattern) then
            table.remove(lines, index)
            return
        end
    end
end

local function removeFunctionBlock(lines: { string }, name: string)
    local startIndex: number? = nil
    local startPattern = ("^local function %s%%("):format(name)
    for index = 1, #lines do
        if string.match(lines[index], startPattern) then
            startIndex = index
            break
        end
    end
    if startIndex == nil then
        return
    end

    local depth = 1
    local endIndex = startIndex
    while endIndex < #lines and depth > 0 do
        endIndex += 1
        local trimmed = string.gsub(lines[endIndex], "^%s+", "")
        if string.match(trimmed, "^if .+ then$") or string.match(trimmed, "^for .+ do$") or string.match(trimmed, "^while .+ do$") or trimmed == "repeat" then
            depth += 1
        elseif trimmed == "end" or string.match(trimmed, "^until ") then
            depth -= 1
        end
    end

    for index = endIndex, startIndex, -1 do
        table.remove(lines, index)
    end

    if startIndex <= #lines and lines[startIndex] == "" and startIndex > 1 and lines[startIndex - 1] == "" then
        table.remove(lines, startIndex)
    end
end

local function pruneUnusedRuntimeSymbols(lines: { string })
    if countTokenUsages(lines, "VarUIntSize") <= 1 then
        removeFunctionBlock(lines, "VarUIntSize")
    end
    if countTokenUsages(lines, "WriteVarUInt") <= 1 then
        removeFunctionBlock(lines, "WriteVarUInt")
    end
    if countTokenUsages(lines, "ReadVarUInt") <= 1 then
        removeFunctionBlock(lines, "ReadVarUInt")
    end
    if countTokenUsages(lines, "writef16") <= 1 then
        removeFunctionBlock(lines, "writef16")
    end
    if countTokenUsages(lines, "readf16") <= 1 then
        removeFunctionBlock(lines, "readf16")
    end

    local aliases = {
        "DEFAULT_BATCH_CAPACITY",
        "ERR_PASS",
        "writeu8",
        "writei8",
        "writeu16",
        "writei16",
        "writeu32",
        "writei32",
        "writef16",
        "writef32",
        "writef64",
        "writestring",
        "readu8",
        "readi8",
        "readu16",
        "readi16",
        "readu32",
        "readi32",
        "readf16",
        "readf32",
        "readf64",
        "readstring",
        "band",
        "bor",
        "rshift",
        "lshift",
    }
    for index = 1, #aliases do
        local alias = aliases[index]
        if countTokenUsages(lines, alias) <= 1 then
            removeLocalAliasLine(lines, alias)
        end
    end
end

local function emitQueue(
    lines: { string },
    prefix: string,
    remoteVar: string,
    fireMethod: string,
    maxPassArgs: number,
    messageIdWidth: WidthInfo,
    _validateLevel: Analyzer.ValidateLevel
)
    local upper = string.upper(prefix)
    addLine(lines, 0, ("local %s_ARENA_CAPACITY = DEFAULT_ARENA_CAPACITY"):format(upper))
    addLine(lines, 0, ("local %s_ARENA = create(%s_ARENA_CAPACITY)"):format(upper, upper))
    addLine(lines, 0, ("local %s_CURSOR = 0"):format(upper))
    addLine(lines, 0, ("local %s_QUEUE_SIZE = 0"):format(upper))
    addLine(lines, 0, ("local %s_DROPPED = 0"):format(upper))
    if maxPassArgs > 0 then
        addLine(lines, 0, ("local %s_QUEUE_PASS_COUNT = table.create(DEFAULT_BATCH_CAPACITY, 0)"):format(upper))
        for passIndex = 1, maxPassArgs do
            addLine(lines, 0, ("local %s_QUEUE_PASS_%d = table.create(DEFAULT_BATCH_CAPACITY)"):format(upper, passIndex))
        end
    end
    local segmentHeaderBytes = messageIdWidth.bytes * 2
    local minSegmentRunCount = math.floor((segmentHeaderBytes + 1) / messageIdWidth.bytes) + 1
    local minSegmentTailBytes = (minSegmentRunCount - 1) * messageIdWidth.bytes
    addLine(lines, 0, ("local %s_SEGMENT_HEADER_BYTES = %d"):format(upper, segmentHeaderBytes))
    addLine(lines, 0, ("local %s_SEGMENT_MIN_COUNT = %d"):format(upper, minSegmentRunCount))
    addLine(lines, 0, ("local %s_SEGMENT_MIN_TAIL_BYTES = %d"):format(upper, minSegmentTailBytes))
    addLine(lines, 0, "")

    addLine(lines, 0, ("local function Flush%s()"):format(prefix))
    addLine(lines, 1, ("if %s_CURSOR == 0 then"):format(upper))
    addLine(lines, 2, ("%s_QUEUE_SIZE = 0"):format(upper))
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, ("local payloadToSend = create(%s_CURSOR)"):format(upper))
    addLine(lines, 1, ("local payloadOffset = %s_CURSOR"):format(upper))
    addLine(lines, 1, ("if %s_QUEUE_SIZE >= %s_SEGMENT_MIN_COUNT then"):format(upper, upper))
    addLine(lines, 2, "-- Only scan runs when the batch is large enough to amortize segment headers.")
    addLine(lines, 2, "local sourceOffset = 0")
    addLine(lines, 2, "payloadOffset = 0")
    addLine(lines, 2, ("while sourceOffset < %s_CURSOR do"):format(upper))
    addLine(lines, 3, "local runStart = sourceOffset")
    addLine(lines, 3, ("local messageId = %s(%s_ARENA, sourceOffset)"):format(messageIdWidth.reader, upper))
    addLine(lines, 3, ("sourceOffset += %d"):format(messageIdWidth.bytes))
    addLine(lines, 3, ("local skip = %s_SKIP[messageId]"):format(upper))
    addLine(lines, 3, ("local firstBodyEnd = skip(%s_ARENA, %s_CURSOR, sourceOffset)"):format(upper, upper))
    addLine(lines, 3, "local runEnd = firstBodyEnd")
    addLine(lines, 3, "local runCount = 1")
    addLine(lines, 3, ("if %s_CURSOR - firstBodyEnd < %s_SEGMENT_MIN_TAIL_BYTES then"):format(upper, upper))
    addLine(lines, 4, "-- Remaining bytes cannot fit enough repeated IDs to make segmentation pay off.")
    addLine(lines, 4, ("local tailSize = %s_CURSOR - runStart"):format(upper))
    addLine(lines, 4, "if tailSize > 0 then")
    addLine(lines, 5, ("copy(payloadToSend, payloadOffset, %s_ARENA, runStart, tailSize)"):format(upper))
    addLine(lines, 5, "payloadOffset += tailSize")
    addLine(lines, 4, "end")
    addLine(lines, 4, "break")
    addLine(lines, 3, "end")
    addLine(lines, 3, ("while runEnd < %s_CURSOR do"):format(upper))
    addLine(lines, 4, ("local nextMessageId = %s(%s_ARENA, runEnd)"):format(messageIdWidth.reader, upper))
    addLine(lines, 4, "if nextMessageId ~= messageId then")
    addLine(lines, 5, "break")
    addLine(lines, 4, "end")
    addLine(lines, 4, ("local nextBodyStart = runEnd + %d"):format(messageIdWidth.bytes))
    addLine(lines, 4, ("runEnd = skip(%s_ARENA, %s_CURSOR, nextBodyStart)"):format(upper, upper))
    addLine(lines, 4, "runCount += 1")
    addLine(lines, 3, "end")
    addLine(lines, 3, ("if runCount * %d > %s_SEGMENT_HEADER_BYTES + VarUIntSize(runCount) then"):format(messageIdWidth.bytes, upper))
    addLine(lines, 4, ("%s(payloadToSend, payloadOffset, SEGMENT_MARKER_ID)"):format(messageIdWidth.writer))
    addLine(lines, 4, ("payloadOffset += %d"):format(messageIdWidth.bytes))
    addLine(lines, 4, ("%s(payloadToSend, payloadOffset, messageId)"):format(messageIdWidth.writer))
    addLine(lines, 4, ("payloadOffset += %d"):format(messageIdWidth.bytes))
    addLine(lines, 4, "payloadOffset = WriteVarUInt(payloadToSend, payloadOffset, runCount)")
    addLine(lines, 4, "local copyCursor = sourceOffset")
    addLine(lines, 4, "local bodyEnd = firstBodyEnd")
    addLine(lines, 4, "while true do")
    addLine(lines, 5, "local bodySize = bodyEnd - copyCursor")
    addLine(lines, 5, "if bodySize > 0 then")
    addLine(lines, 6, ("copy(payloadToSend, payloadOffset, %s_ARENA, copyCursor, bodySize)"):format(upper))
    addLine(lines, 6, "payloadOffset += bodySize")
    addLine(lines, 5, "end")
    addLine(lines, 5, "if bodyEnd >= runEnd then")
    addLine(lines, 6, "break")
    addLine(lines, 5, "end")
    addLine(lines, 5, ("copyCursor = bodyEnd + %d"):format(messageIdWidth.bytes))
    addLine(lines, 5, ("bodyEnd = skip(%s_ARENA, %s_CURSOR, copyCursor)"):format(upper, upper))
    addLine(lines, 4, "end")
    addLine(lines, 3, "else")
    addLine(lines, 4, "local runSize = runEnd - runStart")
    addLine(lines, 4, "if runSize > 0 then")
    addLine(lines, 5, ("copy(payloadToSend, payloadOffset, %s_ARENA, runStart, runSize)"):format(upper))
    addLine(lines, 5, "payloadOffset += runSize")
    addLine(lines, 4, "end")
    addLine(lines, 3, "end")
    addLine(lines, 3, "sourceOffset = runEnd")
    addLine(lines, 2, "end")
    addLine(lines, 1, "else")
    addLine(lines, 2, "-- For tiny batches, a direct copy is cheaper than any merge scan.")
    addLine(lines, 2, ("copy(payloadToSend, 0, %s_ARENA, 0, %s_CURSOR)"):format(upper, upper))
    addLine(lines, 1, "end")
    addLine(lines, 1, ("if payloadOffset < %s_CURSOR then"):format(upper))
    addLine(lines, 2, "local compactPayload = create(payloadOffset)")
    addLine(lines, 2, "copy(compactPayload, 0, payloadToSend, 0, payloadOffset)")
    addLine(lines, 2, "payloadToSend = compactPayload")
    addLine(lines, 1, "end")

    if maxPassArgs == 0 then
        addLine(lines, 1, ("%s:%s(payloadToSend)"):format(remoteVar, fireMethod))
    else
        addLine(lines, 1, ("local messageCount = %s_QUEUE_SIZE"):format(upper))
        addLine(lines, 1, "local passCountList = table.create(messageCount, 0)")
        addLine(lines, 1, "for index = 1, messageCount do")
        addLine(lines, 2, ("passCountList[index] = %s_QUEUE_PASS_COUNT[index]"):format(upper))
        addLine(lines, 2, ("%s_QUEUE_PASS_COUNT[index] = 0"):format(upper))
        addLine(lines, 1, "end")

        local passValueLists: { string } = {}
        for passIndex = 1, maxPassArgs do
            local passListName = ("passList_%d"):format(passIndex)
            passValueLists[#passValueLists + 1] = passListName
            addLine(lines, 1, ("local %s = table.create(messageCount)"):format(passListName))
            addLine(lines, 1, "for index = 1, messageCount do")
            addLine(lines, 2, ("%s[index] = %s_QUEUE_PASS_%d[index]"):format(passListName, upper, passIndex))
            addLine(lines, 2, ("%s_QUEUE_PASS_%d[index] = nil"):format(upper, passIndex))
            addLine(lines, 1, "end")
        end

        local callArgs: { string } = { "payloadToSend", "passCountList" }
        for passIndex = 1, #passValueLists do
            callArgs[#callArgs + 1] = passValueLists[passIndex]
        end
        addLine(lines, 1, ("%s:%s(%s)"):format(remoteVar, fireMethod, join(callArgs)))
    end

    addLine(lines, 1, ("%s_CURSOR = 0"):format(upper))
    addLine(lines, 1, ("%s_QUEUE_SIZE = 0"):format(upper))
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
end

local function emitEventListener(
    lines: { string },
    isServer: boolean,
    prefix: string,
    remoteVar: string,
    maxPassArgs: number,
    messageIdWidth: WidthInfo,
    validateLevel: Analyzer.ValidateLevel
)
    local upper = string.upper(prefix)
    if isServer then
        if maxPassArgs > 0 then
            addLine(lines, 0, ("%s.OnServerEvent:Connect(function(player, payload, passCountList, ...)"):format(remoteVar))
        else
            addLine(lines, 0, ("%s.OnServerEvent:Connect(function(player, payload)"):format(remoteVar))
        end
    else
        if maxPassArgs > 0 then
            addLine(lines, 0, ("%s.OnClientEvent:Connect(function(payload, passCountList, ...)"):format(remoteVar))
        else
            addLine(lines, 0, ("%s.OnClientEvent:Connect(function(payload)"):format(remoteVar))
        end
    end
    addLine(lines, 1, "if typeof(payload) ~= \"buffer\" then")
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, "local payloadLength = len(payload)")
    addLine(lines, 1, ("if payloadLength < %d then"):format(messageIdWidth.bytes))
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    if maxPassArgs > 0 then
        local passTables: { string } = {}
        for passIndex = 1, maxPassArgs do
            passTables[#passTables + 1] = ("passTable%d"):format(passIndex)
        end
        addLine(lines, 1, ("local %s = ..."):format(join(passTables)))
    end
    addLine(lines, 1, "local offset = 0")
    if maxPassArgs > 0 then
        addLine(lines, 1, "local messageIndex = 0")
    end
    addLine(lines, 1, "while offset < payloadLength do")
    if messageIdWidth.bytes > 1 then
        addLine(lines, 2, ("if offset + %d > payloadLength then"):format(messageIdWidth.bytes))
        addLine(lines, 3, "return")
        addLine(lines, 2, "end")
    end
    addLine(lines, 2, ("local messageId = %s(payload, offset)"):format(messageIdWidth.reader))
    addLine(lines, 2, ("offset += %d"):format(messageIdWidth.bytes))
    addLine(lines, 2, "local segmentCount = 1")
    addLine(lines, 2, "local dispatch")
    addLine(lines, 2, "if messageId == SEGMENT_MARKER_ID then")
    if messageIdWidth.bytes > 1 then
        addLine(lines, 3, ("if offset + %d > payloadLength then"):format(messageIdWidth.bytes))
    else
        addLine(lines, 3, "if offset >= payloadLength then")
    end
    addLine(lines, 4, "return")
    addLine(lines, 3, "end")
    addLine(lines, 3, ("messageId = %s(payload, offset)"):format(messageIdWidth.reader))
    addLine(lines, 3, ("offset += %d"):format(messageIdWidth.bytes))
    addLine(lines, 3, ("dispatch = %s_DISPATCH[messageId]"):format(upper))
    addLine(lines, 3, "if dispatch == nil then")
    addLine(lines, 4, "return")
    addLine(lines, 3, "end")
    addLine(lines, 3, "segmentCount, offset = ReadVarUInt(payload, payloadLength, offset)")
    addLine(lines, 3, "if segmentCount < 1 then")
    addLine(lines, 4, "return")
    addLine(lines, 3, "end")
    addLine(lines, 2, "else")
    addLine(lines, 3, ("dispatch = %s_DISPATCH[messageId]"):format(upper))
    addLine(lines, 3, "if dispatch == nil then")
    addLine(lines, 4, "return")
    addLine(lines, 3, "end")
    addLine(lines, 2, "end")
    addLine(lines, 2, "for _segmentIndex = 1, segmentCount do")
    if maxPassArgs > 0 then
        addLine(lines, 3, "messageIndex += 1")
        addLine(lines, 3, "local passCount = 0")
        addLine(lines, 3, "if type(passCountList) == \"table\" then")
        addLine(lines, 4, "local rawPassCount = passCountList[messageIndex]")
        addLine(lines, 4, "if type(rawPassCount) == \"number\" then")
        addLine(lines, 5, "passCount = rawPassCount")
        addLine(lines, 4, "end")
        addLine(lines, 3, "end")
        for passIndex = 1, maxPassArgs do
            addLine(lines, 3, ("local messagePass%d = nil"):format(passIndex))
            addLine(lines, 3, ("if type(passTable%d) == \"table\" then"):format(passIndex))
            addLine(lines, 4, ("messagePass%d = passTable%d[messageIndex]"):format(passIndex, passIndex))
            addLine(lines, 3, "end")
        end
    end

    local callArgs: { string } = {}
    if isServer then
        callArgs[#callArgs + 1] = "player"
    end
    callArgs[#callArgs + 1] = "payload"
    callArgs[#callArgs + 1] = "payloadLength"
    callArgs[#callArgs + 1] = "offset"
    if maxPassArgs > 0 then
        callArgs[#callArgs + 1] = "passCount"
    end
    for passIndex = 1, maxPassArgs do
        callArgs[#callArgs + 1] = ("messagePass%d"):format(passIndex)
    end
    addLine(lines, 3, ("local nextOffset = dispatch(%s)"):format(join(callArgs)))
    if maxPassArgs > 0 or isValidateFull(validateLevel) then
        addLine(lines, 3, "if type(nextOffset) ~= \"number\" then")
        addLine(lines, 4, "return")
        addLine(lines, 3, "end")
        addLine(lines, 3, "if nextOffset < offset or nextOffset > payloadLength then")
        addLine(lines, 4, "return")
        addLine(lines, 3, "end")
    end
    addLine(lines, 3, "offset = nextOffset")
    addLine(lines, 2, "end")
    addLine(lines, 1, "end")
    addLine(lines, 0, "end)")
    addLine(lines, 0, "")
end

local function emitFunctionInvoke(
    lines: { string },
    isServer: boolean,
    maxPassArgs: number,
    messageIdWidth: WidthInfo,
    validateLevel: Analyzer.ValidateLevel
)
    if isServer then
        addLine(lines, 0, "FunctionRemote.OnServerInvoke = function(player, payload, ...)")
    else
        addLine(lines, 0, "FunctionRemote.OnClientInvoke = function(payload, ...)")
    end
    addLine(lines, 1, "if typeof(payload) ~= \"buffer\" then")
    emitError(lines, 2, validateLevel, "Function payload must be a buffer", "ERR_TYPE")
    addLine(lines, 1, "end")
    addLine(lines, 1, "local payloadLength = len(payload)")
    addLine(lines, 1, ("if payloadLength < %d then"):format(messageIdWidth.bytes))
    emitError(lines, 2, validateLevel, "Function payload too short", "ERR_BOUNDS")
    addLine(lines, 1, "end")
    addLine(lines, 1, ("local messageId = %s(payload, 0)"):format(messageIdWidth.reader))
    addLine(lines, 1, "local dispatch = FUNCTION_DISPATCH[messageId]")
    addLine(lines, 1, "if dispatch == nil then")
    emitError(lines, 2, validateLevel, "No function dispatch for message ID", "ERR_SCHEMA")
    addLine(lines, 1, "end")
    if maxPassArgs > 0 then
        addLine(lines, 1, "local passCount = select(\"#\", ...)")
    end
    local passArgs: { string } = {}
    for passIndex = 1, maxPassArgs do
        passArgs[#passArgs + 1] = ("pass%d"):format(passIndex)
    end
    if #passArgs > 0 then
        addLine(lines, 1, ("local %s = ..."):format(join(passArgs)))
    end
    local callArgs: { string } = {}
    if isServer then
        callArgs[#callArgs + 1] = "player"
    end
    callArgs[#callArgs + 1] = "payload"
    callArgs[#callArgs + 1] = "payloadLength"
    if maxPassArgs > 0 then
        callArgs[#callArgs + 1] = "passCount"
    end
    for passIndex = 1, maxPassArgs do
        callArgs[#callArgs + 1] = ("pass%d"):format(passIndex)
    end
    addLine(lines, 1, ("return dispatch(%s)"):format(join(callArgs)))
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
end

local function emitCommonRuntimePreamble(lines: { string }, schema: Analyzer.AnalyzedSchema, isServer: boolean)
    addLine(lines, 0, "local RunService = game:GetService(\"RunService\")")
    addLine(lines, 0, "local ReplicatedStorage = game:GetService(\"ReplicatedStorage\")")
    if isServer then
        addLine(lines, 0, "local Players = game:GetService(\"Players\")")
    end
    addLine(lines, 0, "")

    if isServer then
        addLine(lines, 0, "local function FindOrCreateRemote(className, remoteName)")
        addLine(lines, 1, "local existing = ReplicatedStorage:FindFirstChild(remoteName)")
        addLine(lines, 1, "if existing ~= nil then")
        addLine(lines, 2, "if existing.ClassName ~= className then")
        addLine(lines, 3, "error((\"Remote '%s' exists as '%s', expected '%s'\"):format(remoteName, existing.ClassName, className))")
        addLine(lines, 2, "end")
        addLine(lines, 2, "return existing")
        addLine(lines, 1, "end")
        addLine(lines, 1, "local remote = Instance.new(className)")
        addLine(lines, 1, "remote.Name = remoteName")
        addLine(lines, 1, "remote.Parent = ReplicatedStorage")
        addLine(lines, 1, "return remote")
        addLine(lines, 0, "end")
        addLine(lines, 0, "")
        addLine(lines, 0, ("local Reliable = FindOrCreateRemote(\"RemoteEvent\", %q) :: RemoteEvent"):format(schema.remoteScope .. "_RELIABLE"))
        addLine(lines, 0, ("local Unreliable = FindOrCreateRemote(\"UnreliableRemoteEvent\", %q) :: UnreliableRemoteEvent"):format(schema.remoteScope .. "_UNRELIABLE"))
        addLine(lines, 0, ("local FunctionRemote = FindOrCreateRemote(\"RemoteFunction\", %q) :: RemoteFunction"):format(schema.remoteScope .. "_FUNCTION"))
    else
        addLine(lines, 0, ("local Reliable = ReplicatedStorage:WaitForChild(%q) :: RemoteEvent"):format(schema.remoteScope .. "_RELIABLE"))
        addLine(lines, 0, ("local Unreliable = ReplicatedStorage:WaitForChild(%q) :: UnreliableRemoteEvent"):format(schema.remoteScope .. "_UNRELIABLE"))
        addLine(lines, 0, ("local FunctionRemote = ReplicatedStorage:WaitForChild(%q) :: RemoteFunction"):format(schema.remoteScope .. "_FUNCTION"))
    end

    addLine(lines, 0, "")
    addLine(lines, 0, "local function WithCount(...)")
    addLine(lines, 1, "return select(\"#\", ...), ...")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "local DEFAULT_BATCH_CAPACITY = 2048")
    addLine(lines, 0, "local DEFAULT_ARENA_CAPACITY = 65536")
    addLine(lines, 0, "local create = buffer.create")
    addLine(lines, 0, "local copy = buffer.copy")
    addLine(lines, 0, "local len = buffer.len")
    addLine(lines, 0, "local writeu8 = buffer.writeu8")
    addLine(lines, 0, "local writei8 = buffer.writei8")
    addLine(lines, 0, "local writeu16 = buffer.writeu16")
    addLine(lines, 0, "local writei16 = buffer.writei16")
    addLine(lines, 0, "local writeu32 = buffer.writeu32")
    addLine(lines, 0, "local writei32 = buffer.writei32")
    addLine(lines, 0, "local function writef16(payload, offset, value)")
    addLine(lines, 1, "local sign = 0")
    addLine(lines, 1, "if value < 0 or value == -math.huge then")
    addLine(lines, 2, "sign = 32768")
    addLine(lines, 2, "value = -value")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if value ~= value then")
    addLine(lines, 2, "writeu16(payload, offset, sign + 32256)")
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if value == math.huge then")
    addLine(lines, 2, "writeu16(payload, offset, sign + 31744)")
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if value == 0 then")
    addLine(lines, 2, "writeu16(payload, offset, sign)")
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, "local exp = math.floor(math.log(value, 2))")
    addLine(lines, 1, "local mant = value / (2 ^ exp) - 1")
    addLine(lines, 1, "local halfExp = exp + 15")
    addLine(lines, 1, "local halfMant")
    addLine(lines, 1, "if halfExp <= 0 then")
    addLine(lines, 2, "halfMant = math.floor(value / (2 ^ -24) +0.5)")
    addLine(lines, 2, "if halfMant < 0 then halfMant = 0 end")
    addLine(lines, 2, "if halfMant > 1023 then halfMant = 1023 end")
    addLine(lines, 2, "writeu16(payload, offset, sign + halfMant)")
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if halfExp >= 31 then")
    addLine(lines, 2, "writeu16(payload, offset, sign + 31744)")
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, "halfMant = math.floor(mant * 1024 +0.5)")
    addLine(lines, 1, "if halfMant >= 1024 then")
    addLine(lines, 2, "halfMant = 0")
    addLine(lines, 2, "halfExp += 1")
    addLine(lines, 2, "if halfExp >= 31 then")
    addLine(lines, 3, "writeu16(payload, offset, sign + 31744)")
    addLine(lines, 3, "return")
    addLine(lines, 2, "end")
    addLine(lines, 1, "end")
    addLine(lines, 1, "writeu16(payload, offset, sign + halfExp * 1024 + halfMant)")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "local writef32 = buffer.writef32")
    addLine(lines, 0, "local writef64 = buffer.writef64")
    addLine(lines, 0, "local writestring = buffer.writestring")
    addLine(lines, 0, "local readu8 = buffer.readu8")
    addLine(lines, 0, "local readi8 = buffer.readi8")
    addLine(lines, 0, "local readu16 = buffer.readu16")
    addLine(lines, 0, "local readi16 = buffer.readi16")
    addLine(lines, 0, "local readu32 = buffer.readu32")
    addLine(lines, 0, "local readi32 = buffer.readi32")
    addLine(lines, 0, "local function readf16(payload, offset)")
    addLine(lines, 1, "local bits = readu16(payload, offset)")
    addLine(lines, 1, "local sign = if bit32.band(bits, 32768) ~= 0 then -1 else 1")
    addLine(lines, 1, "local exp = bit32.band(bit32.rshift(bits, 10), 31)")
    addLine(lines, 1, "local mant = bit32.band(bits, 1023)")
    addLine(lines, 1, "if exp == 0 then")
    addLine(lines, 2, "if mant == 0 then")
    addLine(lines, 3, "return sign * 0")
    addLine(lines, 2, "end")
    addLine(lines, 2, "return sign * (mant / 1024) * (2 ^ -14)")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if exp == 31 then")
    addLine(lines, 2, "if mant == 0 then")
    addLine(lines, 3, "return sign * math.huge")
    addLine(lines, 2, "end")
    addLine(lines, 2, "return 0 / 0")
    addLine(lines, 1, "end")
    addLine(lines, 1, "return sign * (1 + mant / 1024) * (2 ^ (exp - 15))")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "local readf32 = buffer.readf32")
    addLine(lines, 0, "local readf64 = buffer.readf64")
    addLine(lines, 0, "local readstring = buffer.readstring")
    addLine(lines, 0, "local band = bit32.band")
    addLine(lines, 0, "local bor = bit32.bor")
    addLine(lines, 0, "local rshift = bit32.rshift")
    addLine(lines, 0, "local lshift = bit32.lshift")
    addLine(lines, 0, "")
end

local function generateRuntime(schema: Analyzer.AnalyzedSchema, isServer: boolean): string
    local validateLevel = schema.validateLevel
    local decodeStructMode = resolveDecodeStruct(schema.options)
    local messages: { MessageInfo } = {}
    local symbolByMessage: { [Analyzer.AnalyzedMessage]: string } = {}
    collectMessages(schema.root, schema.root.name, messages, symbolByMessage)
    local lines: { string } = {
        "--!strict",
        "--!native",
        "--!optimize 2",
        "--!nolint LocalShadow",
        "--#selene: allow(shadowing)",
        isServer and "-- Name: Server" or "-- Name: Client",
        isServer and "-- Purpose: Generated runtime for server networking" or "-- Purpose: Generated runtime for client networking",
        "-- Generated-by: NetRay-Compiler",
        "-- Version: "..Version,
        "",
    }

    addLine(lines, 0, "local Types = require(script.Parent.Types)")
    addLine(lines, 0, "type u8 = typeof(Types.u8)")
    addLine(lines, 0, "type i8 = typeof(Types.i8)")
    addLine(lines, 0, "type u16 = typeof(Types.u16)")
    addLine(lines, 0, "type i16 = typeof(Types.i16)")
    addLine(lines, 0, "type u32 = typeof(Types.u32)")
    addLine(lines, 0, "type i32 = typeof(Types.i32)")
    addLine(lines, 0, "type f16 = typeof(Types.f16)")
    addLine(lines, 0, "type f32 = typeof(Types.f32)")
    addLine(lines, 0, "type f64 = typeof(Types.f64)")
    addLine(lines, 0, ("type NetRoot = typeof(Types.%s)"):format(isServer and "NetServer" or "NetClient"))
    addLine(lines, 0, "type NetStats = typeof(Types.NetStats)")
    addLine(lines, 0, "type Connection = typeof(Types.Connection)")
    for structIndex = 1, #schema.structs do
        local structName = schema.structs[structIndex].name
        addLine(lines, 0, ("type %s = typeof(Types.%s)"):format(structName, structName))
    end
    for messageIndex = 1, #messages do
        local messageInfo = messages[messageIndex]
        local message = messageInfo.message
        local apiTypeName = isServer and messageServerApiTypeName(messageInfo.apiBase) or messageClientApiTypeName(messageInfo.apiBase)
        local callbackTypeName = isServer and messageServerCallbackTypeName(messageInfo.apiBase, message.category)
            or messageClientCallbackTypeName(messageInfo.apiBase, message.category)
        addLine(lines, 0, ("type %s = typeof(Types.%s)"):format(apiTypeName, apiTypeName))
        addLine(lines, 0, ("type %s = typeof(Types.%s)"):format(callbackTypeName, callbackTypeName))
    end
    addLine(lines, 0, "")

    emitCommonRuntimePreamble(lines, schema, isServer)

    addLine(lines, 0, "local ERR_BOUNDS = \"E_BOUNDS\"")
    addLine(lines, 0, "local ERR_SCHEMA = \"E_SCHEMA\"")
    addLine(lines, 0, "local ERR_TAG = \"E_TAG\"")
    addLine(lines, 0, "local ERR_TYPE = \"E_TYPE\"")
    addLine(lines, 0, "local ERR_PASS = \"E_PASS\"")
    addLine(lines, 0, "local SEGMENT_MARKER_ID = 0")
    addLine(lines, 0, "")

    addLine(lines, 0, "local function VarUIntSize(value)")
    addLine(lines, 1, "if value < 128 then return 1 end")
    addLine(lines, 1, "if value < 16384 then return 2 end")
    addLine(lines, 1, "if value < 2097152 then return 3 end")
    addLine(lines, 1, "if value < 268435456 then return 4 end")
    addLine(lines, 1, "return 5")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "local function WriteVarUInt(payload, offset, value)")
    addLine(lines, 1, "if value < 128 then")
    addLine(lines, 2, "writeu8(payload, offset, value)")
    addLine(lines, 2, "return offset + 1")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if value < 16384 then")
    addLine(lines, 2, "writeu8(payload, offset, bor(band(value, 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 1, band(rshift(value, 7), 127))")
    addLine(lines, 2, "return offset + 2")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if value < 2097152 then")
    addLine(lines, 2, "writeu8(payload, offset, bor(band(value, 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 1, bor(band(rshift(value, 7), 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 2, band(rshift(value, 14), 127))")
    addLine(lines, 2, "return offset + 3")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if value < 268435456 then")
    addLine(lines, 2, "writeu8(payload, offset, bor(band(value, 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 1, bor(band(rshift(value, 7), 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 2, bor(band(rshift(value, 14), 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 3, band(rshift(value, 21), 127))")
    addLine(lines, 2, "return offset + 4")
    addLine(lines, 1, "end")
    addLine(lines, 1, "writeu8(payload, offset, bor(band(value, 127), 128))")
    addLine(lines, 1, "writeu8(payload, offset + 1, bor(band(rshift(value, 7), 127), 128))")
    addLine(lines, 1, "writeu8(payload, offset + 2, bor(band(rshift(value, 14), 127), 128))")
    addLine(lines, 1, "writeu8(payload, offset + 3, bor(band(rshift(value, 21), 127), 128))")
    addLine(lines, 1, "writeu8(payload, offset + 4, band(rshift(value, 28), 15))")
    addLine(lines, 1, "return offset + 5")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "local function ReadVarUInt(payload, payloadLength, offset)")
    addLine(lines, 1, "local next1 = offset + 1")
    addLine(lines, 1, "if next1 > payloadLength then error(ERR_BOUNDS) end")
    addLine(lines, 1, "local b1 = readu8(payload, offset)")
    addLine(lines, 1, "if b1 < 128 then return b1, next1 end")
    addLine(lines, 1, "local next2 = next1 + 1")
    addLine(lines, 1, "if next2 > payloadLength then error(ERR_BOUNDS) end")
    addLine(lines, 1, "local b2 = readu8(payload, next1)")
    addLine(lines, 1, "local value = band(b1, 127) + lshift(band(b2, 127), 7)")
    addLine(lines, 1, "if b2 < 128 then return value, next2 end")
    addLine(lines, 1, "local next3 = next2 + 1")
    addLine(lines, 1, "if next3 > payloadLength then error(ERR_BOUNDS) end")
    addLine(lines, 1, "local b3 = readu8(payload, next2)")
    addLine(lines, 1, "value += lshift(band(b3, 127), 14)")
    addLine(lines, 1, "if b3 < 128 then return value, next3 end")
    addLine(lines, 1, "local next4 = next3 + 1")
    addLine(lines, 1, "if next4 > payloadLength then error(ERR_BOUNDS) end")
    addLine(lines, 1, "local b4 = readu8(payload, next3)")
    addLine(lines, 1, "value += lshift(band(b4, 127), 21)")
    addLine(lines, 1, "if b4 < 128 then return value, next4 end")
    addLine(lines, 1, "local next5 = next4 + 1")
    addLine(lines, 1, "if next5 > payloadLength then error(ERR_BOUNDS) end")
    addLine(lines, 1, "local b5 = readu8(payload, next4)")
    addLine(lines, 1, "if b5 >= 16 then error(ERR_SCHEMA) end")
    addLine(lines, 1, "value += lshift(b5, 28)")
    addLine(lines, 1, "return value, next5")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")

    addLine(lines, 0, "local function CreateConnection(disconnectFn: () -> ()): Connection")
    addLine(lines, 1, "local active = true")
    addLine(lines, 1, "local connection = {} :: any")
    addLine(lines, 1, "connection.Connected = true")
    addLine(lines, 1, "function connection:Disconnect()")
    addLine(lines, 2, "if not active then")
    addLine(lines, 3, "return")
    addLine(lines, 2, "end")
    addLine(lines, 2, "active = false")
    addLine(lines, 2, "connection.Connected = false")
    addLine(lines, 2, "disconnectFn()")
    addLine(lines, 1, "end")
    addLine(lines, 1, "return connection :: Connection")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")

    local maxReliableId = 0
    local maxUnreliableId = 0
    local maxFunctionId = 0
    for index = 1, #messages do
        local info = messages[index]
        local category = info.message.category
        if category == "reliable" then
            if info.message.id > maxReliableId then
                maxReliableId = info.message.id
            end
        elseif category == "unreliable" then
            if info.message.id > maxUnreliableId then
                maxUnreliableId = info.message.id
            end
        elseif category == "function" then
            if info.message.id > maxFunctionId then
                maxFunctionId = info.message.id
            end
        end
    end

    local reliableMessageIdWidth = getMessageIdWidthInfo(maxReliableId)
    local unreliableMessageIdWidth = getMessageIdWidthInfo(maxUnreliableId)
    local functionMessageIdWidth = getMessageIdWidthInfo(maxFunctionId)

    addLine(lines, 0, ("local MAX_RELIABLE_ID = %d"):format(maxReliableId))
    addLine(lines, 0, ("local MAX_UNRELIABLE_ID = %d"):format(maxUnreliableId))
    addLine(lines, 0, ("local MAX_FUNCTION_ID = %d"):format(maxFunctionId))
    addLine(lines, 0, "local RELIABLE_DISPATCH = table.create(MAX_RELIABLE_ID)")
    addLine(lines, 0, "local UNRELIABLE_DISPATCH = table.create(MAX_UNRELIABLE_ID)")
    addLine(lines, 0, "local RELIABLE_SKIP = table.create(MAX_RELIABLE_ID)")
    addLine(lines, 0, "local UNRELIABLE_SKIP = table.create(MAX_UNRELIABLE_ID)")
    addLine(lines, 0, "local FUNCTION_DISPATCH = table.create(MAX_FUNCTION_ID)")
    addLine(lines, 0, "")

    emitQueue(
        lines,
        "Reliable",
        "Reliable",
        isServer and "FireAllClients" or "FireServer",
        schema.maxPassArgs.reliable,
        reliableMessageIdWidth,
        validateLevel
    )
    emitQueue(
        lines,
        "Unreliable",
        "Unreliable",
        isServer and "FireAllClients" or "FireServer",
        schema.maxPassArgs.unreliable,
        unreliableMessageIdWidth,
        validateLevel
    )

    for index = 1, #messages do
        local info = messages[index]
        local symbol = info.symbol
        local message = info.message
        local messageIdWidth: WidthInfo
        if message.category == "reliable" then
            messageIdWidth = reliableMessageIdWidth
        elseif message.category == "unreliable" then
            messageIdWidth = unreliableMessageIdWidth
        else
            messageIdWidth = functionMessageIdWidth
        end
        local requestNeedsPassValidation = validateLevel ~= "Off" and #info.passthroughParams > 0
        local returnNeedsPassValidation = validateLevel ~= "Off" and #info.passthroughReturns > 0
        local includeRequestEncode = message.category == "function" or canSendEvent(message.from, isServer)
        local includeRequestDecode = message.category == "function" or canReceiveEvent(message.from, isServer)
        local messageIdConst = "MESSAGE_ID_" .. symbol
        local encodeRequestName = "Encode_" .. symbol
        local decodeRequestName = "Decode_" .. symbol
        local requestPassValidator = "ValidatePass_" .. symbol
        local handlerName = "Handler_" .. symbol
        local handlerTokenName = "HandlerToken_" .. symbol
        local responsePassValidator = "ValidateReturnPass_" .. symbol
        local encodeResponseName = "EncodeReturn_" .. symbol
        local decodeResponseName = "DecodeReturn_" .. symbol
        local apiTypeName = isServer and messageServerApiTypeName(info.apiBase) or messageClientApiTypeName(info.apiBase)
        local callbackTypeName = isServer and messageServerCallbackTypeName(info.apiBase, message.category)
            or messageClientCallbackTypeName(info.apiBase, message.category)
        local requestDecodePlans = buildDecodedParamPlans(info.serializedParams, schema.structByName, decodeStructMode)
        local requestDecodedVars = collectDecodedLeafNames(requestDecodePlans)

        addLine(lines, 0, ("local %s: %s = {} :: %s"):format(symbol, apiTypeName, apiTypeName))
        addLine(lines, 0, ("local %s = %d"):format(messageIdConst, message.id))
        addLine(lines, 0, "")

        if requestNeedsPassValidation then
            emitPassthroughValidator(lines, requestPassValidator, info.passthroughParams, validateLevel)
        end
        emitCodecFunctions(
            lines,
            encodeRequestName,
            decodeRequestName,
            messageIdConst,
            messageIdWidth,
            info.serializedParams,
            info.fullName,
            validateLevel,
            schema.structByName,
            includeRequestEncode,
            includeRequestDecode,
            decodeStructMode
        )

        if message.category == "function" then
            if returnNeedsPassValidation then
                emitPassthroughValidator(lines, responsePassValidator, info.passthroughReturns, validateLevel)
            end
            emitCodecFunctions(
                lines,
                encodeResponseName,
                decodeResponseName,
                messageIdConst,
                messageIdWidth,
                info.serializedReturns,
                info.fullName .. " return",
                validateLevel,
                schema.structByName,
                true,
                true,
                "Table"
            )
        end

        local handlerReturnParams: { Ast.Param } = {}
        if message.category == "function" then
            handlerReturnParams = message.returns or {}
        end
        local handlerParams = expandDecodeParams(message.params, schema.structByName, decodeStructMode)
        local handlerType = callbackTypeExpr(handlerParams, isServer, handlerReturnParams)
        addLine(lines, 0, ("local %s: (%s)? = nil"):format(handlerName, handlerType))
        addLine(lines, 0, ("local %s = 0"):format(handlerTokenName))
        addLine(lines, 0, "")

        if message.category == "reliable" or message.category == "unreliable" then
            local methodName = isServer and "FireAll" or "Fire"
            local allParamSignature = typedParamList(message.params)
            local serializedNames = paramNames(info.serializedParams)
            local passthroughNames = paramNames(info.passthroughParams)
            local queueUpper = message.category == "unreliable" and "UNRELIABLE" or "RELIABLE"
            local remoteVarName = message.category == "unreliable" and "Unreliable" or "Reliable"
            local categoryMaxPass = schema.maxPassArgs[message.category]
            local eventCallbackType = callbackTypeName
            local usesCanonicalLayout = paramsHaveVariableLength(info.serializedParams, schema.structByName)
            local canonicalFixedSize = usesCanonicalLayout and fixedBytesForCanonicalParams(info.serializedParams, schema.structByName) or 0
            local canUseFlatSize = (not usesCanonicalLayout) and canEmitFlatTopLevelSize(info.serializedParams, schema.structByName)
            local canEmitFire = includeRequestEncode
            local canEmitOn = includeRequestDecode
            local skipName = "Skip_" .. symbol
            local eventCall = message.call or "ManySync"
            local eventIsSingle = eventCall == "SingleSync" or eventCall == "SingleAsync"
            local eventIsMany = eventCall == "ManySync" or eventCall == "ManyAsync"
            local eventIsAsync = eventCall == "SingleAsync" or eventCall == "ManyAsync"
            local eventIsPolling = eventCall == "Polling"
            local handlerListName = "Handlers_" .. symbol
            local handlerTokenListName = "HandlerTokens_" .. symbol
            local handlerSlotByTokenName = "HandlerSlotByToken_" .. symbol
            local handlerCountName = "HandlerCount_" .. symbol
            local handlerNextTokenName = "HandlerNextToken_" .. symbol

            local callbackArgs: { string } = {}
            if isServer then
                callbackArgs[#callbackArgs + 1] = "player"
            end
            local serializedIndex = 0
            local passthroughIndex = 0
            for paramIndex = 1, #message.params do
                local param = message.params[paramIndex]
                if param.type.kind == "passthrough" then
                    passthroughIndex += 1
                    callbackArgs[#callbackArgs + 1] = ("pass%d"):format(passthroughIndex)
                else
                    serializedIndex += 1
                    local leafNames = requestDecodePlans[serializedIndex].leafNames
                    for leafIndex = 1, #leafNames do
                        callbackArgs[#callbackArgs + 1] = leafNames[leafIndex]
                    end
                end
            end
            local callbackArgList = join(callbackArgs)

            local pollingHeadName = "PollHead_" .. symbol
            local pollingTailName = "PollTail_" .. symbol
            local pollingArgNames: { string } = {}
            if canEmitOn and eventIsPolling then
                addLine(lines, 0, ("local %s = 1"):format(pollingHeadName))
                addLine(lines, 0, ("local %s = 0"):format(pollingTailName))
                for argIndex = 1, #callbackArgs do
                    local pollArgName = ("PollArg_%d_%s"):format(argIndex, symbol)
                    pollingArgNames[#pollingArgNames + 1] = pollArgName
                    addLine(lines, 0, ("local %s = table.create(DEFAULT_BATCH_CAPACITY)"):format(pollArgName))
                end
                addLine(lines, 0, "")
            end

            if canEmitOn and eventIsMany then
                addLine(lines, 0, ("local %s = table.create(DEFAULT_BATCH_CAPACITY)"):format(handlerListName))
                addLine(lines, 0, ("local %s = table.create(DEFAULT_BATCH_CAPACITY)"):format(handlerTokenListName))
                addLine(lines, 0, ("local %s = {}"):format(handlerSlotByTokenName))
                addLine(lines, 0, ("local %s = 0"):format(handlerCountName))
                addLine(lines, 0, ("local %s = 0"):format(handlerNextTokenName))
                addLine(lines, 0, "")
            end

            if canEmitFire then
                emitSkipFunction(lines, skipName, info.serializedParams, info.fullName, validateLevel, schema.structByName)
                local skipDispatchVar = message.category == "unreliable" and "UNRELIABLE_SKIP" or "RELIABLE_SKIP"
                addLine(lines, 0, ("%s[%d] = %s"):format(skipDispatchVar, message.id, skipName))
                addLine(lines, 0, "")
            end

            if canEmitFire then
                addLine(lines, 0, ("function %s.%s(%s): boolean"):format(symbol, methodName, allParamSignature))
                if requestNeedsPassValidation then
                    addLine(
                        lines,
                        1,
                        ("if not %s(%d%s%s) then"):format(
                            requestPassValidator,
                            #info.passthroughParams,
                            #passthroughNames > 0 and ", " or "",
                            join(passthroughNames)
                        )
                    )
                    emitError(lines, 2, validateLevel, info.fullName .. " passthrough arguments are invalid", "ERR_PASS")
                    addLine(lines, 1, "end")
                end
                local fireSizeState: EmitState = { tempIndex = 0 }
                local fireStringLenHints: { [string]: string } = {}
                if usesCanonicalLayout then
                    addLine(lines, 1, "local __nr_prefixSize = 0")
                    addLine(lines, 1, "local __nr_varSize = 0")
                    for serializedIndex = 1, #info.serializedParams do
                        local serializedParam = info.serializedParams[serializedIndex]
                        emitCanonicalSizeForType(
                            lines,
                            fireSizeState,
                            serializedParam.type,
                            serializedNames[serializedIndex],
                            info.fullName .. "." .. serializedParam.name,
                            "__nr_prefixSize",
                            "__nr_varSize",
                            1,
                            validateLevel,
                            schema.structByName,
                            fireStringLenHints
                        )
                    end
                    if canonicalFixedSize == 0 then
                        addLine(lines, 1, ("local __nr_totalSize = %d + __nr_prefixSize + __nr_varSize"):format(messageIdWidth.bytes))
                    else
                        addLine(
                            lines,
                            1,
                            ("local __nr_totalSize = %d + __nr_prefixSize + %d + __nr_varSize"):format(
                                messageIdWidth.bytes,
                                canonicalFixedSize
                            )
                        )
                    end
                elseif canUseFlatSize then
                    emitFlatTopLevelSize(
                        lines,
                        fireSizeState,
                        info.serializedParams,
                        serializedNames,
                        info.fullName,
                        "__nr_totalSize",
                        messageIdWidth.bytes,
                        validateLevel,
                        fireStringLenHints,
                        schema.structByName
                    )
                else
                    addLine(lines, 1, ("local __nr_totalSize = %d"):format(messageIdWidth.bytes))
                    for serializedIndex = 1, #info.serializedParams do
                        local serializedParam = info.serializedParams[serializedIndex]
                        emitSizeForType(
                            lines,
                            fireSizeState,
                            serializedParam.type,
                            serializedNames[serializedIndex],
                            info.fullName .. "." .. serializedParam.name,
                            "__nr_totalSize",
                            1,
                            validateLevel,
                            schema.structByName,
                            fireStringLenHints
                        )
                    end
                end

                addLine(lines, 1, ("local __nr_base = %s_CURSOR"):format(queueUpper))
                addLine(lines, 1, "local __nr_required = __nr_base + __nr_totalSize")
                addLine(lines, 1, ("if __nr_required > %s_ARENA_CAPACITY then"):format(queueUpper))
                addLine(lines, 2, ("local nextCapacity = %s_ARENA_CAPACITY"):format(queueUpper))
                addLine(lines, 2, "while nextCapacity < __nr_required do")
                addLine(lines, 3, "nextCapacity *= 2")
                addLine(lines, 2, "end")
                addLine(lines, 2, "local nextArena = create(nextCapacity)")
                addLine(lines, 2, ("if %s_CURSOR > 0 then"):format(queueUpper))
                addLine(lines, 3, ("copy(nextArena, 0, %s_ARENA, 0, %s_CURSOR)"):format(queueUpper, queueUpper))
                addLine(lines, 2, "end")
                addLine(lines, 2, ("%s_ARENA = nextArena"):format(queueUpper))
                addLine(lines, 2, ("%s_ARENA_CAPACITY = nextCapacity"):format(queueUpper))
                addLine(lines, 1, "end")

                addLine(lines, 1, ("%s_CURSOR = __nr_required"):format(queueUpper))
                addLine(lines, 1, ("local __nr_payload = %s_ARENA"):format(queueUpper))
                addLine(lines, 1, ("%s(__nr_payload, __nr_base, %s)"):format(messageIdWidth.writer, messageIdConst))
                local fireWriteState: EmitState = { tempIndex = fireSizeState.tempIndex }
                if usesCanonicalLayout then
                    addLine(lines, 1, ("local __nr_prefix = __nr_base + %d"):format(messageIdWidth.bytes))
                    addLine(lines, 1, "local __nr_fixed = __nr_prefix + __nr_prefixSize")
                    if canonicalFixedSize == 0 then
                        addLine(lines, 1, "local __nr_var = __nr_fixed")
                    else
                        addLine(lines, 1, ("local __nr_var = __nr_fixed + %d"):format(canonicalFixedSize))
                    end
                    for serializedIndex = 1, #info.serializedParams do
                        local serializedParam = info.serializedParams[serializedIndex]
                        emitWriteCanonicalForType(
                            lines,
                            fireWriteState,
                            serializedParam.type,
                            serializedNames[serializedIndex],
                            "__nr_payload",
                            "__nr_prefix",
                            "__nr_fixed",
                            "__nr_var",
                            1,
                            schema.structByName,
                            fireStringLenHints
                        )
                    end
                else
                    addLine(lines, 1, ("local __nr_p = __nr_base + %d"):format(messageIdWidth.bytes))
                    emitWriteParamsWithFixedBlocks(
                        lines,
                        fireWriteState,
                        info.serializedParams,
                        serializedNames,
                        "__nr_payload",
                        "__nr_p",
                        1,
                        schema.structByName,
                        fireStringLenHints
                    )
                end
                addLine(lines, 1, ("%s_QUEUE_SIZE += 1"):format(queueUpper))
                if categoryMaxPass > 0 then
                    addLine(lines, 1, ("local __nr_slot = %s_QUEUE_SIZE"):format(queueUpper))
                    addLine(lines, 1, ("%s_QUEUE_PASS_COUNT[__nr_slot] = %d"):format(queueUpper, #info.passthroughParams))
                    for passIndex = 1, categoryMaxPass do
                        local passValueExpr = passIndex <= #passthroughNames and passthroughNames[passIndex] or "nil"
                        addLine(lines, 1, ("%s_QUEUE_PASS_%d[__nr_slot] = %s"):format(queueUpper, passIndex, passValueExpr))
                    end
                end
                addLine(lines, 1, "return true")
                addLine(lines, 0, "end")
                addLine(lines, 0, "")
            end

            if canEmitFire and isServer then
                local fireSignatureParts: { string } = { "player: Player" }
                local fireListSignatureParts: { string } = { "players: { Player }" }
                local fireExceptSignatureParts: { string } = { "excludedPlayer: Player" }
                for paramIndex = 1, #message.params do
                    local param = message.params[paramIndex]
                    local typedParam = ("%s: %s"):format(param.name, toLuauType(param.type))
                    fireSignatureParts[#fireSignatureParts + 1] = typedParam
                    fireListSignatureParts[#fireListSignatureParts + 1] = typedParam
                    fireExceptSignatureParts[#fireExceptSignatureParts + 1] = typedParam
                end

                addLine(lines, 0, ("function %s.Fire(%s): boolean"):format(symbol, join(fireSignatureParts)))
                addLine(lines, 1, "if typeof(player) ~= \"Instance\" or not player:IsA(\"Player\") then")
                emitError(lines, 2, validateLevel, info.fullName .. " Fire requires Player", "ERR_TYPE")
                addLine(lines, 1, "end")
                if requestNeedsPassValidation then
                    addLine(
                        lines,
                        1,
                        ("if not %s(%d%s%s) then"):format(
                            requestPassValidator,
                            #info.passthroughParams,
                            #passthroughNames > 0 and ", " or "",
                            join(passthroughNames)
                        )
                    )
                    emitError(lines, 2, validateLevel, info.fullName .. " passthrough arguments are invalid", "ERR_PASS")
                    addLine(lines, 1, "end")
                end
                addLine(lines, 1, ("local __nr_payload = %s(%s)"):format(encodeRequestName, join(serializedNames)))
                if categoryMaxPass > 0 then
                    addLine(lines, 1, ("local __nr_passCountList = table.create(1, %d)"):format(#info.passthroughParams))
                    local firePassArgs: { string } = { "player", "__nr_payload", "__nr_passCountList" }
                    for passIndex = 1, categoryMaxPass do
                        local passListName = ("__nr_passList_%d"):format(passIndex)
                        local passValueExpr = passIndex <= #passthroughNames and passthroughNames[passIndex] or "nil"
                        addLine(lines, 1, ("local %s = table.create(1)"):format(passListName))
                        addLine(lines, 1, ("%s[1] = %s"):format(passListName, passValueExpr))
                        firePassArgs[#firePassArgs + 1] = passListName
                    end
                    addLine(lines, 1, ("%s:FireClient(%s)"):format(remoteVarName, join(firePassArgs)))
                else
                    addLine(lines, 1, ("%s:FireClient(player, __nr_payload)"):format(remoteVarName))
                end
                addLine(lines, 1, "return true")
                addLine(lines, 0, "end")
                addLine(lines, 0, "")

                addLine(lines, 0, ("function %s.FireList(%s): boolean"):format(symbol, join(fireListSignatureParts)))
                addLine(lines, 1, "if type(players) ~= \"table\" then")
                emitError(lines, 2, validateLevel, info.fullName .. " FireList requires {Player}", "ERR_TYPE")
                addLine(lines, 1, "end")
                if requestNeedsPassValidation then
                    addLine(
                        lines,
                        1,
                        ("if not %s(%d%s%s) then"):format(
                            requestPassValidator,
                            #info.passthroughParams,
                            #passthroughNames > 0 and ", " or "",
                            join(passthroughNames)
                        )
                    )
                    emitError(lines, 2, validateLevel, info.fullName .. " passthrough arguments are invalid", "ERR_PASS")
                    addLine(lines, 1, "end")
                end
                addLine(lines, 1, ("local __nr_payload = %s(%s)"):format(encodeRequestName, join(serializedNames)))
                if categoryMaxPass > 0 then
                    addLine(lines, 1, ("local __nr_passCountList = table.create(1, %d)"):format(#info.passthroughParams))
                    local fireListPassArgs: { string } = { "__nr_target", "__nr_payload", "__nr_passCountList" }
                    for passIndex = 1, categoryMaxPass do
                        local passListName = ("__nr_passList_%d"):format(passIndex)
                        local passValueExpr = passIndex <= #passthroughNames and passthroughNames[passIndex] or "nil"
                        addLine(lines, 1, ("local %s = table.create(1)"):format(passListName))
                        addLine(lines, 1, ("%s[1] = %s"):format(passListName, passValueExpr))
                        fireListPassArgs[#fireListPassArgs + 1] = passListName
                    end
                    addLine(lines, 1, "for __nr_index = 1, #players do")
                    addLine(lines, 2, "local __nr_target = players[__nr_index]")
                    addLine(lines, 2, "if typeof(__nr_target) ~= \"Instance\" or not __nr_target:IsA(\"Player\") then")
                    emitError(lines, 3, validateLevel, info.fullName .. " FireList requires Player values", "ERR_TYPE")
                    addLine(lines, 2, "end")
                    addLine(lines, 2, ("%s:FireClient(%s)"):format(remoteVarName, join(fireListPassArgs)))
                    addLine(lines, 1, "end")
                else
                    addLine(lines, 1, "for __nr_index = 1, #players do")
                    addLine(lines, 2, "local __nr_target = players[__nr_index]")
                    addLine(lines, 2, "if typeof(__nr_target) ~= \"Instance\" or not __nr_target:IsA(\"Player\") then")
                    emitError(lines, 3, validateLevel, info.fullName .. " FireList requires Player values", "ERR_TYPE")
                    addLine(lines, 2, "end")
                    addLine(lines, 2, ("%s:FireClient(__nr_target, __nr_payload)"):format(remoteVarName))
                    addLine(lines, 1, "end")
                end
                addLine(lines, 1, "return true")
                addLine(lines, 0, "end")
                addLine(lines, 0, "")

                addLine(lines, 0, ("function %s.FireExcept(%s): boolean"):format(symbol, join(fireExceptSignatureParts)))
                addLine(lines, 1, "if typeof(excludedPlayer) ~= \"Instance\" or not excludedPlayer:IsA(\"Player\") then")
                emitError(lines, 2, validateLevel, info.fullName .. " FireExcept requires Player", "ERR_TYPE")
                addLine(lines, 1, "end")
                if requestNeedsPassValidation then
                    addLine(
                        lines,
                        1,
                        ("if not %s(%d%s%s) then"):format(
                            requestPassValidator,
                            #info.passthroughParams,
                            #passthroughNames > 0 and ", " or "",
                            join(passthroughNames)
                        )
                    )
                    emitError(lines, 2, validateLevel, info.fullName .. " passthrough arguments are invalid", "ERR_PASS")
                    addLine(lines, 1, "end")
                end
                addLine(lines, 1, ("local __nr_payload = %s(%s)"):format(encodeRequestName, join(serializedNames)))
                addLine(lines, 1, "local __nr_players = Players:GetPlayers()")
                if categoryMaxPass > 0 then
                    addLine(lines, 1, ("local __nr_passCountList = table.create(1, %d)"):format(#info.passthroughParams))
                    local fireExceptPassArgs: { string } = { "__nr_target", "__nr_payload", "__nr_passCountList" }
                    for passIndex = 1, categoryMaxPass do
                        local passListName = ("__nr_passList_%d"):format(passIndex)
                        local passValueExpr = passIndex <= #passthroughNames and passthroughNames[passIndex] or "nil"
                        addLine(lines, 1, ("local %s = table.create(1)"):format(passListName))
                        addLine(lines, 1, ("%s[1] = %s"):format(passListName, passValueExpr))
                        fireExceptPassArgs[#fireExceptPassArgs + 1] = passListName
                    end
                    addLine(lines, 1, "for __nr_index = 1, #__nr_players do")
                    addLine(lines, 2, "local __nr_target = __nr_players[__nr_index]")
                    addLine(lines, 2, "if __nr_target ~= excludedPlayer then")
                    addLine(lines, 3, ("%s:FireClient(%s)"):format(remoteVarName, join(fireExceptPassArgs)))
                    addLine(lines, 2, "end")
                    addLine(lines, 1, "end")
                else
                    addLine(lines, 1, "for __nr_index = 1, #__nr_players do")
                    addLine(lines, 2, "local __nr_target = __nr_players[__nr_index]")
                    addLine(lines, 2, "if __nr_target ~= excludedPlayer then")
                    addLine(lines, 3, ("%s:FireClient(__nr_target, __nr_payload)"):format(remoteVarName))
                    addLine(lines, 2, "end")
                    addLine(lines, 1, "end")
                end
                addLine(lines, 1, "return true")
                addLine(lines, 0, "end")
                addLine(lines, 0, "")
            end

            if canEmitOn then
                if eventIsPolling then
                    addLine(lines, 0, ("function %s.Iter()"):format(symbol))
                    addLine(lines, 1, "return function()")
                    addLine(lines, 2, ("local __nr_head = %s"):format(pollingHeadName))
                    addLine(lines, 2, ("if __nr_head > %s then"):format(pollingTailName))
                    addLine(lines, 3, "return nil")
                    addLine(lines, 2, "end")
                    local pollReturnVars: { string } = {}
                    for argIndex = 1, #pollingArgNames do
                        local pollVarName = ("__nr_arg%d"):format(argIndex)
                        pollReturnVars[#pollReturnVars + 1] = pollVarName
                        addLine(lines, 2, ("local %s = %s[__nr_head]"):format(pollVarName, pollingArgNames[argIndex]))
                        addLine(lines, 2, ("%s[__nr_head] = nil"):format(pollingArgNames[argIndex]))
                    end
                    addLine(lines, 2, ("%s = __nr_head + 1"):format(pollingHeadName))
                    addLine(lines, 2, ("if %s > %s then"):format(pollingHeadName, pollingTailName))
                    addLine(lines, 3, ("%s = 1"):format(pollingHeadName))
                    addLine(lines, 3, ("%s = 0"):format(pollingTailName))
                    addLine(lines, 2, "end")
                    if #pollReturnVars > 0 then
                        addLine(lines, 2, ("return %s"):format(join(pollReturnVars)))
                    else
                        addLine(lines, 2, "return true")
                    end
                    addLine(lines, 1, "end")
                    addLine(lines, 0, "end")
                    addLine(lines, 0, "")
                elseif eventIsSingle then
                    addLine(lines, 0, ("function %s.On(callback: %s): Connection"):format(symbol, eventCallbackType))
                    addLine(lines, 1, "if type(callback) ~= \"function\" then error(ERR_TYPE) end")
                    addLine(lines, 1, ("%s += 1"):format(handlerTokenName))
                    addLine(lines, 1, ("local token = %s"):format(handlerTokenName))
                    addLine(lines, 1, ("%s = callback"):format(handlerName))
                    addLine(lines, 1, "return CreateConnection(function()")
                    addLine(lines, 2, ("if %s == token then"):format(handlerTokenName))
                    addLine(lines, 3, ("%s += 1"):format(handlerTokenName))
                    addLine(lines, 3, ("%s = nil"):format(handlerName))
                    addLine(lines, 2, "end")
                    addLine(lines, 1, "end)")
                    addLine(lines, 0, "end")
                    addLine(lines, 0, "")
                elseif eventIsMany then
                    addLine(lines, 0, ("function %s.On(callback: %s): Connection"):format(symbol, eventCallbackType))
                    addLine(lines, 1, "if type(callback) ~= \"function\" then error(ERR_TYPE) end")
                    addLine(lines, 1, ("%s += 1"):format(handlerNextTokenName))
                    addLine(lines, 1, ("local token = %s"):format(handlerNextTokenName))
                    addLine(lines, 1, ("%s += 1"):format(handlerCountName))
                    addLine(lines, 1, ("local slot = %s"):format(handlerCountName))
                    addLine(lines, 1, ("%s[slot] = callback"):format(handlerListName))
                    addLine(lines, 1, ("%s[slot] = token"):format(handlerTokenListName))
                    addLine(lines, 1, ("%s[token] = slot"):format(handlerSlotByTokenName))
                    addLine(lines, 1, "return CreateConnection(function()")
                    addLine(lines, 2, ("local existingSlot = %s[token]"):format(handlerSlotByTokenName))
                    addLine(lines, 2, "if existingSlot == nil then")
                    addLine(lines, 3, "return")
                    addLine(lines, 2, "end")
                    addLine(lines, 2, ("local lastSlot = %s"):format(handlerCountName))
                    addLine(lines, 2, "if existingSlot ~= lastSlot then")
                    addLine(lines, 3, ("local movedCallback = %s[lastSlot]"):format(handlerListName))
                    addLine(lines, 3, ("local movedToken = %s[lastSlot]"):format(handlerTokenListName))
                    addLine(lines, 3, ("%s[existingSlot] = movedCallback"):format(handlerListName))
                    addLine(lines, 3, ("%s[existingSlot] = movedToken"):format(handlerTokenListName))
                    addLine(lines, 3, "if movedToken ~= nil then")
                    addLine(lines, 4, ("%s[movedToken] = existingSlot"):format(handlerSlotByTokenName))
                    addLine(lines, 3, "end")
                    addLine(lines, 2, "end")
                    addLine(lines, 2, ("%s[lastSlot] = nil"):format(handlerListName))
                    addLine(lines, 2, ("%s[lastSlot] = nil"):format(handlerTokenListName))
                    addLine(lines, 2, ("%s[token] = nil"):format(handlerSlotByTokenName))
                    addLine(lines, 2, ("%s -= 1"):format(handlerCountName))
                    addLine(lines, 1, "end)")
                    addLine(lines, 0, "end")
                    addLine(lines, 0, "")
                end
            end

            if canEmitOn then
                local dispatchVar = message.category == "unreliable" and "UNRELIABLE_DISPATCH" or "RELIABLE_DISPATCH"
                local signatureArgs: { string } = {}
                if isServer then
                    signatureArgs[#signatureArgs + 1] = "player"
                end
                signatureArgs[#signatureArgs + 1] = "payload"
                signatureArgs[#signatureArgs + 1] = "payloadLength"
                signatureArgs[#signatureArgs + 1] = "offset"
                if categoryMaxPass > 0 then
                    signatureArgs[#signatureArgs + 1] = "passCount"
                end
                for passIndex = 1, categoryMaxPass do
                    signatureArgs[#signatureArgs + 1] = ("pass%d"):format(passIndex)
                end

                addLine(lines, 0, ("%s[%d] = function(%s)"):format(dispatchVar, message.id, join(signatureArgs)))
                if requestNeedsPassValidation then
                    local passVarsForValidation: { string } = { "passCount" }
                    for passIndex = 1, #info.passthroughParams do
                        passVarsForValidation[#passVarsForValidation + 1] = ("pass%d"):format(passIndex)
                    end
                    addLine(lines, 1, ("if not %s(%s) then"):format(requestPassValidator, join(passVarsForValidation)))
                    addLine(lines, 2, "return payloadLength")
                    addLine(lines, 1, "end")
                end

                local decodeResultVars: { string } = {}
                for idxVar = 1, #requestDecodedVars do
                    decodeResultVars[#decodeResultVars + 1] = requestDecodedVars[idxVar]
                end
                decodeResultVars[#decodeResultVars + 1] = "nextOffset"
                addLine(lines, 1, ("local %s = %s(payload, payloadLength, offset)"):format(join(decodeResultVars), decodeRequestName))

                if eventIsPolling then
                    addLine(lines, 1, ("local __nr_tail = %s + 1"):format(pollingTailName))
                    addLine(lines, 1, ("%s = __nr_tail"):format(pollingTailName))
                    for argIndex = 1, #pollingArgNames do
                        addLine(lines, 1, ("%s[__nr_tail] = %s"):format(pollingArgNames[argIndex], callbackArgs[argIndex]))
                    end
                    addLine(lines, 1, "return nextOffset")
                elseif eventIsSingle then
                    addLine(lines, 1, ("local callback = %s"):format(handlerName))
                    addLine(lines, 1, "if callback == nil then")
                    addLine(lines, 2, "return nextOffset")
                    addLine(lines, 1, "end")
                    if eventIsAsync then
                        if #callbackArgs > 0 then
                            addLine(lines, 1, ("task.spawn(callback, %s)"):format(callbackArgList))
                        else
                            addLine(lines, 1, "task.spawn(callback)")
                        end
                    else
                        if #callbackArgs > 0 then
                            addLine(lines, 1, ("callback(%s)"):format(callbackArgList))
                        else
                            addLine(lines, 1, "callback()")
                        end
                    end
                    addLine(lines, 1, "return nextOffset")
                elseif eventIsMany then
                    addLine(lines, 1, ("if %s == 0 then"):format(handlerCountName))
                    addLine(lines, 2, "return nextOffset")
                    addLine(lines, 1, "end")
                    addLine(lines, 1, ("for __nr_index = 1, %s do"):format(handlerCountName))
                    addLine(lines, 2, ("local callback = %s[__nr_index]"):format(handlerListName))
                    addLine(lines, 2, "if callback ~= nil then")
                    if eventIsAsync then
                        if #callbackArgs > 0 then
                            addLine(lines, 3, ("task.spawn(callback, %s)"):format(callbackArgList))
                        else
                            addLine(lines, 3, "task.spawn(callback)")
                        end
                    else
                        if #callbackArgs > 0 then
                            addLine(lines, 3, ("callback(%s)"):format(callbackArgList))
                        else
                            addLine(lines, 3, "callback()")
                        end
                    end
                    addLine(lines, 2, "end")
                    addLine(lines, 1, "end")
                    addLine(lines, 1, "return nextOffset")
                else
                    addLine(lines, 1, "return nextOffset")
                end
                addLine(lines, 0, "end")
                addLine(lines, 0, "")
            end
        elseif message.category == "function" then
            local serializedNames = paramNames(info.serializedParams)
            local passthroughNames = paramNames(info.passthroughParams)
            local allReturnNames = paramNames(message.returns or {})
            local passthroughReturnNames = paramNames(info.passthroughReturns)
            local functionCallbackType = callbackTypeName
            local functionReturnType = returnTypeExpr(message.returns or {})

            addLine(lines, 0, ("function %s.On(callback: %s): Connection"):format(symbol, functionCallbackType))
            addLine(lines, 1, "if type(callback) ~= \"function\" then error(ERR_TYPE) end")
            addLine(lines, 1, ("%s += 1"):format(handlerTokenName))
            addLine(lines, 1, ("local token = %s"):format(handlerTokenName))
            addLine(lines, 1, ("%s = callback"):format(handlerName))
            addLine(lines, 1, "return CreateConnection(function()")
            addLine(lines, 2, ("if %s == token then"):format(handlerTokenName))
            addLine(lines, 3, ("%s += 1"):format(handlerTokenName))
            addLine(lines, 3, ("%s = nil"):format(handlerName))
            addLine(lines, 2, "end")
            addLine(lines, 1, "end)")
            addLine(lines, 0, "end")
            addLine(lines, 0, "")

            local callSignature: { string } = {}
            if isServer then
                callSignature[#callSignature + 1] = "player: Player"
            end
            for indexParam = 1, #message.params do
                local param = message.params[indexParam]
                callSignature[#callSignature + 1] = ("%s: %s"):format(param.name, toLuauType(param.type))
            end
            addLine(lines, 0, ("function %s.Call(%s): %s"):format(symbol, join(callSignature), functionReturnType))
            if isServer then
                addLine(lines, 1, "if typeof(player) ~= \"Instance\" or not player:IsA(\"Player\") then")
                emitError(lines, 2, validateLevel, info.fullName .. " server call requires Player", "ERR_TYPE")
                addLine(lines, 1, "end")
            end
            if requestNeedsPassValidation then
                addLine(
                    lines,
                    1,
                    ("if not %s(%d%s%s) then"):format(
                        requestPassValidator,
                        #info.passthroughParams,
                        #passthroughNames > 0 and ", " or "",
                        join(passthroughNames)
                    )
                )
                emitError(lines, 2, validateLevel, info.fullName .. " passthrough arguments are invalid", "ERR_PASS")
                addLine(lines, 1, "end")
            end
            addLine(lines, 1, ("local requestPayload = %s(%s)"):format(encodeRequestName, join(serializedNames)))

            local responseCaptureVars: { string } = { "responseCount", "responsePayload" }
            for passIndex = 1, #passthroughReturnNames do
                responseCaptureVars[#responseCaptureVars + 1] = ("responsePass%d"):format(passIndex)
            end

            local invokeArgs: { string } = {}
            if isServer then
                invokeArgs[#invokeArgs + 1] = "player"
            end
            invokeArgs[#invokeArgs + 1] = "requestPayload"
            for passIndex = 1, #passthroughNames do
                invokeArgs[#invokeArgs + 1] = passthroughNames[passIndex]
            end

            if isServer then
                addLine(lines, 1, ("local %s = WithCount(FunctionRemote:InvokeClient(%s))"):format(join(responseCaptureVars), join(invokeArgs)))
            else
                addLine(lines, 1, ("local %s = WithCount(FunctionRemote:InvokeServer(%s))"):format(join(responseCaptureVars), join(invokeArgs)))
            end
            addLine(lines, 1, "if responseCount < 1 then")
            emitError(lines, 2, validateLevel, info.fullName .. " function response missing payload", "ERR_SCHEMA")
            addLine(lines, 1, "end")
            if #passthroughReturnNames > 0 then
                addLine(lines, 1, "local responsePassCount = responseCount - 1")
            end

            if returnNeedsPassValidation then
                local passValidationArgs: { string } = { "responsePassCount" }
                for passIndex = 1, #passthroughReturnNames do
                    passValidationArgs[#passValidationArgs + 1] = ("responsePass%d"):format(passIndex)
                end
                addLine(lines, 1, ("if not %s(%s) then"):format(responsePassValidator, join(passValidationArgs)))
                emitError(lines, 2, validateLevel, info.fullName .. " return passthrough is invalid", "ERR_PASS")
                addLine(lines, 1, "end")
            end
            addLine(lines, 1, "if typeof(responsePayload) ~= \"buffer\" then")
            emitError(lines, 2, validateLevel, info.fullName .. " function response payload must be buffer", "ERR_TYPE")
            addLine(lines, 1, "end")
            addLine(lines, 1, "local responseLength = len(responsePayload)")
            addLine(lines, 1, ("if responseLength < %d then"):format(messageIdWidth.bytes))
            emitError(lines, 2, validateLevel, info.fullName .. " function response payload too short", "ERR_BOUNDS")
            addLine(lines, 1, "end")
            addLine(lines, 1, ("local responseId = %s(responsePayload, 0)"):format(messageIdWidth.reader))
            addLine(lines, 1, ("if responseId ~= %s then"):format(messageIdConst))
            emitError(lines, 2, validateLevel, info.fullName .. " function response message ID mismatch", "ERR_SCHEMA")
            addLine(lines, 1, "end")

            local decodedReturnVars: { string } = {}
            for indexReturn = 1, #info.serializedReturns do
                decodedReturnVars[#decodedReturnVars + 1] = ("decoded_%s"):format(sanitizeIdentifier(info.serializedReturns[indexReturn].name))
            end
            local decodeReturnCapture: { string } = {}
            for indexVar = 1, #decodedReturnVars do
                decodeReturnCapture[#decodeReturnCapture + 1] = decodedReturnVars[indexVar]
            end
            decodeReturnCapture[#decodeReturnCapture + 1] = "responseOffset"
            addLine(
                lines,
                1,
                ("local %s = %s(responsePayload, responseLength, %d)"):format(
                    join(decodeReturnCapture),
                    decodeResponseName,
                    messageIdWidth.bytes
                )
            )
            addLine(lines, 1, "if responseOffset ~= responseLength then")
            emitError(lines, 2, validateLevel, info.fullName .. " function response has trailing bytes", "ERR_SCHEMA")
            addLine(lines, 1, "end")

            if #allReturnNames > 0 then
                local returnArgs: { string } = {}
                local serialIndex = 0
                local passIndex = 0
                local returnParamList = message.returns or {}
                for returnIndex = 1, #returnParamList do
                    local returnParam = returnParamList[returnIndex]
                    if returnParam.type.kind == "passthrough" then
                        passIndex += 1
                        returnArgs[#returnArgs + 1] = ("responsePass%d"):format(passIndex)
                    else
                        serialIndex += 1
                        returnArgs[#returnArgs + 1] = decodedReturnVars[serialIndex]
                    end
                end
                addLine(lines, 1, ("return %s"):format(join(returnArgs)))
            end
            addLine(lines, 0, "end")
            addLine(lines, 0, "")

            local signatureArgs: { string } = {}
            if isServer then
                signatureArgs[#signatureArgs + 1] = "player"
            end
            signatureArgs[#signatureArgs + 1] = "payload"
            signatureArgs[#signatureArgs + 1] = "payloadLength"
            if schema.maxPassArgs.Function > 0 then
                signatureArgs[#signatureArgs + 1] = "passCount"
            end
            for passIndex = 1, schema.maxPassArgs.Function do
                signatureArgs[#signatureArgs + 1] = ("pass%d"):format(passIndex)
            end
            addLine(lines, 0, ("FUNCTION_DISPATCH[%d] = function(%s)"):format(message.id, join(signatureArgs)))
            if requestNeedsPassValidation then
                local inboundPassValidationArgs: { string } = { "passCount" }
                for passIndex = 1, #passthroughNames do
                    inboundPassValidationArgs[#inboundPassValidationArgs + 1] = ("pass%d"):format(passIndex)
                end
                addLine(lines, 1, ("if not %s(%s) then"):format(requestPassValidator, join(inboundPassValidationArgs)))
                emitError(lines, 2, validateLevel, info.fullName .. " inbound passthrough is invalid", "ERR_PASS")
                addLine(lines, 1, "end")
            end

            local inboundDecodeCapture: { string } = {}
            for indexVar = 1, #requestDecodedVars do
                inboundDecodeCapture[#inboundDecodeCapture + 1] = requestDecodedVars[indexVar]
            end
            inboundDecodeCapture[#inboundDecodeCapture + 1] = "offset"
            addLine(
                lines,
                1,
                ("local %s = %s(payload, payloadLength, %d)"):format(join(inboundDecodeCapture), decodeRequestName, messageIdWidth.bytes)
            )
            addLine(lines, 1, "if offset ~= payloadLength then")
            emitError(lines, 2, validateLevel, info.fullName .. " inbound function payload has trailing bytes", "ERR_SCHEMA")
            addLine(lines, 1, "end")
            addLine(lines, 1, ("local callback = %s"):format(handlerName))
            addLine(lines, 1, "if callback == nil then")
            emitError(lines, 2, validateLevel, info.fullName .. " inbound function has no handler", "ERR_SCHEMA")
            addLine(lines, 1, "end")

            local callbackArgs: { string } = {}
            if isServer then
                callbackArgs[#callbackArgs + 1] = "player"
            end
            local callbackSerialIndex = 0
            local callbackPassIndex = 0
            for paramIndex = 1, #message.params do
                local param = message.params[paramIndex]
                if param.type.kind == "passthrough" then
                    callbackPassIndex += 1
                    callbackArgs[#callbackArgs + 1] = ("pass%d"):format(callbackPassIndex)
                else
                    callbackSerialIndex += 1
                    local leafNames = requestDecodePlans[callbackSerialIndex].leafNames
                    for leafIndex = 1, #leafNames do
                        callbackArgs[#callbackArgs + 1] = leafNames[leafIndex]
                    end
                end
            end

            if #allReturnNames > 0 then
                local callbackResultVars: { string } = {}
                for returnIndex = 1, #allReturnNames do
                    callbackResultVars[#callbackResultVars + 1] = ("callbackRet_%d"):format(returnIndex)
                end
                addLine(lines, 1, ("local %s = callback(%s)"):format(join(callbackResultVars), join(callbackArgs)))

                local responseSerializedArgs: { string } = {}
                local responsePassthroughArgs: { string } = {}
                local returnParamList = message.returns or {}
                for returnIndex = 1, #returnParamList do
                    local returnParam = returnParamList[returnIndex]
                    if returnParam.type.kind == "passthrough" then
                        responsePassthroughArgs[#responsePassthroughArgs + 1] = callbackResultVars[returnIndex]
                    else
                        responseSerializedArgs[#responseSerializedArgs + 1] = callbackResultVars[returnIndex]
                    end
                end

                if returnNeedsPassValidation then
                    addLine(
                        lines,
                        1,
                        ("if not %s(%d%s%s) then"):format(
                            responsePassValidator,
                            #responsePassthroughArgs,
                            #responsePassthroughArgs > 0 and ", " or "",
                            join(responsePassthroughArgs)
                        )
                    )
                    emitError(lines, 2, validateLevel, info.fullName .. " handler returned invalid passthrough", "ERR_PASS")
                    addLine(lines, 1, "end")
                end
                addLine(lines, 1, ("local responsePayload = %s(%s)"):format(encodeResponseName, join(responseSerializedArgs)))
                if #responsePassthroughArgs > 0 then
                    local returnPayload: { string } = { "responsePayload" }
                    for passIndex = 1, #responsePassthroughArgs do
                        returnPayload[#returnPayload + 1] = responsePassthroughArgs[passIndex]
                    end
                    addLine(lines, 1, ("return %s"):format(join(returnPayload)))
                else
                    addLine(lines, 1, "return responsePayload")
                end
            else
                addLine(lines, 1, ("callback(%s)"):format(join(callbackArgs)))
                addLine(lines, 1, ("local responsePayload = %s()"):format(encodeResponseName))
                addLine(lines, 1, "return responsePayload")
            end
            addLine(lines, 0, "end")
            addLine(lines, 0, "")
        else
            error(("Unsupported message category '%s' for message '%s'"):format(message.category, info.fullName))
        end
    end

    addLine(lines, 0, "local function StepReplication()")
    addLine(lines, 1, "FlushReliable()")
    addLine(lines, 1, "FlushUnreliable()")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "RunService.Heartbeat:Connect(StepReplication)")
    addLine(lines, 0, "")

    emitEventListener(
        lines,
        isServer,
        "Reliable",
        "Reliable",
        schema.maxPassArgs.reliable,
        reliableMessageIdWidth,
        validateLevel
    )
    emitEventListener(
        lines,
        isServer,
        "Unreliable",
        "Unreliable",
        schema.maxPassArgs.unreliable,
        unreliableMessageIdWidth,
        validateLevel
    )
    emitFunctionInvoke(lines, isServer, schema.maxPassArgs.Function, functionMessageIdWidth, validateLevel)

    addLine(lines, 0, "local Stats: NetStats = {")
    addLine(lines, 1, "GetReliableDropped = function() return RELIABLE_DROPPED end,")
    addLine(lines, 1, "GetUnreliableDropped = function() return UNRELIABLE_DROPPED end,")
    addLine(lines, 1, "GetReliableQueueSize = function() return RELIABLE_QUEUE_SIZE end,")
    addLine(lines, 1, "GetUnreliableQueueSize = function() return UNRELIABLE_QUEUE_SIZE end,")
    addLine(lines, 0, "}")
    addLine(lines, 0, "")

    local scopeLines = buildScopeTables(schema.root, 0, true, symbolByMessage)
    appendLines(lines, scopeLines)
    addLine(lines, 0, "")
    addLine(lines, 0, "Net.StepReplication = StepReplication")
    addLine(lines, 0, "Net.Stats = Stats")
    addLine(lines, 0, "local NetTyped: NetRoot = Net")
    addLine(lines, 0, "")
    addLine(lines, 0, "return table.freeze(NetTyped)")

    pruneUnusedRuntimeSymbols(lines)

    return concat(lines)
end

local function generateServer(schema: Analyzer.AnalyzedSchema): string
    return generateRuntime(schema, true)
end

local function generateClient(schema: Analyzer.AnalyzedSchema): string
    return generateRuntime(schema, false)
end
return {
    emitQueue = emitQueue,
    emitEventListener = emitEventListener,
    emitFunctionInvoke = emitFunctionInvoke,
    emitCommonRuntimePreamble = emitCommonRuntimePreamble,
    generateRuntime = generateRuntime,
    generateServer = generateServer,
    generateClient = generateClient,
}
