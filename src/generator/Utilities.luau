--!strict
-- Name: Utilities
-- Purpose: Shared generator helpers

local Ast = require("../idl/Ast")
local Analyzer = require("../idl/Analyzer")
local Types = require("./Types")

type MessageInfo = Types.MessageInfo
type EmitState = Types.EmitState
type WidthInfo = Types.WidthInfo
type LengthPrefixInfo = Types.LengthPrefixInfo
type TypeBrandingMode = Types.TypeBrandingMode
type DecodeStructMode = Types.DecodeStructMode
type DecodedLeaf = Types.DecodedLeaf
type DecodedParamPlan = Types.DecodedParamPlan
type DecodeVarMeta = Types.DecodeVarMeta
type DecodeVarCursor = Types.DecodeVarCursor

local EMPTY_PARAMS = Types.EMPTY_PARAMS
local LUAU_KEYWORDS = Types.LUAU_KEYWORDS
local PRIMITIVE_BYTES = Types.PRIMITIVE_BYTES
local PRIMITIVE_WRITERS = Types.PRIMITIVE_WRITERS
local PRIMITIVE_READERS = Types.PRIMITIVE_READERS
local MAX_FIXED_LENGTH_BOUND = Types.MAX_FIXED_LENGTH_BOUND
local MAX_VARINT_LENGTH = Types.MAX_VARINT_LENGTH
local function widthForBound(maxValue: number): WidthInfo
    if maxValue <= 255 then
        return {
            bytes = 1,
            writer = "writeu8",
            reader = "readu8",
            maxValue = 255,
        }
    end

    return {
        bytes = 2,
        writer = "writeu16",
        reader = "readu16",
        maxValue = 65535,
    }
end

local function validateBoundedLength(maxValue: number?, typeLabel: string): number?
    if maxValue == nil then
        return nil
    end
    if maxValue < 0 then
        error(("%s max length cannot be negative (%d)"):format(typeLabel, maxValue))
    end
    if maxValue > MAX_FIXED_LENGTH_BOUND then
        error(("%s max length %d exceeds supported u16 limit"):format(typeLabel, maxValue))
    end
    return maxValue
end

local function getLengthPrefixInfo(typeLabel: string, maxValue: number?): LengthPrefixInfo
    local declaredMax = validateBoundedLength(maxValue, typeLabel)
    if declaredMax == nil then
        return {
            declaredMax = nil,
            isVarint = true,
            width = nil,
        }
    end
    return {
        declaredMax = declaredMax,
        isVarint = false,
        width = widthForBound(declaredMax),
    }
end

local function getStringLengthPrefixInfo(typeDef: Ast.Type): LengthPrefixInfo
    return getLengthPrefixInfo("String", typeDef.max)
end

local function getArrayLengthPrefixInfo(typeDef: Ast.Type): LengthPrefixInfo
    return getLengthPrefixInfo("Array", typeDef.max)
end

local function getFixedArrayLength(typeDef: Ast.Type): number
    local fixedLength = typeDef.max
    if fixedLength == nil then
        error("FixedArray requires a compile-time length")
    end
    if fixedLength < 0 then
        error(("FixedArray length cannot be negative (%d)"):format(fixedLength))
    end
    if fixedLength > MAX_FIXED_LENGTH_BOUND then
        error(("FixedArray length %d exceeds supported u16 limit"):format(fixedLength))
    end
    return fixedLength
end

local function getMapLengthPrefixInfo(typeDef: Ast.Type): LengthPrefixInfo
    return getLengthPrefixInfo("Map", typeDef.max)
end

local function getMessageIdWidthInfo(maxId: number): WidthInfo
    if maxId < 0 then
        error(("Message ID cannot be negative (%d)"):format(maxId))
    end
    if maxId > 65535 then
        error(("Message ID %d exceeds supported u16 limit"):format(maxId))
    end
    return widthForBound(maxId)
end

local function isValidateFull(validateLevel: Analyzer.ValidateLevel): boolean
    return validateLevel == "Full"
end

