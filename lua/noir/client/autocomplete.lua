local Autocomplete = Noir.Autocomplete or {}
Noir.Autocomplete = Autocomplete
local badKeyChars = {"\"", "'", ".", "\\", "//", ":", "(", ")", "%", "-", "+", " ", "\n", "\t"}

function Autocomplete.IsSafeKey(key)
    for _, v in pairs(badKeyChars) do
        if string.find(key, v, 1, true) ~= nil then return false end
    end

    return tonumber(key[1]) == nil
end

function Autocomplete.GetValuesAndFuncs(tbl, name, scannedTbls, depth)
    scannedTbls = scannedTbls or {}
    depth = depth or 3
    local values, functions = {}, {}

    for k, v in pairs(tbl) do
        if not isstring(k) then continue end
        if k[1] == "_" then continue end
        if not Autocomplete.IsSafeKey(k) then continue end
        local fullname = name and name .. "." .. k or k

        if isfunction(v) then
            table.insert(functions, fullname)
        elseif istable(v) then
            if scannedTbls[v] or depth == 1 then continue end
            scannedTbls[v] = true
            local vals, funcs = Autocomplete.GetValuesAndFuncs(v, fullname, scannedTbls, depth - 1)
            table.Add(values, vals)
            table.Add(functions, funcs)
        else
            table.insert(values, fullname)
        end
    end

    return values, functions
end

function Autocomplete.GetAllClassfuncs()
    local classFucs = {}

    for k, v in pairs(debug.getregistry()) do
        -- Make sure its an actual object and not just some _LOADED stuff
        if isstring(k) and istable(v) and (v.MetaID or v.MetaName or v.__tostring) then
            for key, val in pairs(v) do
                if isstring(key) and isfunction(val) and not key:StartWith("__") and Autocomplete.IsSafeKey(key) then
                    table.insert(classFucs, k .. ":" .. key)
                end
            end
        end
    end

    return classFucs
end

function Autocomplete.GetJS()
    local values, funcs = Autocomplete.GetValuesAndFuncs(_G)
    table.Add(funcs, Autocomplete.GetAllClassfuncs())
    Noir.Debug(string.format("Found %i values and %i functions for editor autocomplete", #values, #funcs))
    local js = string.format([[gmodinterface.LoadAutocomplete({values: "%s", funcs: "%s"})]], table.concat(values, "|"), table.concat(funcs, "|"))

    return js .. "\nconsole.log('Client autocomplete loaded')"
end