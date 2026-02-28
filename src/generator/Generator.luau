--!strict
-- Name: Generator
-- Purpose: Generator orchestrator

local Analyzer = require("../idl/Analyzer")
local Runtime = require("./Runtime")
local EmitTypes = require("./EmitTypes")

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
