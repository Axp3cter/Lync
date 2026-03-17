--!strict
--!optimize 2
-- Test entry point. Auto-discovers all .test modules recursively.

local Runner = require (script.Runner)

local function collect (parent: Instance): ()
    local children = parent:GetChildren ()
    table.sort (children, function (a: Instance, b: Instance): boolean
        return a.Name < b.Name
    end)

    for _, child in children do
        if child:IsA ("ModuleScript") and string.match (child.Name, "%.test$") then
            require (child)
        elseif child:IsA ("Folder") then
            collect (child)
        end
    end
end

collect (script)

local isSuccess = Runner.run ()

if not isSuccess then
    error ("[Lync] Tests failed, see output above")
end

return isSuccess
