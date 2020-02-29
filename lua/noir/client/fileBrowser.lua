local Browser = Noir.FileBrowser or {}
Noir.FileBrowser = Browser

local function getFilePath(filePath, fileName)
    fileName = string.Trim(fileName, "/")

    if filePath == "GAME" then
        return fileName
    else
        return string.format("%s/%s", string.lower(filePath), fileName)
    end
end

local function fixFilePath(filePath, fileName)
    local fullpath = getFilePath(filePath, fileName)
    local pathSplit = fullpath:Split("/")
    if #pathSplit < 2 then return filePath, fileName end
    local first_folder = table.remove(pathSplit, 1):lower()

    if first_folder == "data" then
        return "DATA", table.concat(pathSplit, "/")
    elseif first_folder == "lua" then
        return "LUA", table.concat(pathSplit, "/")
    end

    return filePath, fileName
end

PANEL = {}
PANEL.FilesQueue = {}
PANEL.QueueFrameSize = 30

PANEL.AllowedExtensions = {
    ["txt"] = true,
    ["jpg"] = true,
    ["png"] = true,
    ["vtf"] = true,
    ["dat"] = true,
    ["json"] = true
}

local function addColumn(listView, name)
    local column = listView:AddColumn(name)
    column.Header.BackgroundColor = Color(40, 40, 40)
    column.Header.HoveredColor = Color(70, 70, 70)

    return column
end

local function AddMenuOption(menu, label, callback, icon)
    local option = menu:AddOption(label, callback)
    option:SetIcon(icon)
    option:SetTextColor(Color(200, 200, 200))

    return option
end

