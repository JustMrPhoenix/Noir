local Autocomplete = Noir.Autocomplete or {}
Noir.Autocomplete = Autocomplete

function Autocomplete.GetValuesAndFuncs(tbl, name, scannedTbls, depth)
    scannedTbls = scannedTbls or {}
    depth = depth or 3
    local values, functions = {}, {}
    local tableScanQueue = {}

    for k, v in pairs(tbl) do
        -- nolint
        if not isstring(k) then continue end
        if k[1] == "_" then continue end
        if not Noir.Utils.IsSafeKey(k) then continue end
        local fullname = name and name .. "." .. k or k
        
        if string.Trim(k) == "" then
            continue
        end
        if isfunction(v) then
            table.insert(functions, fullname)
        elseif istable(v) then
            if scannedTbls[v] or depth == 0 then continue end
            scannedTbls[v] = true
            tableScanQueue[fullname] = v
        else
            table.insert(values, fullname)
        end
    end

    for fullname, tbl in pairs(tableScanQueue) do
        local vals, funcs = Autocomplete.GetValuesAndFuncs(tbl, fullname, scannedTbls, depth - 1)
        table.Add(values, vals)
        table.Add(functions, funcs)
    end

    return values, functions
end

function Autocomplete.GetAllClassfuncs()
    local classFucs = {}

    for k, v in pairs(debug.getregistry()) do
        if string.Trim(k) == "" then
            continue
        end
        -- Make sure its an actual object and not just some _LOADED stuff
        if isstring(k) and istable(v) and (v.MetaID or v.MetaName or v.__tostring) then
            for key, val in pairs(v) do
                if string.Trim(key) == "" then
                    continue
                end
                if isstring(key) and isfunction(val) and not key:StartWith("__") and Noir.Utils.IsSafeKey(key) then
                    table.insert(classFucs, k .. ":" .. key)
                end
            end
        end
    end

    return classFucs
end

function Autocomplete.GetJS(interfaceName)
    interfaceName = interfaceName or "gmodinterface"
    local values, funcs = Autocomplete.GetValuesAndFuncs(_G)
    table.Add(funcs, Autocomplete.GetAllClassfuncs())
    Noir.Debug(Format("Found %i values and %i functions for editor autocomplete", #values, #funcs))
    local js = Format([[%s.LoadAutocomplete({values: "%s", funcs: "%s"})]], interfaceName, table.concat(values, "|"), table.concat(funcs, "|"))

    return js .. "\nconsole.log('Client autocomplete loaded')"
end


function Autocomplete.GetJSWithState(state, interfaceName)
    interfaceName = interfaceName or "gmodinterface"
    return Format("%s.LoadAutocompleteState(\"%s\").then(() => {%s});", interfaceName, state, Autocomplete.GetJS(interfaceName))
end

concommand.Add("noir_reload_autocomplete", function()
    local values, funcs = Autocomplete.GetValuesAndFuncs(_G)
    table.Add(funcs, Autocomplete.GetAllClassfuncs())
    Noir.Debug(Format("Found %i values and %i functions for editor autocomplete", #values, #funcs))
    values, funcs = table.concat(values, "|"), table.concat(funcs, "|")
    if IsValid(Noir.Editor.Frame) and Noir.Editor.MonacoPanel.Ready then
        Noir.Editor.MonacoPanel:RunJS([[gmodinterface.LoadAutocomplete({values: "%s", funcs: "%s"})]], values, funcs)
    end

    if IsValid(Noir.ReplFrame) and Noir.ReplFrame.Repl.Ready then
        Noir.ReplFrame.Repl:RunJS([[replinterface.LoadAutocomplete({values: "%s", funcs: "%s"})]], values, funcs)
    end
end)