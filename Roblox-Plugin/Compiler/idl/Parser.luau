--!strict
-- Name: Parser
-- Purpose: Parse NetRay IDL tokens into an AST

local Ast = require(script.Parent.Ast)

export type Token = Ast.Token

local TYPE_ALIASES: { [string]: string } = {
    boolean = "bool",
    bool = "bool",
    u8 = "u8",
    i8 = "i8",
    u16 = "u16",
    i16 = "i16",
    u32 = "u32",
    i32 = "i32",
    f16 = "f16",
    f32 = "f32",
    f64 = "f64",
    string = "string",
    buffer = "buffer",
    vector = "vector",
    vector3 = "vector",
    cframe = "cframe",
    brickcolor = "brickcolor",
    color3 = "color3",
    datetime = "datetime",
    datetimemillis = "datetimemillis",
    instance = "instance",
    unknown = "unknown",
}

local NUMERIC_KINDS: { [string]: boolean } = {
    u8 = true,
    i8 = true,
    u16 = true,
    i16 = true,
    u32 = true,
    i32 = true,
    f16 = true,
    f32 = true,
    f64 = true,
}

local RELIABILITY_ALIASES: { [string]: string } = {
    reliable = "reliable",
    unreliable = "unreliable",
}

local EVENT_FROM_ALIASES: { [string]: string } = {
    client = "client",
    server = "server",
    both = "both",
}

local EVENT_CALL_ALIASES: { [string]: string } = {
    singlesync = "SingleSync",
    manysync = "ManySync",
    singleasync = "SingleAsync",
    manyasync = "ManyAsync",
    polling = "Polling",
}

