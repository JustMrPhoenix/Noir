Noir = Noir or {}
Noir.DebugConvar = CreateConVar("noir_debug", "0", FCVAR_ARCHIVE, "Set debug mode of Noir lua editor", 0, 1)
Noir.DEBUG = Noir.DebugConvar:GetBool()

cvars.AddChangeCallback("noir_debug", function(cvar, old, new)
    Noir.DEBUG = Noir.DebugConvar:GetBool()
end, "noirDebugToggle")

local reload = function()
    if CLIENT then
        if IsValid(Noir.Editor.Frame) then
            Noir.Editor.Frame:Remove()
        end

        if IsValid(Noir.FileBrowser.Frame) then
            Noir.FileBrowser.Frame:Remove()
        end

        if IsValid(Noir.ReplFrame) then
            Noir.ReplFrame:Remove()
        end

        Noir = nil
    end

    include("noir/noir_init.lua")
end

Noir.Reload = reload

if CLIENT then
    concommand.Add("noir_reload_cl", reload, nil, "Reload Noir lua editor")

    concommand.Add("noir_reload_skin", function()
        include("noir/client/skin.lua")
    end, nil, "Reload Noir skin")
else
    concommand.Add("noir_reload_sv", function(ply)
        if IsValid(ply) and not ply:IsSuperAdmin() then return end
        reload()
    end, nil, "Reload Noir lua editor")
end

local function loadModule(path)
    local namesplit = path:Split("/")
    local name = table.remove(namesplit):Split(".")[1]
    local folder = namesplit[#namesplit]
    local state

    if folder == "client" then
        state = "CL"
    elseif folder == "server" then
        if CLIENT then return end -- Do not try to load server modules on client
        state = "SV"
    else
        state = "SH"
    end

    if SERVER and state ~= "SV" then
        AddCSLuaFile(path)
    end

    if string.len(name) > 15 then
        name = string.Left(name, 12) .. "..."
    end

    local str = Format("| [%s] MODULE: %s%s |", state, name, string.rep(" ", 15 - name:len()))
    print(str)
    if state == "CL" and SERVER then return end
    include(path)
end

function Noir.Load()
    if CLIENT and not (BRANCH ~= "dev" and BRANCH ~= "unknown") then
        print("[Noir] Please install chromium to use Noir lua editor")

        return
    end

    require("luacheck")

    print("+------------------------------+")
    print("|            -Noir-            |")
    print("+------------------------------+")
    print("|                              |")
    loadModule("logging.lua")
    loadModule("utils.lua")
    loadModule("network.lua")
    loadModule("execution.lua")
    loadModule("outputFormat.lua")
    loadModule("environment.lua")
    loadModule("client/autocomplete.lua")
    loadModule("client/skin.lua")
    loadModule("client/fileBrowser.lua")
    loadModule("client/monaco_panel.lua")
    loadModule("client/editor.lua")
    loadModule("client/repl.lua")
    print("|                              |")
    print("+-------Loading complete-------+")
    Noir.Msg("Loaded!\n")
end

if SERVER then
    AddCSLuaFile()
    for _,filename in ipairs(file.Find("lua/includes/modules/luacheck*", "GAME")) do
        AddCSLuaFile("includes/modules/" .. filename)
    end
end

Noir.Load()