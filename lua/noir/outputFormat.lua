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

local blacklistedTypes = {
    ["proto"] = true
}

function Format.FormatShort( val )
    local type = type(val)
    if blacklistedTypes[type] then return tostring(val) end
    if val == nil then
        return "nil"
    elseif type == "thread" then
        return tostring(val), coroutine.status(val)
    elseif istable( val ) then
        if IsColor( val ) then
            return fmt("Color(%i,%i,%i,%i)", val.r, val.g, val.b, val.a)
        else
            return fmt("{ tbl:%p#%i }", val, table.Count(val))
        end
    else
        if isstring( val ) then
            return fmt("\"%s\"", val:gsub( ".", stringEscape ))
        elseif isvector( val ) then
            return fmt("Vector(%i,%i,%i)", val.x, val.y, val.z)
        elseif isangle( val ) then
            return fmt("Angle(%i,%i,%i)", val.pitch, val.yaw, val.roll)
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
        elseif isfunction(val) then
            local debugInfo = debug.getinfo(val)
            if debugInfo.what == "C" then
                return fmt("cfunc:%p", val)
            else
                return fmt("func:%p", val), fmt("%s[%d-%d]", debugInfo.short_src, debugInfo.linedefined, debugInfo.lastlinedefined)
            end
        else
            return tostring( val )
        end
    end
end

function Format.FormatLong( val, level, doFull, doneTbls )
    local type = type(val)
    if blacklistedTypes[type] then return tostring(val) end
    level = level or 0
    doneTbls = doneTbls or {}
    local levelIndent = string.rep("    ", level)
    if isstring(val) then
        if string.find(val, "\n") then
            val = string.Replace(val, "\\", "\\\\")
            val = string.Replace(val, "]", "\\]")
            return fmt("[[%s]]", val)
        else
            return Format.FormatShort(val)
        end
    elseif type == "thread" then
        return tostring(val), coroutine.status(val)
    elseif isbool(val) or isnumber(val) then
        return Format.FormatShort(val)
    elseif isentity(val) then
        if IsValid(val) then
            if val:IsPlayer() then
                return fmt("-- %s : %s\n%s-- %s\n%s-- %s\n%s-- http://steamcommunity.com/profiles/%s \n%s%s", Format.FormatShort(val), val:Nick(), levelIndent, val:SteamID(), levelIndent, val:GetModel(), levelIndent, val:SteamID64(), levelIndent, Format.FormatLong( val:GetTable(), level, doFull, doneTbls))
            else
                return fmt("-- %s\n%s-- %s\n%s-- %s\n%s%s", Format.FormatShort(val), levelIndent, val:GetClass(), levelIndent, val:GetModel(), levelIndent, Format.FormatLong( val:GetTable(), level, doFull, doneTbls))
            end
        else
            return Format.FormatShort(val)
        end

    elseif isfunction(val) then
        local debugInfo = debug.getinfo(val)
        if debugInfo.what == "C" then
            return fmt("cfunc:%p", val)
        else
            local fullpath = debugInfo.short_src
            local info
            if debugInfo.source ~= "@"..debugInfo.short_src then
                info = fmt("%s\n%s-- %s\n%s-- %d-%d", debugInfo.source, levelIndent,  debugInfo.short_src, levelIndent, debugInfo.linedefined, debugInfo.lastlinedefined)
            else
                
                info = fmt("%s:%d-%d", debugInfo.source, debugInfo.linedefined, debugInfo.lastlinedefined)
            end
            if file.Exists(fullpath, "GAME") then
                local fileContent = file.Read(fullpath, "GAME")
                local lines = string.Split(fileContent, "\n")
                if debugInfo.lastlinedefined > #lines then 
                    return fmt("%sfunc(%p)", levelIndent, val), info
                end
                local indent = "^"..string.match(lines[debugInfo.linedefined], "^%s*")
                local result = string.gsub(lines[debugInfo.linedefined], indent, "")
                if debugInfo.linedefined == debugInfo.lastlinedefined then
                    return string.Trim(result), info
                else
                    for i = debugInfo.linedefined + 1, debugInfo.lastlinedefined do
                        result = result .. "\n" .. levelIndent .. string.gsub(lines[i], indent, "")
                    end
                    return string.Trim(result), info
                end
            else
                return fmt("func(%p)",val), info
            end
        end
    elseif val and not istable(val) and isfunction(val.GetTable) then
        return fmt("-- %s\n%s", Format.FormatShort(val), Format.FormatLong( val:GetTable(), level, doFull, doneTbls))
    elseif not istable( val ) or IsColor( val ) then
        return Format.FormatShort( val )
    elseif val == nil or ( not istable(val) and not IsValid(val) ) then
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
                str, cmt = Format.FormatLong(v, level + 1, doFull, doneTbls)
            else
                str, cmt = Format.FormatShort(v)
            end
            if cmt and string.find(cmt, "\n") then
                cmt = fmt(" --[[ %s ]]", cmt)
            elseif cmt then
                cmt = fmt(" -- %s", cmt)
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
                str, cmt = Format.FormatLong(v, level + 1, doFull, doneTbls)
            else
                str, cmt = Format.FormatShort(v)
            end
            if cmt and string.find(cmt, "\n") then
                cmt = fmt(" --[[ %s ]]", cmt)
            elseif cmt then
                cmt = fmt(" -- %s", cmt)
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
        local formated, cmt = Format.FormatLong(messageData[1], 0, displayFull)
        if cmt then
            text = fmt("-- %s\n%s", cmt, formated)
        else
            text = formated
        end
    else
        local lines = {}
        for k, v in pairs(messageData) do
            local formated, cmt = Format.FormatLong(v, 0, displayFull)
            if string.find(v, "\n") then
                formated = "\n" .. formated .. "-- " .. cmt
            end
            table.insert(lines, fmt("-- %s : %s", k, formated))
        end
        text = table.concat(lines, "\n")
    end
    return text == "" and "nil" or text
end