local function parse(tokens: { Token }): Ast.Schema
    local index = 1

    local function peek(offset: number?): Token?
        return tokens[index + (offset or 0)]
    end

    local function fail(message: string, token: Token?)
        if token then
            error(("%s at %d:%d"):format(message, token.line, token.column))
        end
        error(message .. " at <eof>")
    end

    local function expect(kind: string, value: string?): Token
        local token = tokens[index]
        if not token or token.kind ~= kind or (value ~= nil and token.value ~= value) then
            fail("Unexpected token", token)
        end
        index += 1
        return token
    end

    local function accept(kind: string, value: string?): Token?
        local token = tokens[index]
        if token and token.kind == kind and (value == nil or token.value == value) then
            index += 1
            return token
        end
        return nil
    end

    local function expectIdentifierLike(): string
        local token = peek()
        if token and (token.kind == "identifier" or token.kind == "keyword") then
            index += 1
            return token.value
        end
        fail("Expected identifier", token)
        return ""
    end

    local function expectNumber(): number
        local token = expect("number", nil)
        local parsed = tonumber(token.value)
        if parsed == nil then
            fail("Expected numeric literal", token)
        end
        return parsed :: number
    end

    local function parseOptionValue(): string
        local token = tokens[index]
        if not token then
            fail("Unexpected end of tokens while parsing option value", token)
        end

        if token.kind == "string" or token.kind == "identifier" or token.kind == "keyword" or token.kind == "number" then
            index += 1
            return token.value
        end

        fail(("Unexpected option value token '%s'"):format(token.kind), token)
        return ""
    end

    local function normalizeTypeName(name: string): string
        local alias = TYPE_ALIASES[string.lower(name)]
        if alias ~= nil then
            return alias
        end
        return name
    end

    local function normalizeReliability(name: string): string
        local alias = RELIABILITY_ALIASES[string.lower(name)]
        if alias ~= nil then
            return alias
        end
        error("E_EVENT_TYPE")
    end

    local function normalizeEventFrom(name: string): string
        local alias = EVENT_FROM_ALIASES[string.lower(name)]
        if alias ~= nil then
            return alias
        end
        error("E_EVENT_FROM")
    end

    local function normalizeEventCall(name: string): string
        local alias = EVENT_CALL_ALIASES[string.lower(name)]
        if alias ~= nil then
            return alias
        end
        error("E_EVENT_CALL")
    end

    local function acceptRangeDots(): boolean
        local first = peek()
        local second = peek(1)
        if first and second and first.kind == "symbol" and second.kind == "symbol" and first.value == "." and second.value == "." then
            index += 2
            return true
        end
        return false
    end

    local function parseBoundsInParens(): (number?, number?)
        expect("symbol", "(")
        local minBound: number? = nil
        local maxBound: number? = nil
        if acceptRangeDots() then
            maxBound = expectNumber()
        else
            local first = expectNumber()
            if acceptRangeDots() then
                minBound = first
                local nextToken = peek()
                if nextToken and nextToken.kind == "number" then
                    maxBound = expectNumber()
                end
            elseif accept("symbol", ",") then
                minBound = first
                maxBound = expectNumber()
            else
                minBound = first
                maxBound = first
            end
        end
        expect("symbol", ")")
        return minBound, maxBound
    end

    local function parseBoundsInBrackets(): (boolean, number?, number?)
        local minBound: number? = nil
        local maxBound: number? = nil
        local fixed = false
        if acceptRangeDots() then
            maxBound = expectNumber()
        else
            local first = expectNumber()
            if acceptRangeDots() then
                minBound = first
                local nextToken = peek()
                if nextToken and nextToken.kind == "number" then
                    maxBound = expectNumber()
                end
            else
                minBound = first
                maxBound = first
                fixed = true
            end
        end
        expect("symbol", "]")
        return fixed, minBound, maxBound
    end

    local parseType: () -> Ast.Type
    local parseStructFields: () -> { Ast.Param }
    local parseEnumValues: () -> { string }

    function parseStructFields(): { Ast.Param }
        local fields: { Ast.Param } = {}
        while not accept("symbol", "}") do
            local first = peek()
            local second = peek(1)
            if not first then
                fail("Unexpected end while parsing struct", first)
            end

            local fieldName: string
            local fieldType: Ast.Type

            if second and second.kind == "symbol" and second.value == ":" and (first.kind == "identifier" or first.kind == "keyword") then
                fieldName = expectIdentifierLike()
                expect("symbol", ":")
                fieldType = parseType()
            else
                fieldType = parseType()
                fieldName = expectIdentifierLike()
            end

            fields[#fields + 1] = { name = fieldName, type = fieldType }
            if not accept("symbol", ",") then
                accept("symbol", ";")
            end
        end
        return fields
    end

    function parseEnumValues(): { string }
        local values: { string } = {}
        if not accept("symbol", "}") then
            while true do
                values[#values + 1] = expectIdentifierLike()
                if accept("symbol", "}") then
                    break
                end
                expect("symbol", ",")
                if accept("symbol", "}") then
                    break
                end
            end
        end
        return values
    end

    local function parsePrimaryType(): Ast.Type
        local token = peek()
        if not token then
            fail("Unexpected end of tokens", token)
        end

        if token.kind == "keyword" and token.value == "optional" then
            expect("keyword", "optional")
            return { kind = "optional", value = parseType() }
        end

        if token.kind == "keyword" and token.value == "array" then
            expect("keyword", "array")
            expect("symbol", "<")
            local element = parseType()
            local max: number? = nil
            if accept("symbol", ",") then
                max = expectNumber()
            end
            expect("symbol", ">")
            return { kind = "array", value = element, max = max }
        end

        if token.kind == "keyword" and token.value == "fixedarray" then
            expect("keyword", "fixedarray")
            expect("symbol", "<")
            local element = parseType()
            expect("symbol", ",")
            local fixedLength = expectNumber()
            expect("symbol", ">")
            return { kind = "fixedarray", value = element, min = fixedLength, max = fixedLength }
        end

        if token.kind == "keyword" and token.value == "map" then
            expect("keyword", "map")
            expect("symbol", "<")
            local keyType = parseType()
            expect("symbol", ",")
            local valueType = parseType()
            local max: number? = nil
            if accept("symbol", ",") then
                max = expectNumber()
            end
            expect("symbol", ">")
            return { kind = "map", key = keyType, value = valueType, max = max }
        end

        if token.kind == "keyword" and token.value == "passthrough" then
            expect("keyword", "passthrough")
            local nextToken = peek()
            if nextToken and (nextToken.kind == "identifier" or nextToken.kind == "keyword") then
                local passType = expectIdentifierLike()
                return { kind = "passthrough", value = passType }
            end
            return { kind = "passthrough", value = "any" }
        end

        local nextToken = peek(1)
        if token.kind == "keyword" and token.value == "struct" and nextToken and nextToken.kind == "symbol" and nextToken.value == "{" then
            expect("keyword", "struct")
            expect("symbol", "{")
            local fields = parseStructFields()
            return { kind = "inline_struct", fields = fields }
        end

        nextToken = peek(1)
        if token.kind == "keyword" and token.value == "enum" and nextToken and nextToken.kind == "symbol" and nextToken.value == "{" then
            expect("keyword", "enum")
            expect("symbol", "{")
            local values = parseEnumValues()
            return { kind = "enum_inline", values = values }
        end

        if token.kind == "symbol" and token.value == "{" then
            expect("symbol", "{")
            expect("symbol", "[")
            local keyType = parseType()
            expect("symbol", "]")
            expect("symbol", ":")
            local valueType = parseType()
            expect("symbol", "}")
            return { kind = "map", key = keyType, value = valueType }
        end

        if token.kind == "identifier" or token.kind == "keyword" then
            local name = normalizeTypeName(expectIdentifierLike())

            if name == "string" or name == "buffer" then
                local minBound: number? = nil
                local maxBound: number? = nil
                if accept("symbol", "<") then
                    maxBound = expectNumber()
                    expect("symbol", ">")
                else
                    local openToken = peek()
                    if openToken and openToken.kind == "symbol" and openToken.value == "(" then
                        minBound, maxBound = parseBoundsInParens()
                    end
                end
                return {
                    kind = name,
                    min = minBound,
                    max = maxBound,
                }
            end

            if name == "unknown" then
                return { kind = "passthrough", value = "any" }
            end

            if name == "instance" then
                if accept("symbol", "(") then
                    local className = expectIdentifierLike()
                    expect("symbol", ")")
                    return { kind = "passthrough", value = className }
                end
                return { kind = "passthrough", value = "Instance" }
            end

            if name == "vector" then
                local componentType: Ast.Type? = nil
                if accept("symbol", "<") then
                    componentType = parseType()
                    expect("symbol", ">")
                end
                local minBound: number? = nil
                local maxBound: number? = nil
                local openToken = peek()
                if openToken and openToken.kind == "symbol" and openToken.value == "(" then
                    minBound, maxBound = parseBoundsInParens()
                end
                return {
                    kind = "vector",
                    value = componentType,
                    min = minBound,
                    max = maxBound,
                }
            end

            if name == "cframe" then
                local posType: Ast.Type? = nil
                local rotType: Ast.Type? = nil
                if accept("symbol", "<") then
                    posType = parseType()
                    if accept("symbol", ",") then
                        rotType = parseType()
                    else
                        rotType = posType
                    end
                    expect("symbol", ">")
                end
                return {
                    kind = "cframe",
                    value = posType,
                    key = rotType,
                }
            end

            if NUMERIC_KINDS[name] then
                local minBound: number? = nil
                local maxBound: number? = nil
                local openToken = peek()
                if openToken and openToken.kind == "symbol" and openToken.value == "(" then
                    minBound, maxBound = parseBoundsInParens()
                end
                return {
                    kind = name,
                    min = minBound,
                    max = maxBound,
                }
            end

            return { kind = name }
        end

        fail("Unexpected type token", token)
        return { kind = "invalid" }
    end

    function parseType(): Ast.Type
        local typeDef = parsePrimaryType()
        while true do
            if accept("symbol", "?") then
                typeDef = { kind = "optional", value = typeDef }
            elseif accept("symbol", "[") then
                if accept("symbol", "]") then
                    typeDef = { kind = "array", value = typeDef }
                else
                    local fixed, minBound, maxBound = parseBoundsInBrackets()
                    if fixed then
                        typeDef = {
                            kind = "fixedarray",
                            value = typeDef,
                            min = minBound,
                            max = maxBound,
                        }
                    else
                        typeDef = {
                            kind = "array",
                            value = typeDef,
                            min = minBound,
                            max = maxBound,
                        }
                    end
                end
            else
                break
            end
        end
        return typeDef
    end

    local function parseLegacyParams(): { Ast.Param }
        local params: { Ast.Param } = {}
        expect("symbol", "(")
        if not accept("symbol", ")") then
            local paramIndex = 1
            while true do
                local paramType = parseType()
                local name = expectIdentifierLike()
                params[paramIndex] = { name = name, type = paramType }
                paramIndex += 1

                if accept("symbol", ")") then
                    break
                end
                expect("symbol", ",")
                if accept("symbol", ")") then
                    break
                end
            end
        end
        return params
    end

    local function parseDataParams(singleName: string, tuplePrefix: string): { Ast.Param }
        local params: { Ast.Param } = {}
        if accept("symbol", "(") then
            if not accept("symbol", ")") then
                local tupleIndex = 1
                while true do
                    params[#params + 1] = {
                        name = tuplePrefix .. tostring(tupleIndex),
                        type = parseType(),
                    }
                    tupleIndex += 1

                    if accept("symbol", ")") then
                        break
                    end
                    expect("symbol", ",")
                    if accept("symbol", ")") then
                        break
                    end
                end
            end
            return params
        end

        params[1] = {
            name = singleName,
            type = parseType(),
        }
        return params
    end

    local function consumeOptionalSeparator()
        if accept("symbol", ",") then
            return
        end
        accept("symbol", ";")
    end

    local function parseStruct(name: string): Ast.Struct
        expect("symbol", "{")
        local fields = parseStructFields()
        return { name = name, fields = fields }
    end

    local function enumBodyHasTaggedVariants(): boolean
        local cursor = index
        local depth = 0
        while true do
            local token = tokens[cursor]
            if token == nil then
                fail("Unexpected end while parsing enum", token)
            end

            if depth == 0 and token.kind == "symbol" and token.value == "}" then
                return false
            end

            if depth == 0 and (token.kind == "identifier" or token.kind == "keyword") then
                local nextToken = tokens[cursor + 1]
                if nextToken and nextToken.kind == "symbol" and nextToken.value == "{" then
                    return true
                end
            end

            if token.kind == "symbol" then
                if token.value == "{" then
                    depth += 1
                elseif token.value == "}" then
                    depth -= 1
                end
            end

            cursor += 1
        end
    end

    local function parseEnum(name: string): Ast.Enum
        local tagField: string? = nil
        if accept("symbol", "=") then
            local tagToken = peek()
            if not tagToken then
                fail("Expected enum assignment value", tagToken)
            end
            if tagToken.kind == "symbol" and tagToken.value == "{" then
                -- unit enum assignment style: enum Name = { A, B }
            elseif tagToken.kind == "string" then
                tagField = expect("string", nil).value
            elseif tagToken.kind == "identifier" or tagToken.kind == "keyword" then
                tagField = expectIdentifierLike()
            else
                fail("Expected enum assignment value", tagToken)
            end
        end

        expect("symbol", "{")
        local parseAsTaggedEnum = tagField ~= nil or enumBodyHasTaggedVariants()
        if not parseAsTaggedEnum then
            local values = parseEnumValues()
            return {
                declKind = "enum",
                name = name,
                values = values,
            }
        end

        local variants: { any } = {}
        if not accept("symbol", "}") then
            while true do
                local variantName = expectIdentifierLike()
                local fields: { Ast.Param } = {}
                if accept("symbol", "{") then
                    fields = parseStructFields()
                end
                variants[#variants + 1] = {
                    name = variantName,
                    fields = fields,
                }
                if accept("symbol", "}") then
                    break
                end
                expect("symbol", ",")
                if accept("symbol", "}") then
                    break
                end
            end
        end

        return {
            declKind = "enum",
            name = name,
            tag = tagField,
            variants = variants,
        }
    end

    local function parseSet(name: string): Ast.Set
        if accept("symbol", "=") then
            -- optional assignment style: set Name = { ... }
        end
        expect("symbol", "{")
        local values: { string } = {}
        if not accept("symbol", "}") then
            while true do
                values[#values + 1] = expectIdentifierLike()
                if accept("symbol", "}") then
                    break
                end
                expect("symbol", ",")
                if accept("symbol", "}") then
                    break
                end
            end
        end
        return {
            declKind = "set",
            name = name,
            values = values,
        }
    end

    local function parseBlinkEvent(name: string, defaultReliability: string): Ast.Event
        local direction = "both"
        local reliability = defaultReliability
        local callMode = "ManySync"
        local params: { Ast.Param } = {}

        expect("symbol", "{")
        while not accept("symbol", "}") do
            local key = string.lower(expectIdentifierLike())
            expect("symbol", ":")
            if key == "from" then
                direction = normalizeEventFrom(expectIdentifierLike())
            elseif key == "type" then
                reliability = normalizeReliability(expectIdentifierLike())
            elseif key == "call" then
                callMode = normalizeEventCall(expectIdentifierLike())
            elseif key == "data" then
                params = parseDataParams("data", "v")
            else
                error("E_EVENT_KEY")
            end
            consumeOptionalSeparator()
        end

        return {
            name = name,
            params = params,
            reliability = reliability,
            from = direction,
            call = callMode,
        }
    end

    local function parseEvent(): Ast.Event
        expect("keyword", "event")

        local reliability = "reliable"
        local reliabilityToken = peek()
        if reliabilityToken and reliabilityToken.kind == "keyword" then
            local lowered = string.lower(reliabilityToken.value)
            if lowered == "reliable" or lowered == "unreliable" then
                reliability = normalizeReliability(expect("keyword", nil).value)
            end
        end

        local name = expect("identifier", nil).value
        local bodyToken = peek()
        if bodyToken and bodyToken.kind == "symbol" and bodyToken.value == "(" then
            local params = parseLegacyParams()
            expect("symbol", ";")
            return {
                name = name,
                params = params,
                reliability = reliability,
                from = "both",
                call = "ManySync",
            }
        end

        if bodyToken and bodyToken.kind == "symbol" and bodyToken.value == "{" then
            local decl = parseBlinkEvent(name, reliability)
            accept("symbol", ";")
            return decl
        end

        fail("Expected event parameter list or event block", bodyToken)
        return {
            name = name,
            params = {},
            reliability = reliability,
            from = "both",
            call = "ManySync",
        }
    end

    local function parseBlinkFunction(name: string): Ast.Function
        local yieldMode = "SingleSync"
        local params: { Ast.Param } = {}
        local returns: { Ast.Param } = {}

        expect("symbol", "{")
        while not accept("symbol", "}") do
            local key = string.lower(expectIdentifierLike())
            expect("symbol", ":")
            if key == "yield" then
                local parsedYield = normalizeEventCall(expectIdentifierLike())
                if parsedYield ~= "SingleSync" then
                    error("E_UNSUPPORTED_YIELD")
                end
                yieldMode = parsedYield
            elseif key == "data" then
                params = parseDataParams("data", "v")
            elseif key == "return" then
                returns = parseDataParams("result", "r")
            else
                error("E_FUNCTION_KEY")
            end
            consumeOptionalSeparator()
        end

        return {
            name = name,
            params = params,
            returns = returns,
            yieldMode = yieldMode,
        }
    end

    local function parseFunction(): Ast.Function
        expect("keyword", "function")
        local name = expect("identifier", nil).value
        local bodyToken = peek()

        if bodyToken and bodyToken.kind == "symbol" and bodyToken.value == "(" then
            local params = parseLegacyParams()
            local returns: { Ast.Param } = {}
            if accept("symbol", "-") then
                expect("symbol", ">")
                returns = parseLegacyParams()
            end
            expect("symbol", ";")
            return {
                name = name,
                params = params,
                returns = returns,
            }
        end

        if bodyToken and bodyToken.kind == "symbol" and bodyToken.value == "{" then
            local decl = parseBlinkFunction(name)
            accept("symbol", ";")
            return decl
        end

        fail("Expected function parameter list or function block", bodyToken)
        return {
            name = name,
            params = {},
            returns = {},
        }
    end

    local parseScope: () -> Ast.Scope

    function parseScope(): Ast.Scope
        expect("keyword", "scope")
        local name = expect("identifier", nil).value
        expect("symbol", "{")

        local decls: { Ast.Decl } = {}
        while not accept("symbol", "}") do
            local token = peek()
            if not token then
                fail("Unexpected end of scope", token)
            end

            if token.kind == "keyword" and token.value == "event" then
                decls[#decls + 1] = parseEvent()
            elseif token.kind == "keyword" and token.value == "function" then
                decls[#decls + 1] = parseFunction()
            elseif token.kind == "keyword" and token.value == "struct" then
                expect("keyword", "struct")
                local structName = expect("identifier", nil).value
                decls[#decls + 1] = parseStruct(structName)
            elseif token.kind == "keyword" and token.value == "enum" then
                expect("keyword", "enum")
                local enumName = expect("identifier", nil).value
                decls[#decls + 1] = parseEnum(enumName)
            elseif token.kind == "keyword" and token.value == "set" then
                expect("keyword", "set")
                local setName = expect("identifier", nil).value
                decls[#decls + 1] = parseSet(setName)
            elseif token.kind == "keyword" and token.value == "scope" then
                decls[#decls + 1] = parseScope()
            else
                fail("Unexpected token in scope", token)
            end
        end

        return {
            name = name,
            declarations = decls,
        }
    end

    local options: { Ast.Option } = {}
    local decls: { Ast.Decl } = {}

    while index <= #tokens do
        local token = peek()
        if not token then
            break
        end

        if token.kind == "keyword" and token.value == "option" then
            expect("keyword", "option")
            local name = expect("identifier", nil).value
            expect("symbol", "=")
            local value = parseOptionValue()
            expect("symbol", ";")
            options[#options + 1] = { name = name, value = value }
        elseif token.kind == "keyword" and token.value == "scope" then
            decls[#decls + 1] = parseScope()
        elseif token.kind == "keyword" and token.value == "struct" then
            expect("keyword", "struct")
            local structName = expect("identifier", nil).value
            decls[#decls + 1] = parseStruct(structName)
        elseif token.kind == "keyword" and token.value == "enum" then
            expect("keyword", "enum")
            local enumName = expect("identifier", nil).value
            decls[#decls + 1] = parseEnum(enumName)
        elseif token.kind == "keyword" and token.value == "set" then
            expect("keyword", "set")
            local setName = expect("identifier", nil).value
            decls[#decls + 1] = parseSet(setName)
        elseif token.kind == "keyword" and token.value == "event" then
            decls[#decls + 1] = parseEvent()
        elseif token.kind == "keyword" and token.value == "function" then
            decls[#decls + 1] = parseFunction()
        else
            fail("Unexpected token", token)
        end
    end

    return {
        options = options,
        declarations = decls,
    }
end

return {
    parse = parse,
}