function PANEL:Init()
    self:SetSkin("Noir")
    local divider = self:Add("DHorizontalDivider")
    divider:Dock(FILL)
    divider:SetDividerWidth(4)
    divider:SetLeftMin(200)
    divider:SetLeftWidth(200)
    divider:SetRightMin(100)

    divider.m_DragBar.Paint = function(_, w, h)
        surface.SetDrawColor(30, 30, 30)
        surface.DrawRect(0, 0, w, h)
    end

    self.Divider = divider
    local tree = self:Add("DTree")
    tree:SetPaintBackground(false)

    tree.DoClick = function(_, node)
        self:OpenFolder(node:GetFolder())
    end

    divider:SetLeft(tree)
    self.Tree = tree
    local list = self:Add("DListView")
    list:SetPaintBackground(false)
    list:SetMultiSelect(false)
    local icon_column = addColumn(list, "")
    icon_column:SetMinWidth(16)
    icon_column:SetWidth(16)
    icon_column:SetMaxWidth(16)
    -- icon_column.DoClick = function() end
    addColumn(list, "Name")
    addColumn(list, "Date Modified")
    addColumn(list, "Size"):SetWidth(20)
    divider:SetRight(list)
    self.List = list

    list.DoDoubleClick = function(_, lineId, line)
        if line.IsFolder then
            self:OpenFolder(line.Fullpath)
        elseif self.SaveMode then
            self.FileNameEntry:SetText(line:GetColumnText(2))
            self:Save()
        elseif self.OnSelected then
            self:OnSelected(line.Fullpath)
        end
    end

    list.OnRowSelected = function(_, lineId, line)
        if self.SaveMode and not line.IsFolder then
            self.FileNameEntry:SetText(line:GetColumnText(2))
        end
    end

    list.OnMousePressed = function(_, keyCode)
        if keyCode ~= MOUSE_RIGHT then return end
        local menu = DermaMenu()
        menu:SetSkin("Noir")

        AddMenuOption(menu, "Refresh", function()
            self:SetPath(self.Path, self.Folder)
        end, "icon16/arrow_refresh.png")

        local path, _ = fixFilePath(self.Path, self.Folder)

        if path ~= "DATA" then
            menu:Open()

            return
        end

        menu:AddSpacer():SetTall(10)

        AddMenuOption(menu, "New Folder", function()
            Derma_StringRequest("New Folder", "New folder name", "New Folder", function(text)
                local _, folder = fixFilePath(self.Path, self.Folder .. "/" .. text)
                file.CreateDir(string.Trim(folder))
                self:SetPath(self.Path, self.Folder)
            end):SetSkin("Noir")
        end, "icon16/folder_add.png")

        menu:Open()
    end

    list.OnRowRightClick = function(_, lineId, line)
        local menu = DermaMenu()
        menu:SetSkin("Noir")

        AddMenuOption(menu, "Refresh", function()
            self:SetPath(self.Path, self.Folder)
        end, "icon16/arrow_refresh.png")

        local path, fileName = fixFilePath(self.Path, line.Fullpath)

        if path ~= "DATA" then
            menu:Open()

            return
        end

        menu:AddSpacer():SetTall(10)

        AddMenuOption(menu, "New Folder", function()
            Derma_StringRequest("New Folder", "New folder name", "New Folder", function(text)
                local _, folder = fixFilePath(self.Path, self.Folder .. "/" .. text)
                file.CreateDir(string.Trim(folder))
                self:SetPath(self.Path, self.Folder)
            end):SetSkin("Noir")
        end, "icon16/folder_add.png")

        menu:AddSpacer():SetTall(10)

        AddMenuOption(menu, "Delete", function()
            if line.IsFolder then
                Derma_Query("Dou you want to delete `" .. fileName .. "` and all of its contents", "Delete?", "Yes", function()
                    local clearFolder

                    clearFolder = function(name)
                        local files, folders = file.Find(name .. "/*", "DATA")

                        for _, v in pairs(files) do
                            file.Delete(name .. "/" .. v)
                        end

                        for _, v in pairs(folders) do
                            clearFolder(name .. "/" .. v)
                        end

                        file.Delete(name)
                    end

                    clearFolder(fileName)
                    self:SetPath(self.Path, self.Folder)
                end, "No"):SetSkin("Noir")
            else
                Derma_Query("Dou you want to delete `" .. fileName .. "`?", "Delete?", "Yes", function()
                    file.Delete(fileName)
                    list:RemoveLine(lineId)
                end, "No"):SetSkin("Noir")
            end
        end, "icon16/delete.png")

        menu:AddSpacer():SetTall(10)

        AddMenuOption(menu, "Rename", function()
            Derma_StringRequest("Rename", "New file name", string.GetFileFromFilename(fileName), function(text)
                file.Rename(fileName, string.Trim(self.Folder .. "/" .. text, "/"))
                self:SetPath(self.Path, self.Folder)
            end):SetSkin("Noir")
        end, "icon16/tag_blue.png")

        menu:Open()
    end

    local saveFilePanel = self:Add("DPanel")
    saveFilePanel:SetBackgroundColor(Color(40, 40, 40))
    saveFilePanel:Dock(BOTTOM)
    saveFilePanel:SetTall(70)
    self.SaveFilePanel = saveFilePanel
    local fileNameLabel = saveFilePanel:Add("DLabel")
    fileNameLabel:SetPos(20, 12)
    fileNameLabel:SetText("File name: ")
    local fileNameEntry = saveFilePanel:Add("DTextEntry")
    fileNameEntry:Dock(TOP)
    fileNameEntry:DockMargin(72, 12, 100, 0)
    fileNameEntry:SetWide(80)
    fileNameEntry:SetText("")

    fileNameEntry.GetAutoComplete = function(_, text)
        local suggestions = {}
        local files = file.Find("*", self.Path)

        for _, v in pairs(files) do
            if string.StartWith(v, text) then
                table.insert(suggestions, v)
            end
        end

        return suggestions
    end

    self.FileNameEntry = fileNameEntry
    local saveButton = saveFilePanel:Add("DButton")
    saveButton:SetText("Save")
    saveButton:Dock(RIGHT)
    saveButton:DockMargin(0, -20, 15, 38)

    saveButton.DoClick = function()
        self:Save()
    end

    local cancelButton = saveFilePanel:Add("DButton")
    cancelButton:SetText("Cancel")
    cancelButton:Dock(RIGHT)
    cancelButton:DockMargin(0, 12, -65, 5)

    cancelButton.DoClick = function()
        if self.OnCancel then
            self:OnCancel()
        end
    end

    self:SetSaveMode(false)
    list:SetKeyboardInputEnabled(true)
    list:RequestFocus()
    list.OnKeyCodePressed = Noir.Debug
