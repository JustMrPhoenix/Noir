local Format = Noir.Format or {}
Noir.Format = Format
local fmt = _G.Format

local stringEscape = {
    ["\\"] = "\\\\",
    ["\0"] = "\\x00" ,
    ["\b"] = "\\b" ,
    ["\t"] = "\\t" ,
    ["\n"] = "\\n" ,
    ["\v"] = "\\v" ,
    ["\f"] = "\\f" ,
    ["\r"] = "\\r" ,
    ["\""] = "\\\"",
    -- ["\'"] = "\\\'"
}

function Format.FormatShort( val )
    if istable( val ) then
        if IsColor( val ) then
            return fmt("Color(%i,%i,%i,%i)", val.r, val.g, val.b, val.a)
        else
            return fmt("{ %s#%i }", val, table.Count(val))
        end
    else
        if isstring( val ) then
            return fmt("\"%s\"", val:gsub( ".", stringEscape ))
        elseif isvector( val ) then
            return fmt("Vector(%i,%i,%i)", val.x, val.y, val.z)
        elseif isangle( val ) then
            return fmt("Angle(%i,%i,%i)", val.pitch, val.yaw, val.roll)
        elseif isfunction( val ) then
            return tostring( val )
        else
            return tostring( val )
        end
    end
end

function Format.FormatLong( val, level )
    level = level or 0
    if isstring(val) then
        return fmt("[[%s]]", string.Replace(val, "]", "\\]"))
    elseif not istable( val ) or IsColor( val ) then
        return Format.FormatShort( val )
    end
    local total = table.Count(val)
    if total == 0 then return "{ }" end
    local sequential = table.IsSequential( val )
    local result = "{"
    local done = 0
    for k, v in pairs( val ) do
        done = done + 1
        if done > 100 then
            result = fmt("%s\n%s-- %s more...", result, string.rep(" ", (level + 1) * 4), total - done)
            break;
        end
        if sequential then
            local str
            if level == 0 and istable(v) and table.Count(v) < 6 then
                str = Format.FormatLong(v, 1)
            else
                str = Format.FormatShort(v)
            end
            result = fmt("%s\n%s%s,", result, string.rep(" ", (level + 1) * 4), str)
        else
            if not isstring(k) then
                k = fmt("[%s]", Format.FormatShort(k))
            elseif not Noir.Utils.IsSafeKey(k) then
                k = fmt("[\"%s\"]", string.Replace(k, "\"", "\\\""))
            end
            local str
            if level == 0 and istable(v) and table.Count(v) < 6 then
                str = Format.FormatLong(v, 1)
            else
                str = Format.FormatShort(v)
            end
            result = fmt("%s\n%s%s = %s,", result, string.rep(" ", (level + 1) * 4), k, str)
        end
    end
    result = result .. "\n" .. string.rep(" ", level * 4) .. "}"
    return result
end

function Format.FormatMessage(message, messageData)
    if message == "run" then
        if messageData[1] ~= true then
            return util.TableToJSON({false, messageData[2]})
        else
            return util.TableToJSON({true, Format.FormatMessage("return",messageData[2])})
        end
    end
    if messageData.args then
        messageData = messageData.args
    end
    local text = ""
    if #messageData == 1 then
        text = Format.FormatLong(messageData[1])
    else
        local lines = {}
        for k, v in pairs(messageData) do
            v = Format.FormatLong(v)
            if string.find(v, "\n") then
                v = "\n" .. v
            end
            table.insert(lines, fmt("-- %s : %s", k, v))
        end
        text = table.concat(lines, "\n")
    end
    return text == "" and "nil" or text
end