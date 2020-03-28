local Format = Noir.Format or {}
Noir.Format = Format

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
        local str = istable(messageData[1]) and table.ToString(messageData[1], nil, true) or tostring(messageData[1])
        if string.find(str, "\n") then
            str = "\n" .. str
        end
        text = str
    else
        for k, v in pairs(messageData) do
            text = text .. "\n"
            local str = istable(v) and table.ToString(v, tostring(v), true) or tostring(v)
            if string.find(str, "\n") then
                str = "\n" .. str
            end
            text = text .. string.format("-- %s : %s", k, str)
        end
    end
    return text == "" and "nil" or text
end