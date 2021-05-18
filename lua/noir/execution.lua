function Noir.RunCode(code, identifier, environment)
    identifier = identifier or "Noir.RunCode"
    local compileResults = CompileString(code, identifier, false)

    if not isfunction(compileResults) then
        Noir.Error("[", identifier, "] Error compiling code: " .. compileResults, "\n")

        return false, compileResults
    end

    if environment then
        debug.setfenv(compileResults, environment)
    end

    local call_results = {pcall(compileResults)}
    Noir.Debug("RunCode", identifier, call_results)

    if not table.remove(call_results, 1) then
        local msg = call_results[1]
        Noir.Error("[", identifier, "] Error pcalling code: " .. tostring(msg), "\n")
        return false, msg
    end

    return true, call_results
end

function Noir.SendCode(code, identifier, target, transferId)
    if util.NetworkStringToID( Noir.Network.Tag ) == 0  and target ~= "self" then
        Noir.ErrorT("This server does not seem to run Noir")
        return
    end
    local data = {
        target = target,
        identifier = identifier,
        vars = Noir.Environment.MakeVars()
    }
    if string.EndsWith(string.lower(code), "--full") or string.StartWith(string.lower(code), "--full") then
        data.full = true
    end

    if target == "self" then
        local me = SERVER and Entity(0) or LocalPlayer()
        local context = Noir.Environment.CreateContext(me, transferId, Noir.Environment.MakeVars())
        local done, returns = Noir.RunCode(code, identifier, context.EnvTable)
        context.RunResults = {done, returns}
        if not done and not isstring(returns) then
            returns = Noir.Format.FormatLong(returns, 0, data.full)
        end
        Noir.Environment.SendMessage(me, transferId, "run", {done, returns, full = data.full})
        if not done then
            ErrorNoHalt(Format("[%s] %s", identifier, returns))
            print()
        end
        return transferId
    end

    Noir.Debug("SendCode", data, code, data.parts)
    Noir.Network.SendTransfer(transferId, data, "runCode", code, target)

    return transferId
end

Noir.Network.StringHandlers["runCode"] = {
    start = function(sender, transferId, data)
        if SERVER then
            Noir.Environment.UpdateVarsSV(data)
            if data.target == "server" then return end
            Noir.Msg( "Sending code(", Color(0, 120, 205), transferId, Color(255,255,255), "): ", -- ):
                Color(230, 220, 115), data.identifier, Color(255,255,255), " [",
                Color(0,150,0), sender == Entity(0) and "(SERVER)" or sender:Nick() .. "(" .. sender:SteamID() .. ")",
                Color(255,255,255), " => ",
                Color(0,150,0), isentity(data.target) and data.target:Nick() .. "(" .. data.target:SteamID() .. ")" or data.target:upper(),
                Color(255,255,255), "]\n"
            )
        end
    end,
    received = function(sender, transferId, data)
        Noir.Msg( "Running code(", Color(0, 120, 205), transferId, Color(255,255,255), "): ", -- ):
            Color(230, 220, 115), data.identifier, Color(255,255,255), " [",
            Color(0,150,0), sender == Entity(0) and "(SERVER)" or sender:Nick() .. "(" .. sender:SteamID() .. ")",
            Color(255,255,255), " => ",
            Color(0,150,0), isentity(data.target) and data.target:Nick() .. "(" .. data.target:SteamID() .. ")" or data.target:upper(),
            Color(255,255,255), "]\n"
        )
        local context = Noir.Environment.CreateContext(sender, transferId, data.vars)
        local done, returns = Noir.RunCode(data.string, data.identifier, context.EnvTable)
        context.RunResults = {done, returns}
        if not done and not isstring(returns) then
            returns = Noir.Format.FormatLong(returns)
        end
        Noir.Environment.SendMessage(sender, transferId, "run", {done, returns, full = data.full})
        if not done then
            ErrorNoHalt(Format("[%s] %s", data.identifier, returns))
            print()
        end
    end
}
