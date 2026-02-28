--!strict
-- Name: EmitTypes
-- Purpose: Generate Luau type definitions for schema types

local Ast = require("../idl/Ast")
local Analyzer = require("../idl/Analyzer")
local Types = require("./Types")
local Utilities = require("./Utilities")

type MessageInfo = Types.MessageInfo

local EMPTY_PARAMS: { Ast.Param } = {}

local addLine = Utilities.addLine
local appendLines = Utilities.appendLines
local concat = Utilities.concat
local join = Utilities.join
local sanitizeIdentifier = Utilities.sanitizeIdentifier
local luauTypeFieldKey = Utilities.luauTypeFieldKey
local toLuauType = Utilities.toLuauType
local typedParamList = Utilities.typedParamList
local returnTypeExpr = Utilities.returnTypeExpr
local tupleTypeExpr = Utilities.tupleTypeExpr
local callbackTypeExpr = Utilities.callbackTypeExpr
local callbackSignatureTypeExpr = Utilities.callbackSignatureTypeExpr
local callableTypeExpr = Utilities.callableTypeExpr
local messageClientCallbackTypeName = Utilities.messageClientCallbackTypeName
local messageServerCallbackTypeName = Utilities.messageServerCallbackTypeName
local messageClientApiTypeName = Utilities.messageClientApiTypeName
local messageServerApiTypeName = Utilities.messageServerApiTypeName
local collectMessages = Utilities.collectMessages
local splitParams = Utilities.splitParams
local paramNames = Utilities.paramNames
local canSendEvent = Utilities.canSendEvent
local canReceiveEvent = Utilities.canReceiveEvent
local resolveTypeBranding = Utilities.resolveTypeBranding
local resolveDecodeStruct = Utilities.resolveDecodeStruct
local expandDecodeParams = Utilities.expandDecodeParams
local getStringBoundComment = Utilities.getStringBoundComment
local indent = Utilities.indent

