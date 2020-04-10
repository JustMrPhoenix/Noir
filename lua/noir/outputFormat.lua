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
    if val == nil then
        return "nil"
    elseif istable( val ) then
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
        elseif isentity(val) then
            if val == game.GetWorld() then
                return fmt("game.GetWorld()")
            elseif not IsValid(val) then
                return fmt("NULL"), "INVALID"
            elseif val:IsPlayer() then
                return fmt("player.GetByID(%i)", val:EntIndex()), fmt("%s : %s",val:SteamID(), val:Nick())
            else
                return fmt("Entity(%i)", val:EntIndex()), fmt("%s : %s", val:GetClass(), val:GetModel())
            end
        else
            return tostring( val )
        end
    end
end

function Format.FormatLong( val, level, doFull, doneTbls )
    level = level or 0
    doneTbls = doneTbls or {}
    if isstring(val) then
        if string.find(val, "\n") then
            val = string.Replace(val, "\\", "\\\\")
            val = string.Replace(val, "]", "\\]")
            return fmt("[[%s]]", val)
        else
            return Format.FormatShort(val)
        end
    elseif isbool(val) or isnumber(val) then
        return Format.FormatShort(val)
    elseif val == nil or (  not istable(val) and not IsValid(val) ) then
        return Format.FormatShort( val )
    elseif isentity(val) then
        if val:IsPlayer() then
            return fmt("-- %s : %s\n-- %s\n-- %s\n-- http://steamcommunity.com/profiles/%s \n%s", Format.FormatShort(val), val:Nick(), val:SteamID(), val:GetModel(), val:SteamID64(), Format.FormatLong( val:GetTable(), level, doFull, doneTbls))
        else
            return fmt("-- %s\n-- %s\n-- %s\n%s", Format.FormatShort(val), val:GetClass(), val:GetModel(), Format.FormatLong( val:GetTable(), level, doFull, doneTbls))
        end
    elseif val and not istable(val) and isfunction(val.GetTable) then
        return fmt("-- %s\n%s", Format.FormatShort(val), Format.FormatLong( val:GetTable(), level, doFull, doneTbls))
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
            local str, cmt
            if ( doFull or (level == 0 and istable(v) and table.Count(v) < 6) ) and not doneTbls[v] then
                doneTbls[v] = true
                str = Format.FormatLong(v, level + 1, doFull, doneTbls)
            else
                str, cmt = Format.FormatShort(v)
            end
            if cmt then
                cmt = fmt(" --[[ %s ]]", cmt)
            end
            result = fmt("%s\n%s%s,%s", result, string.rep(" ", (level + 1) * 4), str, cmt or "")
        else
            if not isstring(k) then
                k = fmt("[%s]", Format.FormatShort(k))
            elseif not Noir.Utils.IsSafeKey(k) then
                k = fmt("[\"%s\"]", string.Replace(k, "\"", "\\\""))
            end
            local str, cmt
            if ( doFull or (level == 0 and istable(v) and table.Count(v) < 6) ) and not doneTbls[v] then
                doneTbls[v] = true
                str = Format.FormatLong(v, level + 1, doFull, doneTbls)
            else
                str, cmt = Format.FormatShort(v)
            end
            if cmt then
                cmt = fmt(" --[[ %s ]]", cmt)
            end
            result = fmt("%s\n%s%s = %s,%s", result, string.rep(" ", (level + 1) * 4), k, str, cmt or "")
        end
    end
    result = result .. "\n" .. string.rep(" ", level * 4) .. "}"
    return result
end

function Format.FormatMessage(message, messageData, displayFull)
    if message == "run" then
        if messageData[1] ~= true then
            return util.TableToJSON({false, messageData[2]})
        else
            return util.TableToJSON({true, Format.FormatMessage("return",messageData[2], displayFull)})
        end
    end
    Noir.Debug("FormatMessage", messageData)
    if messageData.args then
        messageData = messageData.args
    end
    local text = ""
    if #messageData == 1 then
        text = Format.FormatLong(messageData[1], 0, displayFull)
    else
        local lines = {}
        for k, v in pairs(messageData) do
            v = Format.FormatLong(v, 0, displayFull)
            if string.find(v, "\n") then
                v = "\n" .. v
            end
            table.insert(lines, fmt("-- %s : %s", k, v))
        end
        text = table.concat(lines, "\n")
    end
    return text == "" and "nil" or text
end