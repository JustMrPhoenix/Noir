local WHITE = Color(255,255,255)

function NDL.Msg(...)
    if __CONTEXT then
        print("[NDL] ", ...)
    else
        MsgC(WHITE,"[",Color(0,230,255),"NDL",WHITE,"] ",...)
    end
end

function NDL.Error(...)
    if __CONTEXT then
        print("[ERROR] ", ...)
    else
        NDL.Msg(Color(200,0,0),"[ERROR] ",WHITE,...)
    end
end

function NDL.Print(...)
    print("[NDL] ",...)
end

function NDL.PrintChat(...)
    chatAddText(WHITE,"[",Color(0,230,255),"NDL",WHITE,"] ",...)
end
