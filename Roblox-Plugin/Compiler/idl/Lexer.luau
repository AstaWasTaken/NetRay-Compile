--!strict
-- Name: Lexer
-- Purpose: Tokenize NetRay IDL input

export type Token = {
    kind: string,
    value: string,
    line: number,
    column: number,
}

local KEYWORDS = {
    option = true,
    scope = true,
    struct = true,
    enum = true,
    set = true,
    event = true,
    ["function"] = true,
    optional = true,
    array = true,
    fixedarray = true,
    map = true,
    passthrough = true,
    unreliable = true,
    reliable = true,
}

local function isAlpha(char: string): boolean
    local byte = string.byte(char)
    return (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or char == "_"
end

local function isDigit(char: string): boolean
    local byte = string.byte(char)
    return byte >= 48 and byte <= 57
end

local function lex(text: string): { Token }
    local tokens: { Token } = {}
    local index = 1
    local line = 1
    local column = 1
    local length = #text

    local function addToken(kind: string, value: string, startColumn: number)
        tokens[#tokens + 1] = {
            kind = kind,
            value = value,
            line = line,
            column = startColumn,
        }
    end

    while index <= length do
        local char = string.sub(text, index, index)
        if char == "\n" then
            line += 1
            column = 1
            index += 1
        elseif char == " " or char == "\t" or char == "\r" then
            column += 1
            index += 1
        elseif char == "/" and string.sub(text, index + 1, index + 1) == "/" then
            while index <= length and string.sub(text, index, index) ~= "\n" do
                index += 1
            end
        elseif char == "-" and string.sub(text, index + 1, index + 1) == "-" then
            while index <= length and string.sub(text, index, index) ~= "\n" do
                index += 1
            end
        elseif char == "\"" then
            local startColumn = column
            local startIndex = index + 1
            index += 1
            column += 1
            while index <= length do
                local current = string.sub(text, index, index)
                if current == "\"" then
                    break
                end
                if current == "\n" then
                    error("Unterminated string literal")
                end
                index += 1
                column += 1
            end
            local value = string.sub(text, startIndex, index - 1)
            addToken("string", value, startColumn)
            index += 1
            column += 1
        elseif isAlpha(char) then
            local startColumn = column
            local startIndex = index
            index += 1
            column += 1
            while index <= length do
                local current = string.sub(text, index, index)
                if not isAlpha(current) and not isDigit(current) then
                    break
                end
                index += 1
                column += 1
            end
            local value = string.sub(text, startIndex, index - 1)
            if KEYWORDS[value] then
                addToken("keyword", value, startColumn)
            else
                addToken("identifier", value, startColumn)
            end
        elseif isDigit(char) then
            local startColumn = column
            local startIndex = index
            index += 1
            column += 1
            while index <= length and isDigit(string.sub(text, index, index)) do
                index += 1
                column += 1
            end
            local value = string.sub(text, startIndex, index - 1)
            addToken("number", value, startColumn)
        else
            local startColumn = column
            addToken("symbol", char, startColumn)
            index += 1
            column += 1
        end
    end

    return tokens
end

return {
    lex = lex,
}
