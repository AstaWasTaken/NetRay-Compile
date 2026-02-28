--!strict
-- Name: Generator
-- Purpose: Generator orchestrator

local Analyzer = require(script.Parent.Parent.idl.Analyzer)
local Runtime = require(script.Parent.Runtime)
local EmitTypes = require(script.Parent.EmitTypes)

local function generate(schema: Analyzer.AnalyzedSchema)
    return {
        server = Runtime.generateServer(schema),
        client = Runtime.generateClient(schema),
        types = EmitTypes.generateTypes(schema),
    }
end

return {
    generate = generate,
}
