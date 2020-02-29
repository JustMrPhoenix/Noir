local noirTagColor = Color(200, 200, 200)
local whiteColor = Color(255, 255, 255)
local fileInfo = debug.getinfo(1)
local pathSplit = fileInfo.short_src:Split("/")
table.remove(pathSplit)
Noir.NoirLuaPath = table.concat(pathSplit, "/")

function Noir.Msg(...)
    MsgC(whiteColor, "[", noirTagColor, "Noir", whiteColor, "] ", ...)
end

function Noir.Error(...)
    Noir.Msg(Color(200, 0, 0), "[ERROR] ", whiteColor, ...)
end

function Noir.print(...)
    print("[Noir] ", ...)
end

local function valueToStr(val)
    local valType = type(val)

    if valType == "string" then
        val = string.Replace(val, "\n", "\\n")
        val = string.Replace(val, "\t", "\\t")
    elseif IsColor(val) then
        return string.format("Color(%i,%i,%i,%i)", val.r, val.g, val.b, val.a)
    elseif valType == "Vector" then
        return string.format("Vector(%i,%i,%i)", val.x, val.y, val.z)
    elseif valType == "table" then
        return table.ToString(val, tostring(val), true)
    end

    return string.format("(%s) %s", valType, val)
end

function Noir.Debug(...)
    if not Noir.DEBUG then return end
    local args = {...}
    local debugInfo = debug.getinfo(2)

    if not debugInfo then
        debugInfo = debug.getinfo(1)
    end

    if game.SinglePlayer() or game.GetIPAddress() == "loopback" then
        Noir.Msg("[", SERVER and Color(137, 222, 255) or Color(231, 219, 116), SERVER and "SERVER" or "CLIENT", whiteColor, "]")
    end

    Noir.Msg("[", Color(83, 187, 208), "DEBUG", whiteColor, "](", Color(255, 216, 0), debugInfo.short_src:Replace(Noir.NoirLuaPath .. "/", ""), whiteColor, ":", Color(255, 216, 0), debugInfo.currentline, whiteColor, ") ")

    if isstring(args[1]) then
        Msg(table.remove(args, 1))
    end

    for k, v in pairs(args) do
        MsgC("\n", Color(0, 200, 0), k, whiteColor, ": ", Color(0, 150, 0), valueToStr(v))
    end

    MsgN("")
end

function Noir.PrintChat(...)
    chat.AddText(whiteColor, "[", noirTagColor, "Noir", whiteColor, "] ", ...)
end