end

function PANEL:Save()
    local folder = self.Folder

    if self.Path ~= "DATA" then
        if self.Path == "GAME" and folder:StartWith("data") then
            folder = folder:sub(5)
        else
            Derma_Message("Cant save file outside data folder", "Error", "Ok"):SetSkin("Noir")

            return
        end
    end

    local filename = self.FileNameEntry:GetText()
    local extension = string.GetExtensionFromFilename(filename)

    if not extension or not self.AllowedExtensions[extension] then
        Derma_Message("Cant save file this this extension", "Error", "Ok"):SetSkin("Noir")

        return
    end

    local fullpath = (folder .. "/" .. filename):Trim("/")
    Noir.Debug("FileBrowserSave", folder, filename, fullpath)

    if file.Exists(fullpath, "DATA") then
        Derma_Query("File already exists, replace it?", "File exists", "Yes", function()
            if self.OnSave then
                self:OnSave(fullpath)
            end
        end, "No"):SetSkin("Noir")

        return
    end

    if self.OnSave then
        self:OnSave(fullpath)
    end
end

function PANEL:SetSaveMode(enable)
    self.SaveMode = enable
    self.SaveFilePanel:SetVisible(enable)
end

function PANEL:QueueFileInfo(fileLine, isFolder, fullpath)
    table.insert(self.FilesQueue, {
        line = fileLine,
        isFolder = isFolder,
        fullpath = fullpath
    })
end