local function isValidateBasicOrFull(validateLevel: Analyzer.ValidateLevel): boolean
    return validateLevel ~= "Off"
end

local function emitError(
    lines: { string },
    depth: number,
    _validateLevel: Analyzer.ValidateLevel,
    _detailedMessage: string,
    shortCodeConst: string
)
    lines[#lines + 1] = string.rep("    ", depth) .. ("error(%s)"):format(shortCodeConst)
end

local function indent(lines: { string }, depth: number): { string }
    local prefix = string.rep("    ", depth)
    local out: { string } = {}
    for index = 1, #lines do
        out[#out + 1] = prefix .. lines[index]
    end
    return out
end

local function concat(lines: { string }): string
    return table.concat(lines, "\n") .. "\n"
end

local function appendLines(target: { string }, source: { string })
    for index = 1, #source do
        target[#target + 1] = source[index]
    end
end

local function join(values: { string }): string
    if #values == 0 then
        return ""
    end
    return table.concat(values, ", ")
end

local function sanitizeIdentifier(value: string): string
    local sanitized = string.gsub(value, "[^%w_]", "_")
    if string.match(sanitized, "^[0-9]") then
        sanitized = "_" .. sanitized
    end
    return sanitized
end

local function addLine(lines: { string }, depth: number, text: string)
    lines[#lines + 1] = string.rep("    ", depth) .. text
end

local function nextTemp(state: EmitState, prefix: string): string
    state.tempIndex += 1
    return ("%s_%d"):format(prefix, state.tempIndex)
end

local function splitParams(params: { Ast.Param }): ({ Ast.Param }, { Ast.Param })
    local serialized: { Ast.Param } = {}
    local passthrough: { Ast.Param } = {}
    for index = 1, #params do
        local param = params[index]
        if param.type.kind == "passthrough" then
            passthrough[#passthrough + 1] = param
        else
            serialized[#serialized + 1] = param
        end
    end
    return serialized, passthrough
end

local function getPassthroughTypeName(param: Ast.Param): string
    local value = (param.type :: any).value
    if type(value) == "string" and value ~= "" then
        return value
    end
    return "any"
end

local function getPassthroughTypeNameFromType(typeDef: Ast.Type): string
    local value = (typeDef.value :: any)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return "unknown"
end

local function normalizeTypeKind(kind: string): string
    if kind == "boolean" then
        return "bool"
    end
    return kind
end

local function isNumericKind(kind: string): boolean
    return kind == "u8"
        or kind == "i8"
        or kind == "u16"
        or kind == "i16"
        or kind == "u32"
        or kind == "i32"
        or kind == "f16"
        or kind == "f32"
        or kind == "f64"
end

local function getStringBoundComment(typeDef: Ast.Type): string?
    local kind = normalizeTypeKind(typeDef.kind)
    if kind ~= "string" or typeDef.max == nil then
        return nil
    end
    return ("string<%d>"):format(typeDef.max)
end

local function resolveTypeBranding(options: { Ast.Option }): TypeBrandingMode
    for index = 1, #options do
        local option = options[index]
        if string.lower(option.name) == "typebranding" then
            local lowered = string.lower(option.value)
            if lowered == "on" then
                return "On"
            end
            if lowered == "off" then
                return "Off"
            end
            error(("Invalid TypeBranding option value '%s' (expected Off or On)"):format(option.value))
        end
    end
    return "Off"
end

local function resolveDecodeStruct(options: { Ast.Option }): DecodeStructMode
    for index = 1, #options do
        local option = options[index]
        if string.lower(option.name) == "decodestruct" then
            local lowered = string.lower(option.value)
            if lowered == "locals" then
                return "Locals"
            end
            if lowered == "table" then
                return "Table"
            end
            error(("Invalid DecodeStruct option value '%s' (expected Locals or Table)"):format(option.value))
        end
    end
    return "Locals"
end

local function luauTypeFieldKey(fieldName: string): string
    if string.match(fieldName, "^[A-Za-z_][A-Za-z0-9_]*$") ~= nil and LUAU_KEYWORDS[fieldName] ~= true then
        return fieldName
    end
    return ("[%q]"):format(fieldName)
end

local function toLuauType(typeDef: Ast.Type): string
    local kind = normalizeTypeKind(typeDef.kind)
    if isNumericKind(kind) then
        return kind
    end
    if kind == "bool" then
        return "boolean"
    end
    if kind == "string" then
        return "string"
    end
    if kind == "buffer" then
        return "buffer"
    end
    if kind == "vector" then
        return "Vector3"
    end
    if kind == "cframe" then
        return "CFrame"
    end
    if kind == "brickcolor" then
        return "BrickColor"
    end
    if kind == "color3" then
        return "Color3"
    end
    if kind == "datetime" or kind == "datetimemillis" then
        return "DateTime"
    end
    if kind == "enum" then
        local values = (typeDef.values :: any) :: { string }?
        if values == nil or #values == 0 then
            return "string"
        end
        local chunks: { string } = {}
        for index = 1, #values do
            chunks[#chunks + 1] = ("%q"):format(values[index])
        end
        return ("(%s)"):format(table.concat(chunks, " | "))
    end
    if kind == "set" then
        local values = (typeDef.values :: any) :: { string }?
        if values == nil or #values == 0 then
            return "{ [string]: boolean }"
        end
        local fields: { string } = {}
        for index = 1, #values do
            fields[#fields + 1] = ("%s: boolean"):format(luauTypeFieldKey(values[index]))
        end
        return ("{ %s }"):format(join(fields))
    end
    if kind == "inline_struct" then
        local fields = (typeDef.fields :: any) :: { Ast.Param }?
        if fields == nil then
            return "{ [string]: any }"
        end
        local chunks: { string } = {}
        for index = 1, #fields do
            local field = fields[index]
            chunks[#chunks + 1] = ("%s: %s"):format(luauTypeFieldKey(field.name), toLuauType(field.type))
        end
        return ("{ %s }"):format(join(chunks))
    end
    if kind == "tagged_enum" then
        local tagField = (typeDef.tag :: any) :: string? or "Type"
        local variants = (typeDef.variants :: any) :: { any }?
        if variants == nil or #variants == 0 then
            return "{ [string]: any }"
        end
        local unions: { string } = {}
        for index = 1, #variants do
            local variant = variants[index]
            local fields = (variant.fields :: any) :: { Ast.Param }?
            local fieldChunks: { string } = {}
            fieldChunks[#fieldChunks + 1] = ("%s: %q"):format(luauTypeFieldKey(tagField), variant.name)
            if fields ~= nil then
                for fieldIndex = 1, #fields do
                    local field = fields[fieldIndex]
                    fieldChunks[#fieldChunks + 1] = ("%s: %s"):format(luauTypeFieldKey(field.name), toLuauType(field.type))
                end
            end
            unions[#unions + 1] = ("{ %s }"):format(join(fieldChunks))
        end
        return table.concat(unions, " | ")
    end
    if kind == "passthrough" then
        return getPassthroughTypeNameFromType(typeDef)
    end
    if kind == "optional" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Optional type is missing value type")
        end
        return ("%s?"):format(toLuauType(valueType))
    end
    if kind == "array" or kind == "fixedarray" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Array type is missing value type")
        end
        return ("{ %s }"):format(toLuauType(valueType))
    end
    if kind == "map" then
        local keyType = (typeDef.key :: any) :: Ast.Type?
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if keyType == nil or valueType == nil then
            error("Map type is missing key/value types")
        end
        local keyName = toLuauType(keyType)
        local valueName = toLuauType(valueType)
        return ("{ [%s]: %s }"):format(keyName, valueName)
    end
    return kind
end

local function typedParamList(params: { Ast.Param }): string
    local chunks: { string } = {}
    for index = 1, #params do
        local param = params[index]
        chunks[#chunks + 1] = ("%s: %s"):format(param.name, toLuauType(param.type))
    end
    return join(chunks)
end

local function returnTypeExpr(params: { Ast.Param }): string
    if #params == 0 then
        return "()"
    end
    local chunks: { string } = {}
    for index = 1, #params do
        chunks[#chunks + 1] = toLuauType(params[index].type)
    end
    if #chunks == 1 then
        return chunks[1]
    end
    return ("(%s)"):format(join(chunks))
end

local function tupleTypeExpr(params: { Ast.Param }): string
    local chunks: { string } = {}
    for index = 1, #params do
        chunks[#chunks + 1] = toLuauType(params[index].type)
    end
    if #chunks == 0 then
        return "() -> ()"
    end
    if #chunks == 1 then
        return ("() -> %s"):format(chunks[1])
    end
    return ("() -> (%s)"):format(join(chunks))
end

local function callbackTypeExpr(params: { Ast.Param }, includePlayer: boolean, returns: { Ast.Param }): string
    local chunks: { string } = {}
    if includePlayer then
        chunks[#chunks + 1] = "player: Player"
    end
    for index = 1, #params do
        local param = params[index]
        chunks[#chunks + 1] = ("%s: %s"):format(param.name, toLuauType(param.type))
    end
    return ("(%s) -> %s"):format(join(chunks), returnTypeExpr(returns))
end

local function callbackSignatureTypeExpr(params: { Ast.Param }, includePlayer: boolean, returns: { Ast.Param }): string
    local chunks: { string } = {}
    if includePlayer then
        chunks[#chunks + 1] = "Player"
    end
    for index = 1, #params do
        chunks[#chunks + 1] = toLuauType(params[index].type)
    end
    return ("(%s) -> %s"):format(join(chunks), returnTypeExpr(returns))
end

local function callableTypeExpr(params: { Ast.Param }, includePlayer: boolean, returnTypeName: string): string
    local chunks: { string } = {}
    if includePlayer then
        chunks[#chunks + 1] = "Player"
    end
    for index = 1, #params do
        chunks[#chunks + 1] = toLuauType(params[index].type)
    end
    return ("(%s) -> %s"):format(join(chunks), returnTypeName)
end

local function messageClientCallbackTypeName(baseName: string, category: string): string
    if category == "function" then
        return baseName .. "_ClientFunctionCallback"
    end
    return baseName .. "_ClientEventCallback"
end

local function messageServerCallbackTypeName(baseName: string, category: string): string
    if category == "function" then
        return baseName .. "_ServerFunctionCallback"
    end
    return baseName .. "_ServerEventCallback"
end

local function messageClientApiTypeName(baseName: string): string
    return baseName .. "_ClientApi"
end

local function messageServerApiTypeName(baseName: string): string
    return baseName .. "_ServerApi"
end

local function collectMessages(
    scope: Analyzer.AnalyzedScope,
    scopePath: string,
    out: { MessageInfo },
    symbolByMessage: { [Analyzer.AnalyzedMessage]: string }
)
    for index = 1, #scope.messages do
        local message = scope.messages[index]
        if message.id < 1 or message.id > 65535 then
            error(("Message ID %d for '%s' exceeds u16 range"):format(message.id, message.name))
        end
        local fullName = scopePath .. "." .. message.name
        local symbol = sanitizeIdentifier(fullName .. "_" .. message.category .. "_" .. tostring(message.id))
        local apiBase = sanitizeIdentifier(fullName .. "_" .. message.category)
        local serializedParams, passthroughParams = splitParams(message.params)
        local returns = message.returns or {}
        local serializedReturns, passthroughReturns = splitParams(returns)

        local info: MessageInfo = {
            message = message,
            symbol = symbol,
            apiBase = apiBase,
            fullName = fullName,
            serializedParams = serializedParams,
            passthroughParams = passthroughParams,
            serializedReturns = serializedReturns,
            passthroughReturns = passthroughReturns,
        }
        out[#out + 1] = info
        symbolByMessage[message] = symbol
    end

    for index = 1, #scope.scopes do
        local child = scope.scopes[index]
        collectMessages(child, scopePath .. "." .. child.name, out, symbolByMessage)
    end
end

local function buildScopeTables(
    scope: Analyzer.AnalyzedScope,
    depth: number,
    isRoot: boolean,
    symbolByMessage: { [Analyzer.AnalyzedMessage]: string },
    rootTypeName: string?
): { string }
    local lines: { string } = {}
    if isRoot then
        if rootTypeName ~= nil then
            lines[#lines + 1] = ("local %s: %s = {"):format(scope.name, rootTypeName)
        else
            lines[#lines + 1] = "local " .. scope.name .. " = {"
        end
    else
        lines[#lines + 1] = ("%s = {"):format(luauTypeFieldKey(scope.name))
    end

    for index = 1, #scope.messages do
        local msg = scope.messages[index]
        local symbol = symbolByMessage[msg] or msg.name
        lines[#lines + 1] = ("%s = %s,"):format(luauTypeFieldKey(msg.name), symbol)
    end

    for index = 1, #scope.scopes do
        local child = scope.scopes[index]
        local childLines = buildScopeTables(child, depth + 1, false, symbolByMessage, nil)
        for lineIndex = 1, #childLines do
            if lineIndex == #childLines then
                lines[#lines + 1] = childLines[lineIndex] .. ","
            else
                lines[#lines + 1] = childLines[lineIndex]
            end
        end
    end

    lines[#lines + 1] = "}"
    return indent(lines, depth)
end

local function paramNames(params: { Ast.Param }): { string }
    local names: { string } = {}
    for index = 1, #params do
        names[#names + 1] = params[index].name
    end
    return names
end

local function canUseDotField(fieldName: string): boolean
    if string.match(fieldName, "^[A-Za-z_][A-Za-z0-9_]*$") == nil then
        return false
    end
    return LUAU_KEYWORDS[fieldName] ~= true
end

local function fieldAccessExpr(valueExpr: string, fieldName: string): string
    if canUseDotField(fieldName) then
        return ("%s.%s"):format(valueExpr, fieldName)
    end
    return ("%s[%q]"):format(valueExpr, fieldName)
end

local function expandDecodeParams(
    params: { Ast.Param },
    structByName: { [string]: Ast.Struct },
    decodeStructMode: DecodeStructMode
): { Ast.Param }
    local expanded: { Ast.Param } = {}
    for index = 1, #params do
        local param = params[index]
        local structDecl = structByName[normalizeTypeKind(param.type.kind)]
        if decodeStructMode == "Locals" and structDecl ~= nil then
            for fieldIndex = 1, #structDecl.fields do
                local field = structDecl.fields[fieldIndex]
                expanded[#expanded + 1] = {
                    name = ("%s_%s"):format(param.name, field.name),
                    type = field.type,
                }
            end
        else
            expanded[#expanded + 1] = param
        end
    end
    return expanded
end

local function buildDecodedParamPlans(
    params: { Ast.Param },
    structByName: { [string]: Ast.Struct },
    decodeStructMode: DecodeStructMode
): { DecodedParamPlan }
    local plans: { DecodedParamPlan } = {}
    for index = 1, #params do
        local param = params[index]
        local paramName = sanitizeIdentifier(param.name)
        local leaves: { DecodedLeaf } = {}
        local structDecl = structByName[normalizeTypeKind(param.type.kind)]
        if decodeStructMode == "Locals" and structDecl ~= nil then
            for fieldIndex = 1, #structDecl.fields do
                local field = structDecl.fields[fieldIndex]
                leaves[#leaves + 1] = {
                    labelSuffix = param.name .. "." .. field.name,
                    targetName = ("decoded_%s_%s"):format(paramName, sanitizeIdentifier(field.name)),
                    typeDef = field.type,
                }
            end
        else
            leaves[#leaves + 1] = {
                labelSuffix = param.name,
                targetName = ("decoded_%s"):format(paramName),
                typeDef = param.type,
            }
        end

        local leafNames: { string } = {}
        for leafIndex = 1, #leaves do
            leafNames[#leafNames + 1] = leaves[leafIndex].targetName
        end
        plans[#plans + 1] = {
            leaves = leaves,
            leafNames = leafNames,
        }
    end
    return plans
end

local function collectDecodedLeafNames(plans: { DecodedParamPlan }): { string }
    local names: { string } = {}
    for planIndex = 1, #plans do
        local leafNames = plans[planIndex].leafNames
        for leafIndex = 1, #leafNames do
            names[#names + 1] = leafNames[leafIndex]
        end
    end
    return names
end

local function canSendEvent(direction: string?, isServer: boolean): boolean
    local resolved = direction or "both"
    if resolved == "client" then
        return not isServer
    end
    if resolved == "server" then
        return isServer
    end
    return true
end

local function canReceiveEvent(direction: string?, isServer: boolean): boolean
    local resolved = direction or "both"
    if resolved == "client" then
        return isServer
    end
    if resolved == "server" then
        return not isServer
    end
    return true
end

local function collectionHintKey(kind: string, valueExpr: string): string
    return ("%s:%s"):format(kind, valueExpr)
end

local function cacheCollectionHint(
    hints: { [string]: string }?,
    depth: number,
    kind: string,
    valueExpr: string,
    tempVar: string
)
    if hints ~= nil and depth == 1 then
        hints[collectionHintKey(kind, valueExpr)] = tempVar
    end
end

local function getCollectionHint(
    hints: { [string]: string }?,
    depth: number,
    kind: string,
    valueExpr: string
): string?
    if hints == nil or depth ~= 1 then
        return nil
    end
    return hints[collectionHintKey(kind, valueExpr)]
end

local function fixedBytesForType(typeDef: Ast.Type): number?
    local kind = normalizeTypeKind(typeDef.kind)
    local primitiveBytes = PRIMITIVE_BYTES[kind]
    if primitiveBytes ~= nil then
        return primitiveBytes
    end
    if kind == "bool" then
        return 1
    end
    return nil
end

-- Recursively compute the exact serialized byte size of a type.
-- Returns the fixed byte count, or nil if the type is variable-length.
-- Handles primitives, bool, structs (all fields fixed), and
-- fixedarray (with compile-time count and fixed-size element type, including
-- packed-bool sizing). Returns nil for string, array, map, optional, etc.
local function computeFixedByteSize(
    typeDef: Ast.Type,
    structByName: { [string]: Ast.Struct },
    seenStructs: { [string]: boolean }
): number?
    local kind = normalizeTypeKind(typeDef.kind)
    local primitiveBytes = PRIMITIVE_BYTES[kind]
    if primitiveBytes ~= nil then
        return primitiveBytes
    end
    if kind == "bool" then
        return 1
    end
    -- Variable-length types: always nil
    if kind == "string" or kind == "array" or kind == "map" or kind == "optional" then
        return nil
    end
    -- FixedArray: fixed only when element type has a known fixed size
    if kind == "fixedarray" then
        local fixedLength = typeDef.max
        if fixedLength == nil or fixedLength < 0 then
            return nil
        end
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            return nil
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        if valueKind == "bool" then
            -- Packed booleans: ceil(N / 8)
            return ((fixedLength + 7) // 8) :: number
        end
        local elemSize = computeFixedByteSize(valueType, structByName, seenStructs)
        if elemSize == nil then
            return nil
        end
        return (fixedLength * elemSize) :: number
    end
    -- Struct: fixed only when every field has a known fixed size
    local structDecl = structByName[kind]
    if structDecl ~= nil then
        if seenStructs[kind] then
            return nil
        end
        seenStructs[kind] = true
        local total = 0
        for fieldIndex = 1, #structDecl.fields do
            local fieldSize = computeFixedByteSize(structDecl.fields[fieldIndex].type, structByName, seenStructs)
            if fieldSize == nil then
                seenStructs[kind] = nil
                return nil
            end
            total += fieldSize
        end
        seenStructs[kind] = nil
        return total
    end
    return nil
end

local function fixedTypeHasUnpackedBoolTag(
    typeDef: Ast.Type,
    structByName: { [string]: Ast.Struct },
    seenStructs: { [string]: boolean }
): boolean
    local kind = normalizeTypeKind(typeDef.kind)
    if kind == "bool" then
        return true
    end
    if PRIMITIVE_BYTES[kind] ~= nil then
        return false
    end
    if kind == "fixedarray" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            return false
        end
        -- Packed bool fixedarrays do not carry per-element boolean tags.
        if normalizeTypeKind(valueType.kind) == "bool" then
            return false
        end
        return fixedTypeHasUnpackedBoolTag(valueType, structByName, seenStructs)
    end
    local structDecl = structByName[kind]
    if structDecl ~= nil then
        if seenStructs[kind] then
            return false
        end
        seenStructs[kind] = true
        for fieldIndex = 1, #structDecl.fields do
            if fixedTypeHasUnpackedBoolTag(structDecl.fields[fieldIndex].type, structByName, seenStructs) then
                seenStructs[kind] = nil
                return true
            end
        end
        seenStructs[kind] = nil
    end
    return false
end

local function canSingleAdvanceSkipForFixedType(
    typeDef: Ast.Type,
    validateLevel: Analyzer.ValidateLevel,
    structByName: { [string]: Ast.Struct }
): number?
    local seenStructs: { [string]: boolean } = {}
    local fixedSize = computeFixedByteSize(typeDef, structByName, seenStructs)
    if fixedSize == nil then
        return nil
    end
    if isValidateBasicOrFull(validateLevel) then
        local seenTagStructs: { [string]: boolean } = {}
        if fixedTypeHasUnpackedBoolTag(typeDef, structByName, seenTagStructs) then
            return nil
        end
    end
    return fixedSize
end

local function offsetExpr(baseExpr: string, offset: number): string
    if offset == 0 then
        return baseExpr
    end
    return ("%s + %d"):format(baseExpr, offset)
end


local function typeHasVariableLength(
    typeDef: Ast.Type,
    structByName: { [string]: Ast.Struct },
    seenStructs: { [string]: boolean }
): boolean
    local kind = normalizeTypeKind(typeDef.kind)
    if kind == "string" or kind == "array" or kind == "map" or kind == "optional" then
        return true
    end
    -- FixedArray: variable only if element type is variable-length
    if kind == "fixedarray" then
        local fixedSize = computeFixedByteSize(typeDef, structByName, seenStructs)
        return fixedSize == nil
    end
    if PRIMITIVE_BYTES[kind] ~= nil or kind == "bool" then
        return false
    end
    local structDecl = structByName[kind]
    if structDecl ~= nil then
        if seenStructs[kind] then
            return false
        end
        seenStructs[kind] = true
        for fieldIndex = 1, #structDecl.fields do
            if typeHasVariableLength(structDecl.fields[fieldIndex].type, structByName, seenStructs) then
                seenStructs[kind] = nil
                return true
            end
        end
        seenStructs[kind] = nil
        return false
    end
    return false
end

local function paramsHaveVariableLength(params: { Ast.Param }, structByName: { [string]: Ast.Struct }): boolean
    local seenStructs: { [string]: boolean } = {}
    for index = 1, #params do
        if typeHasVariableLength(params[index].type, structByName, seenStructs) then
            return true
        end
    end
    return false
end

local function fixedBytesForCanonicalType(
    typeDef: Ast.Type,
    structByName: { [string]: Ast.Struct },
    seenStructs: { [string]: boolean }
): number
    local kind = normalizeTypeKind(typeDef.kind)
    local primitiveBytes = PRIMITIVE_BYTES[kind]
    if primitiveBytes ~= nil then
        return primitiveBytes
    end
    if kind == "bool" then
        return 1
    end
    if kind == "string" or kind == "array" or kind == "map" or kind == "optional" then
        return 0
    end
    -- FixedArray with fixed-size elements: compute total serialized size
    if kind == "fixedarray" then
        local fixedSize = computeFixedByteSize(typeDef, structByName, seenStructs)
        return if fixedSize ~= nil then fixedSize else 0
    end
    local structDecl = structByName[kind]
    if structDecl ~= nil then
        if seenStructs[kind] then
            return 0
        end
        seenStructs[kind] = true
        local total = 0
        for fieldIndex = 1, #structDecl.fields do
            total += fixedBytesForCanonicalType(structDecl.fields[fieldIndex].type, structByName, seenStructs)
        end
        seenStructs[kind] = nil
        return total
    end
    return 0
end

local function fixedBytesForCanonicalParams(params: { Ast.Param }, structByName: { [string]: Ast.Struct }): number
    local seenStructs: { [string]: boolean } = {}
    local total = 0
    for index = 1, #params do
        total += fixedBytesForCanonicalType(params[index].type, structByName, seenStructs)
    end
    return total
end


local function consumeDecodeVarMeta(metas: { DecodeVarMeta }, cursor: DecodeVarCursor, expectedKind: string): DecodeVarMeta
    local meta = metas[cursor.index]
    if meta == nil or meta.kind ~= expectedKind then
        error(("Internal canonical decode metadata mismatch (expected %s)"):format(expectedKind))
    end
    cursor.index += 1
    return meta
end

return {
    widthForBound = widthForBound,
    getStringLengthPrefixInfo = getStringLengthPrefixInfo,
    getArrayLengthPrefixInfo = getArrayLengthPrefixInfo,
    getFixedArrayLength = getFixedArrayLength,
    getMapLengthPrefixInfo = getMapLengthPrefixInfo,
    getMessageIdWidthInfo = getMessageIdWidthInfo,
    isValidateFull = isValidateFull,
    isValidateBasicOrFull = isValidateBasicOrFull,
    emitError = emitError,
    indent = indent,
    concat = concat,
    appendLines = appendLines,
    join = join,
    sanitizeIdentifier = sanitizeIdentifier,
    addLine = addLine,
    nextTemp = nextTemp,
    splitParams = splitParams,
    getPassthroughTypeName = getPassthroughTypeName,
    normalizeTypeKind = normalizeTypeKind,
    isNumericKind = isNumericKind,
    getStringBoundComment = getStringBoundComment,
    resolveTypeBranding = resolveTypeBranding,
    resolveDecodeStruct = resolveDecodeStruct,
    toLuauType = toLuauType,
    typedParamList = typedParamList,
    returnTypeExpr = returnTypeExpr,
    tupleTypeExpr = tupleTypeExpr,
    callbackTypeExpr = callbackTypeExpr,
    callbackSignatureTypeExpr = callbackSignatureTypeExpr,
    callableTypeExpr = callableTypeExpr,
    messageClientCallbackTypeName = messageClientCallbackTypeName,
    messageServerCallbackTypeName = messageServerCallbackTypeName,
    messageClientApiTypeName = messageClientApiTypeName,
    messageServerApiTypeName = messageServerApiTypeName,
    collectMessages = collectMessages,
    buildScopeTables = buildScopeTables,
    paramNames = paramNames,
    luauTypeFieldKey = luauTypeFieldKey,
    fieldAccessExpr = fieldAccessExpr,
    expandDecodeParams = expandDecodeParams,
    buildDecodedParamPlans = buildDecodedParamPlans,
    collectDecodedLeafNames = collectDecodedLeafNames,
    canSendEvent = canSendEvent,
    canReceiveEvent = canReceiveEvent,
    cacheCollectionHint = cacheCollectionHint,
    getCollectionHint = getCollectionHint,
    fixedBytesForType = fixedBytesForType,
    computeFixedByteSize = computeFixedByteSize,
    canSingleAdvanceSkipForFixedType = canSingleAdvanceSkipForFixedType,
    offsetExpr = offsetExpr,
    typeHasVariableLength = typeHasVariableLength,
    paramsHaveVariableLength = paramsHaveVariableLength,
    fixedBytesForCanonicalType = fixedBytesForCanonicalType,
    fixedBytesForCanonicalParams = fixedBytesForCanonicalParams,
    consumeDecodeVarMeta = consumeDecodeVarMeta,
}