local function emitTupleBoundsComment(lines: { string }, label: string, params: { Ast.Param })
    local bounds: { string } = {}
    for index = 1, #params do
        local param = params[index]
        local boundComment = getStringBoundComment(param.type)
        if boundComment ~= nil then
            bounds[#bounds + 1] = ("%s=%s"):format(param.name, boundComment)
        end
    end
    if #bounds > 0 then
        addLine(lines, 0, ("-- %s bounds: %s"):format(label, join(bounds)))
    end
end

local function emitStructType(lines: { string }, structDef: Ast.Struct, typeName: string)
    addLine(lines, 0, ("export type %s = {"):format(typeName))
    for fieldIndex = 1, #structDef.fields do
        local field = structDef.fields[fieldIndex]
        local fieldLine = ("%s: %s,"):format(luauTypeFieldKey(field.name), toLuauType(field.type))
        local boundComment = getStringBoundComment(field.type)
        if boundComment ~= nil then
            fieldLine ..= (" -- %s"):format(boundComment)
        end
        addLine(lines, 1, fieldLine)
    end
    addLine(lines, 0, "}")
    addLine(lines, 0, "")
end

local function buildScopeTypeTable(
    scope: Analyzer.AnalyzedScope,
    depth: number,
    isRoot: boolean,
    isServer: boolean,
    infoByMessage: { [Analyzer.AnalyzedMessage]: MessageInfo }
): { string }
    local lines: { string } = {}
    if isRoot then
        lines[#lines + 1] = ("export type %s = {"):format(isServer and "NetServer" or "NetClient")
    else
        lines[#lines + 1] = ("%s: {"):format(luauTypeFieldKey(scope.name))
    end

    for index = 1, #scope.messages do
        local msg = scope.messages[index]
        local info = infoByMessage[msg]
        if info ~= nil then
            local apiTypeName = isServer and messageServerApiTypeName(info.apiBase) or messageClientApiTypeName(info.apiBase)
            lines[#lines + 1] = ("%s: %s,"):format(luauTypeFieldKey(msg.name), apiTypeName)
        end
    end

    for index = 1, #scope.scopes do
        local child = scope.scopes[index]
        local childLines = buildScopeTypeTable(child, depth + 1, false, isServer, infoByMessage)
        for lineIndex = 1, #childLines do
            if lineIndex == #childLines then
                lines[#lines + 1] = childLines[lineIndex] .. ","
            else
                lines[#lines + 1] = childLines[lineIndex]
            end
        end
    end

    if isRoot then
        lines[#lines + 1] = "StepReplication: () -> (),"
        lines[#lines + 1] = "Stats: NetStats,"
    end
    lines[#lines + 1] = "}"
    return indent(lines, depth)
end

local function generateTypes(schema: Analyzer.AnalyzedSchema): string
    local typeBranding = resolveTypeBranding(schema.options)
    local decodeStructMode = resolveDecodeStruct(schema.options)
    local lines: { string } = {
        "--!strict",
        "--!native",
        "--!optimize 2",
        "-- Name: Types",
        "-- Purpose: Generated Luau types for NetRay schema",
        "-- Generated-by: NetRay-Compiler",
        "",
    }

    local messages: { MessageInfo } = {}
    local symbolByMessage: { [Analyzer.AnalyzedMessage]: string } = {}
    local infoByMessage: { [Analyzer.AnalyzedMessage]: MessageInfo } = {}
    collectMessages(schema.root, schema.root.name, messages, symbolByMessage)
    for index = 1, #messages do
        local info = messages[index]
        infoByMessage[info.message] = info
    end

    addLine(lines, 0, "export type TypeBranding = \"Off\" | \"On\"")
    addLine(lines, 0, ("export type ActiveTypeBranding = %q"):format(typeBranding))
    addLine(lines, 0, "export type Brand<T, B> = T & { __brand: B }")
    if typeBranding == "On" then
        addLine(lines, 0, "export type u8 = Brand<number, \"u8\">")
        addLine(lines, 0, "export type i8 = Brand<number, \"i8\">")
        addLine(lines, 0, "export type u16 = Brand<number, \"u16\">")
        addLine(lines, 0, "export type i16 = Brand<number, \"i16\">")
        addLine(lines, 0, "export type u32 = Brand<number, \"u32\">")
        addLine(lines, 0, "export type i32 = Brand<number, \"i32\">")
        addLine(lines, 0, "export type f16 = Brand<number, \"f16\">")
        addLine(lines, 0, "export type f32 = Brand<number, \"f32\">")
        addLine(lines, 0, "export type f64 = Brand<number, \"f64\">")
    else
        addLine(lines, 0, "export type u8 = number")
        addLine(lines, 0, "export type i8 = number")
        addLine(lines, 0, "export type u16 = number")
        addLine(lines, 0, "export type i16 = number")
        addLine(lines, 0, "export type u32 = number")
        addLine(lines, 0, "export type i32 = number")
        addLine(lines, 0, "export type f16 = number")
        addLine(lines, 0, "export type f32 = number")
        addLine(lines, 0, "export type f64 = number")
    end
    addLine(lines, 0, "")

    addLine(lines, 0, "export type Connection = {")
    addLine(lines, 1, "Connected: boolean,")
    addLine(lines, 1, "Disconnect: (self: Connection) -> (),")
    addLine(lines, 0, "}")
    addLine(lines, 0, "")

    addLine(lines, 0, "export type EventSender1<T> = {")
    addLine(lines, 1, "Fire: (T) -> boolean,")
    addLine(lines, 0, "}")
    addLine(lines, 0, "export type EventReceiver1<T> = {")
    addLine(lines, 1, "On: ((T) -> ()) -> Connection,")
    addLine(lines, 0, "}")
    addLine(lines, 0, "export type EventDuplex1<T> = EventSender1<T> & EventReceiver1<T>")
    addLine(lines, 0, "")

    addLine(lines, 0, "export type NetStats = {")
    addLine(lines, 1, "GetReliableDropped: () -> number,")
    addLine(lines, 1, "GetUnreliableDropped: () -> number,")
    addLine(lines, 1, "GetReliableQueueSize: () -> number,")
    addLine(lines, 1, "GetUnreliableQueueSize: () -> number,")
    addLine(lines, 0, "}")
    addLine(lines, 0, "")

    for index = 1, #schema.structs do
        local structDef = schema.structs[index]
        emitStructType(lines, structDef, structDef.name)
    end

    for index = 1, #schema.enums do
        local enumDef = schema.enums[index]
        local values = enumDef.values or {}
        if #values > 0 then
            local chunks: { string } = {}
            for valueIndex = 1, #values do
                chunks[#chunks + 1] = ("%q"):format(values[valueIndex])
            end
            addLine(lines, 0, ("export type %s = (%s)"):format(enumDef.name, table.concat(chunks, " | ")))
            addLine(lines, 0, "")
        end
    end

    for index = 1, #schema.sets do
        local setDef = schema.sets[index]
        local fields: { string } = {}
        for valueIndex = 1, #setDef.values do
            fields[#fields + 1] = ("%s: boolean"):format(luauTypeFieldKey(setDef.values[valueIndex]))
        end
        addLine(lines, 0, ("export type %s = { %s }"):format(setDef.name, join(fields)))
        addLine(lines, 0, "")
    end

    for index = 1, #schema.taggedEnums do
        local enumDef = schema.taggedEnums[index]
        local variants = (enumDef.variants :: any) :: { any }?
        local tagField = enumDef.tag or "Type"
        if variants ~= nil and #variants > 0 then
            local unionParts: { string } = {}
            for variantIndex = 1, #variants do
                local variant = variants[variantIndex]
                local fields = (variant.fields :: any) :: { Ast.Param }?
                local parts: { string } = {}
                parts[#parts + 1] = ("%s: %q"):format(luauTypeFieldKey(tagField), variant.name)
                if fields ~= nil then
                    for fieldIndex = 1, #fields do
                        local field = fields[fieldIndex]
                        parts[#parts + 1] = ("%s: %s"):format(luauTypeFieldKey(field.name), toLuauType(field.type))
                    end
                end
                unionParts[#unionParts + 1] = ("{ %s }"):format(join(parts))
            end
            addLine(lines, 0, ("export type %s = %s"):format(enumDef.name, table.concat(unionParts, " | ")))
            addLine(lines, 0, "")
        end
    end

    for index = 1, #messages do
        local info = messages[index]
        local message = info.message
        local baseName = info.apiBase
        local returns = message.returns or {}
        local clientCallbackTypeName = messageClientCallbackTypeName(baseName, message.category)
        local serverCallbackTypeName = messageServerCallbackTypeName(baseName, message.category)
        local clientApiTypeName = messageClientApiTypeName(baseName)
        local serverApiTypeName = messageServerApiTypeName(baseName)
        local callbackParams = expandDecodeParams(message.params, schema.structByName, decodeStructMode)

        if message.category == "function" then
            local requestTupleTypeName = baseName .. "_RequestTuple"
            local responseTupleTypeName = baseName .. "_ResponseTuple"
            local clientCallTypeName = baseName .. "_ClientCall"
            local serverCallTypeName = baseName .. "_ServerCall"
            local clientHandlerTypeName = baseName .. "_ClientHandler"
            local serverHandlerTypeName = baseName .. "_ServerHandler"

            emitTupleBoundsComment(lines, info.fullName .. " request", message.params)
            addLine(lines, 0, ("export type %s = %s"):format(requestTupleTypeName, tupleTypeExpr(message.params)))
            emitTupleBoundsComment(lines, info.fullName .. " response", returns)
            addLine(lines, 0, ("export type %s = %s"):format(responseTupleTypeName, tupleTypeExpr(returns)))
            addLine(lines, 0, ("export type %s = %s"):format(clientCallTypeName, callbackSignatureTypeExpr(message.params, false, returns)))
            addLine(lines, 0, ("export type %s = %s"):format(serverCallTypeName, callbackSignatureTypeExpr(message.params, true, returns)))
            addLine(lines, 0, ("export type %s = %s"):format(clientHandlerTypeName, callbackSignatureTypeExpr(callbackParams, false, returns)))
            addLine(lines, 0, ("export type %s = %s"):format(serverHandlerTypeName, callbackSignatureTypeExpr(callbackParams, true, returns)))
            addLine(lines, 0, ("export type %s = %s"):format(clientCallbackTypeName, callbackTypeExpr(callbackParams, false, returns)))
            addLine(lines, 0, ("export type %s = %s"):format(serverCallbackTypeName, callbackTypeExpr(callbackParams, true, returns)))

            addLine(lines, 0, ("export type %s = {"):format(clientApiTypeName))
            addLine(lines, 1, ("On: (%s) -> Connection,"):format(clientCallbackTypeName))
            addLine(lines, 1, ("Call: %s,"):format(clientCallTypeName))
            addLine(lines, 0, "}")
            addLine(lines, 0, ("export type %s = {"):format(serverApiTypeName))
            addLine(lines, 1, ("On: (%s) -> Connection,"):format(serverCallbackTypeName))
            addLine(lines, 1, ("Call: %s,"):format(serverCallTypeName))
            addLine(lines, 0, "}")
        else
            local argsTypeName = baseName .. "_Args"
            local tupleHandlerTypeName = baseName .. "_TupleHandler"
            local clientCanSend = canSendEvent(message.from, false)
            local clientCanReceive = canReceiveEvent(message.from, false)
            local serverCanSend = canSendEvent(message.from, true)
            local serverCanReceive = canReceiveEvent(message.from, true)
            local eventCall = message.call or "ManySync"
            local usePollingApi = eventCall == "Polling"

            emitTupleBoundsComment(lines, info.fullName .. " args", message.params)
            addLine(lines, 0, ("export type %s = %s"):format(argsTypeName, tupleTypeExpr(message.params)))
            addLine(lines, 0, ("export type %s = %s"):format(tupleHandlerTypeName, callbackSignatureTypeExpr(callbackParams, false, EMPTY_PARAMS)))
            addLine(lines, 0, ("export type %s = %s"):format(clientCallbackTypeName, callbackTypeExpr(callbackParams, false, EMPTY_PARAMS)))
            addLine(lines, 0, ("export type %s = %s"):format(serverCallbackTypeName, callbackTypeExpr(callbackParams, true, EMPTY_PARAMS)))

            addLine(lines, 0, ("export type %s = {"):format(clientApiTypeName))
            if clientCanSend then
                addLine(lines, 1, ("Fire: %s,"):format(callableTypeExpr(message.params, false, "boolean")))
            end
            if clientCanReceive then
                if usePollingApi then
                    addLine(lines, 1, "Iter: () -> (() -> any),")
                else
                    addLine(lines, 1, ("On: (%s) -> Connection,"):format(clientCallbackTypeName))
                end
            end
            addLine(lines, 0, "}")

            addLine(lines, 0, ("export type %s = {"):format(serverApiTypeName))
            if serverCanSend then
                local fireListParamTypes: { string } = { "{ Player }" }
                for paramIndex = 1, #message.params do
                    fireListParamTypes[#fireListParamTypes + 1] = toLuauType(message.params[paramIndex].type)
                end
                local fireListType = ("(%s) -> boolean"):format(join(fireListParamTypes))
                addLine(lines, 1, ("Fire: %s,"):format(callableTypeExpr(message.params, true, "boolean")))
                addLine(lines, 1, ("FireAll: %s,"):format(callableTypeExpr(message.params, false, "boolean")))
                addLine(lines, 1, ("FireList: %s,"):format(fireListType))
                addLine(lines, 1, ("FireExcept: %s,"):format(callableTypeExpr(message.params, true, "boolean")))
            end
            if serverCanReceive then
                if usePollingApi then
                    addLine(lines, 1, "Iter: () -> (() -> any),")
                else
                    addLine(lines, 1, ("On: (%s) -> Connection,"):format(serverCallbackTypeName))
                end
            end
            addLine(lines, 0, "}")
        end
        addLine(lines, 0, "")
    end

    local clientScopeTypeLines = buildScopeTypeTable(schema.root, 0, true, false, infoByMessage)
    appendLines(lines, clientScopeTypeLines)
    addLine(lines, 0, "")
    local serverScopeTypeLines = buildScopeTypeTable(schema.root, 0, true, true, infoByMessage)
    appendLines(lines, serverScopeTypeLines)
    addLine(lines, 0, "")
    addLine(lines, 0, "export type Net = NetClient | NetServer")
    addLine(lines, 0, "")

    addLine(lines, 0, "local Types = {")
    addLine(lines, 1, "u8 = (0 :: any) :: u8,")
    addLine(lines, 1, "i8 = (0 :: any) :: i8,")
    addLine(lines, 1, "u16 = (0 :: any) :: u16,")
    addLine(lines, 1, "i16 = (0 :: any) :: i16,")
    addLine(lines, 1, "u32 = (0 :: any) :: u32,")
    addLine(lines, 1, "i32 = (0 :: any) :: i32,")
    addLine(lines, 1, "f16 = (0 :: any) :: f16,")
    addLine(lines, 1, "f32 = (0 :: any) :: f32,")
    addLine(lines, 1, "f64 = (0 :: any) :: f64,")
    addLine(lines, 1, "Connection = ({ Connected = true, Disconnect = function(_self) end } :: any) :: Connection,")
    addLine(
        lines,
        1,
        "NetStats = ({ GetReliableDropped = function() return 0 end, GetUnreliableDropped = function() return 0 end, GetReliableQueueSize = function() return 0 end, GetUnreliableQueueSize = function() return 0 end } :: any) :: NetStats,"
    )
    for structIndex = 1, #schema.structs do
        local structName = schema.structs[structIndex].name
        addLine(lines, 1, ("%s = ({} :: any) :: %s,"):format(structName, structName))
    end
    for enumIndex = 1, #schema.enums do
        local enumName = schema.enums[enumIndex].name
        addLine(lines, 1, ("%s = (\"\" :: any) :: %s,"):format(enumName, enumName))
    end
    for setIndex = 1, #schema.sets do
        local setName = schema.sets[setIndex].name
        addLine(lines, 1, ("%s = ({} :: any) :: %s,"):format(setName, setName))
    end
    for taggedIndex = 1, #schema.taggedEnums do
        local taggedName = schema.taggedEnums[taggedIndex].name
        addLine(lines, 1, ("%s = ({} :: any) :: %s,"):format(taggedName, taggedName))
    end
    for messageIndex = 1, #messages do
        local messageInfo = messages[messageIndex]
        local message = messageInfo.message
        local clientCallbackTypeName = messageClientCallbackTypeName(messageInfo.apiBase, message.category)
        local serverCallbackTypeName = messageServerCallbackTypeName(messageInfo.apiBase, message.category)
        local clientApiTypeName = messageClientApiTypeName(messageInfo.apiBase)
        local serverApiTypeName = messageServerApiTypeName(messageInfo.apiBase)
        addLine(lines, 1, ("%s = ((function(...) end) :: any) :: %s,"):format(clientCallbackTypeName, clientCallbackTypeName))
        addLine(lines, 1, ("%s = ((function(...) end) :: any) :: %s,"):format(serverCallbackTypeName, serverCallbackTypeName))
        addLine(lines, 1, ("%s = ({} :: any) :: %s,"):format(clientApiTypeName, clientApiTypeName))
        addLine(lines, 1, ("%s = ({} :: any) :: %s,"):format(serverApiTypeName, serverApiTypeName))
    end
    addLine(lines, 1, "NetClient = ({} :: any) :: NetClient,")
    addLine(lines, 1, "NetServer = ({} :: any) :: NetServer,")
    addLine(lines, 1, "Net = ({} :: any) :: Net,")
    addLine(lines, 0, "}")
    addLine(lines, 0, "")
    addLine(lines, 0, "return table.freeze(Types)")
    addLine(lines, 0, "")

    return concat(lines)
end
return {
    generateTypes = generateTypes,
}