function PANEL:Think()
    if not #self.FilesQueue then return end

    for i = 1, math.min(self.QueueFrameSize, #self.FilesQueue) do
        local tb = table.remove(self.FilesQueue, 1)
        local time = file.Time(tb.fullpath, self.Path)
        tb.line:SetColumnText(3, time > 1 and os.date("%x %R", time) or "N/A")

        if not tb.isFolder then
            local size = file.Size(tb.fullpath, self.Path)
            tb.line:SetColumnText(4, size ~= 0 and string.NiceSize(size) or "N/A")
        end

        if time <= 1 then
            tb.line.Columns[1]:SetImage(tb.isFolder and "icon16/folder_error.png" or "icon16/page_error.png")
        end
    end
end

function PANEL:OpenFolder(folder)
    self.List:Clear()
    self.List:ClearSelection()
    self.List.VBar:SetScroll(0)
    self.Folder = folder
    self.FilesQueue = {}
    local files, folders = file.Find(folder ~= "" and folder .. "/*" or "*", self.Path)
    Noir.Debug("OpenFolder", folder ~= "" and folder .. "/*" or "*", self.Path, files, folders)

    if folder ~= "" then
        local pathSplit = string.Split(folder, "/")
        local lastPart = table.remove(pathSplit)
        local icon = vgui.Create("DImage", self.List)
        icon:SetImage("icon16/arrow_up.png")
        local line = self.List:AddLine(icon, "..", "", "")
        line.Fullpath = #pathSplit == 0 and "" or table.concat(pathSplit, "/")
        line.IsFolder = true
        line.Up = true
        line.Columns[1].Value = "_up"
        local nodes = self.TreeNodes
        table.insert(pathSplit, lastPart)

        for _, v in pairs(pathSplit) do
            for _, node in pairs(nodes) do
                if v == node:GetText() then
                    node:FilePopulate(false, false)
                    node:SetExpanded(true, true)
                    nodes = node.ChildNodes and node.ChildNodes:GetChildren() or {}
                    break
                end
            end
        end
    end

    for _, v in pairs(folders) do
        if v ~= "/" then
            local fullpath = folder ~= "" and folder .. "/" .. v or v
            local icon = vgui.Create("DImage", self.List)
            icon:SetImage("icon16/folder.png")
            local line = self.List:AddLine(icon, v, "", "")
            self:QueueFileInfo(line, true, fullpath)
            line.Columns[1].Value = "folder"
            line.Fullpath = fullpath
            line.IsFolder = true
        end
    end

    for _, v in pairs(files) do
        local fullpath = folder ~= "" and folder .. "/" .. v or v
        local icon = vgui.Create("DImage", self.List)
        icon:SetImage("icon16/page.png")
        local line = self.List:AddLine(icon, v, "", "")
        self:QueueFileInfo(line, false, fullpath)
        line.Columns[1].Value = "file"
        line.Fullpath = fullpath
    end

    if self.OnFolder then
        self:OnFolder(folder)
    end
end

function PANEL:SetPath(path, folder)
    folder = folder or ""
    self.Path = path
    self.Folder = folder
    self.Tree:Clear()
    self.List:Clear()
    self.List:ClearSelection()
    self.List.VBar:SetScroll(0)
    local pathNode = self.Tree:AddNode(path)
    pathNode:MakeFolder("", path)
    pathNode:SetExpanded(true)
    self.TreeNodes = pathNode.ChildNodes:GetChildren()
    self:OpenFolder(folder)
end

vgui.Register("NoirFileBrowser", PANEL, "EditablePanel")
Browser.LastFolder = {}

function Browser.Show(path, startFolder)
    local frame = vgui.Create("DFrame")
    frame:SetSkin("Noir")
    frame:SetMinHeight(300)
    frame:SetMinWidth(300)
    frame.lblTitle:SetVisible(false)
    frame:SetDeleteOnClose(false)
    frame:SetDraggable(true)
    frame:SetSizable(true)
    frame:MakePopup()
    frame.btnMaxim:SetVisible(false)
    frame.btnMinim:SetVisible(false)

    frame.PerformLayout = function()
        frame.btnClose:SetPos(frame:GetWide() - 31, 0)
        frame.btnClose:SetSize(31, 24)
    end

    frame:SetSize(600, 400)
    frame:Center()
    frame:SetTitle("File browser")
    local browser = frame:Add("NoirFileBrowser")
    browser:Dock(FILL)

    if not startFolder and Browser.LastFolder[path] then
        startFolder = Browser.LastFolder[path]
    end

    browser:SetPath(path, startFolder)

    browser.OnFolder = function(_, fullpath)
        Browser.LastFolder[browser.Path] = fullpath
    end

    frame.Browser = browser
    frame.Tree = browser.Tree
    frame.List = browser.List

    return frame
end

function Browser.Open(closeOnSelect)
    if IsValid(Browser.Frame) then
        if Noir.DEBUG then
            Browser.Frame:Remove()
        else
            Browser.Frame:Show()

            return
        end
    end

    Browser.Frame = Browser.Show("GAME")

    Browser.Frame.Browser.OnSelected = function(browser, fullpath)
        if not Noir.Editor.IsReady then return end
        Noir.Editor.Show()
        Noir.Editor.OpenFile(browser.Path, fullpath)

        if closeOnSelect then
            Browser.Frame:Close()
        end
    end

    return Browser.Frame
end

function Browser.SaveDialog(fileName, onSave, onCancel)
    local frame = Browser.Show("DATA")
    frame.Browser:SetSaveMode(true)
    frame.Browser.FileNameEntry:SetText(fileName)

    frame.Browser.OnSave = function(_, fullpath)
        frame:Close()
        onSave(fullpath)
    end

    frame.Browser.OnCancel = function()
        frame:Close()
        onCancel()
    end

    frame.OnClose = onCancel

    return frame
end
-- if Noir.DEBUG then
--     Browser.Open()
-- end

concommand.Add("noir_showbrowser", function(ply, cmd, args)
    Browser.Open()
end)
