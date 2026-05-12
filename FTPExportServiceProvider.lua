-- FTPExportServiceProvider.lua
-- Multi-FTP Export Plugin for Lightroom Classic

local LrDialogs  = import 'LrDialogs'
local LrFileUtils= import 'LrFileUtils'
local LrPathUtils= import 'LrPathUtils'
local LrView     = import 'LrView'
local LrBinding  = import 'LrBinding'
local LrTasks    = import 'LrTasks'
local LrFtp      = import 'LrFtp'
local LrErrors   = import 'LrErrors'
local LrColor    = import 'LrColor'
local LrPrefs    = import 'LrPrefs'

local ProfileManager = require 'ProfileManager'
local WinScp         = require 'WinScpHelper'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'
local bind = LrView.bind

-- Modal text input dialog (LrDialogs.prompt only returns the verb,
-- so we build a small modal with an edit_field). Returns the entered
-- string on OK, or nil on cancel.
local function askForText(title, label, defaultValue, actionVerb)
    local result
    LrFunctionContext.callWithContext('ftpexport_ask', function(context)
        local props = LrBinding.makePropertyTable(context)
        props.value = defaultValue or ''
        local f = LrView.osFactory()
        local contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text { title = label or '', fill_horizontal = 1 },
            f:edit_field { value = bind 'value', width_in_chars = 30, fill_horizontal = 1 },
        }
        local choice = LrDialogs.presentModalDialog {
            title       = title or 'Input',
            contents    = contents,
            actionVerb  = actionVerb or 'OK',
            cancelVerb  = 'Cancel',
        }
        if choice == 'ok' then
            result = props.value
        end
    end)
    return result
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- Build the items list for the active-profile popup menu.
local function buildProfileItems()
    local names = ProfileManager.listNames()
    local items = { { title = '— Select —', value = '' } }
    for _, n in ipairs(names) do items[#items+1] = { title = n, value = n } end
    return items
end

local function refreshProfileList(props)
    props.profileItems = buildProfileItems()
end

local function applyProfile(name, props)
    local data = ProfileManager.load(name)
    if not data then return end
    props.protocol        = data.protocol       or 'ftp'
    props.ftpHost         = data.ftpHost        or ''
    props.ftpPort         = data.ftpPort        or '21'
    props.ftpUsername     = data.ftpUsername    or ''
    props.ftpPassword     = data.ftpPassword    or ''
    props.ftpRemotePath   = data.ftpRemotePath  or '/'
    props.ftpPassive      = data.ftpPassive     ~= false
    props.subfolderMode   = data.subfolderMode  or 'none'
    props.customSubfolder = data.customSubfolder or ''
    props.ftpOverwrite    = data.ftpOverwrite   == true
    props.generateCsv     = data.generateCsv    ~= false
    props.csvOnly         = data.csvOnly        == true
    props.activeProfile   = name
    ProfileManager.setLastUsed(name)
end

-- Decode serialized selected list from propertyTable string key
local function getSelected(props)
    local raw = props['selectedProfiles']
    return type(raw) == 'table' and raw or {}
end

local function setSelected(props, tbl)
    props['selectedProfiles'] = tbl
end

local function isSelected(props, name)
    local s = getSelected(props)
    return s[name] == true
end

local function toggleSelected(props, name)
    local s = getSelected(props)
    s[name] = not s[name] or nil   -- nil removes the key (false-y)
    setSelected(props, s)
    -- persist
    ProfileManager.saveSelected(s)
end

-- Count selected
local function countSelected(props)
    local s = getSelected(props)
    local n = 0
    for _, v in pairs(s) do if v then n = n + 1 end end
    return n
end

-------------------------------------------------------------------------------
-- Builds the multi-server checklist rows
-------------------------------------------------------------------------------

local function buildServerList(f, propertyTable)
    local names = ProfileManager.listNames()

    if #names == 0 then
        return f:static_text {
            title = "No saved profiles. Add at least one profile in the 'Profiles' section.",
            text_color = LrColor(0.6, 0.4, 0.1),
            fill_horizontal = 1,
        }
    end

    local rows = {}

    -- Header row
    rows[#rows+1] = f:row {
        f:static_text { title = "Upload", width = 45, font = '<system/small/bold>' },
        f:static_text { title = "Profile / Server", fill_horizontal = 1, font = '<system/small/bold>' },
        f:static_text { title = "Folder", fill_horizontal = 1, font = '<system/small/bold>' },
        f:static_text { title = "User", width = 100, font = '<system/small/bold>' },
        f:static_text { title = "Test", width = 50, font = '<system/small/bold>' },
    }

    rows[#rows+1] = f:separator { fill_horizontal = 1 }

    for _, name in ipairs(names) do
        local data    = ProfileManager.load(name)
        local capName = name  -- capture for closure

        -- Each profile gets a unique property key for its checkbox
        local cbKey = 'sel__' .. name
        -- Initialize from persisted selection
        if propertyTable[cbKey] == nil then
            local saved = ProfileManager.loadSelected()
            propertyTable[cbKey] = saved[name] == true
        end

        rows[#rows+1] = f:row {
            spacing = f:label_spacing(),

            -- Checkbox
            f:checkbox {
                value = bind(cbKey),
                width = 45,
                action = function(cb)
                    -- sync persisted map
                    local s = ProfileManager.loadSelected()
                    s[capName] = cb.value or nil
                    ProfileManager.saveSelected(s)
                    -- update summary key
                    local count = 0
                    for _, v in pairs(s) do if v then count = count + 1 end end
                    propertyTable.selectedCount = count
                end,
            },

            -- Profile name + host
            f:column {
                fill_horizontal = 1,
                f:static_text { title = capName, font = '<system/small/bold>' },
                f:static_text {
                    title = string.upper(data.protocol or 'ftp') .. '  '
                          .. (data.ftpHost or '?') .. ':' .. (data.ftpPort or '21'),
                    text_color = LrColor(0.45, 0.45, 0.45),
                    font = '<system/small>',
                },
            },

            -- Remote path
            f:static_text {
                title = data.ftpRemotePath or '/',
                fill_horizontal = 1,
                font = '<system/small>',
                text_color = LrColor(0.3, 0.3, 0.5),
            },

            -- Username
            f:static_text {
                title = data.ftpUsername or '',
                width = 100,
                font = '<system/small>',
            },

            -- Quick test button
            f:push_button {
                title = "Тест",
                width = 50,
                font  = '<system/small>',
                action = function()
                    LrTasks.startAsyncTask(function()
                        local proto = data.protocol or 'ftp'
                        if proto == 'ftps' then
                            local ok, msg = WinScp.runTest({
                                protocol   = 'ftps',
                                host       = data.ftpHost,
                                port       = tonumber(data.ftpPort) or 21,
                                username   = data.ftpUsername,
                                password   = data.ftpPassword,
                                passive    = true, -- FTPS always uses passive (active is unsupported by most FTPS servers behind NAT)
                                remotePath = data.ftpRemotePath or '/',
                            })
                            LrDialogs.message((ok and 'OK — ' or '✗ ') .. capName, msg,
                                ok and 'info' or 'critical')
                            return
                        end
                        local conn = LrFtp.create({
                            protocol = (proto == 'sftp') and 'sftp' or 'ftp',
                            server   = data.ftpHost,
                            port     = tonumber(data.ftpPort) or 21,
                            username = data.ftpUsername,
                            password = data.ftpPassword,
                            passive  = data.ftpPassive,
                        }, false)
                        if conn then
                            local ok = conn:existsOnServer(data.ftpRemotePath or '/')
                            conn:disconnect()
                            if ok ~= nil then
                                LrDialogs.message('OK — ' .. capName, 'Connection works.', 'info')
                            else
                                LrDialogs.message('Warning — ' .. capName, 'Connected, but folder not found.', 'warning')
                            end
                        else
                            LrDialogs.message('Error — ' .. capName, 'Cannot connect.', 'critical')
                        end
                    end)
                end,
            },
        }
    end

    return f:column { spacing = f:control_spacing(), fill_horizontal = 1, unpack(rows) }
end

-------------------------------------------------------------------------------
-- UI Sections
-------------------------------------------------------------------------------

local function sectionsForTopOfDialog(viewFactory, propertyTable)
    local f = viewFactory

    -- Auto-load last profile
    if not propertyTable.activeProfile or propertyTable.activeProfile == '' then
        local last = ProfileManager.getLastUsed()
        if last and ProfileManager.load(last) then applyProfile(last, propertyTable) end
    end

    -- Init selected count
    local saved = ProfileManager.loadSelected()
    local cnt = 0
    for _, v in pairs(saved) do if v then cnt = cnt + 1 end end
    propertyTable.selectedCount = cnt

    -- Init profile dropdown items
    refreshProfileList(propertyTable)

    return {

        -----------------------------------------------------------------------
        -- SECTION 1 — Profile management
        -----------------------------------------------------------------------
        {
            title   = "Profiles",
            synopsis = bind { key = 'activeProfile', object = propertyTable },

            f:column {
                spacing = f:control_spacing(),
                fill_horizontal = 1,

                -- Dropdown + management
                f:row {
                    f:static_text { title = "Edit:", alignment = 'right', width = LrView.share 'lw' },
                    f:popup_menu {
                        value = bind 'activeProfile',
                        fill_horizontal = 1,
                        items = bind 'profileItems',
                        action = function(popup)
                            local v = popup.value
                            if v and v ~= '' then applyProfile(v, propertyTable) end
                        end,
                    },
                },

                f:row {
                    f:push_button {
                        title = "Save As…",
                        action = function()
                            LrTasks.startAsyncTask(function()
                                local sug = (propertyTable.activeProfile ~= '' and propertyTable.activeProfile)
                                            or (propertyTable.ftpUsername ~= '' and propertyTable.ftpUsername)
                                            or 'New profile'
                                local name = askForText('Save FTP profile', 'Profile name:', sug, 'Save')
                                if type(name) == 'string' and name ~= '' then
                                    if ProfileManager.load(name) then
                                        if LrDialogs.confirm('Overwrite', '"'..name..'" already exists. Overwrite?', 'Overwrite', 'Cancel') ~= 'ok' then return end
                                    end
                                    ProfileManager.save(name, propertyTable)
                                    propertyTable.activeProfile = name
                                    refreshProfileList(propertyTable)
                                    LrDialogs.message('Saved',
                                        '"'..name..'" has been saved.\n\n'
                                        ..'Note: the Multi-FTP destinations list below is built when the Export '
                                        ..'dialog opens. To see this profile there, close and reopen Export.',
                                        'info')
                                end
                            end)
                        end,
                    },
                    f:push_button {
                        title = "Update",
                        action = function()
                            local name = propertyTable.activeProfile
                            if not name or name == '' then LrDialogs.message('Error','No profile selected.','warning'); return end
                            ProfileManager.save(name, propertyTable)
                            LrDialogs.message('Saved', '"'..name..'" has been updated.', 'info')
                        end,
                    },
                    f:push_button {
                        title = "Rename",
                        action = function()
                            LrTasks.startAsyncTask(function()
                                local old = propertyTable.activeProfile
                                if not old or old == '' then LrDialogs.message('Error','No profile selected.','warning'); return end
                                local new = askForText('Rename profile', 'New name:', old, 'Rename')
                                if type(new) == 'string' and new ~= '' and new ~= old then
                                    if ProfileManager.rename(old, new) then
                                        propertyTable.activeProfile = new
                                        refreshProfileList(propertyTable)
                                    else
                                        LrDialogs.message('Error','A profile with this name already exists.','critical')
                                    end
                                end
                            end)
                        end,
                    },
                    f:push_button {
                        title = "Delete",
                        action = function()
                            LrTasks.startAsyncTask(function()
                                local name = propertyTable.activeProfile
                                if not name or name == '' then LrDialogs.message('Error','No profile selected.','warning'); return end
                                if LrDialogs.confirm('Delete','"'..name..'" will be deleted.','Delete','Cancel') == 'ok' then
                                    ProfileManager.delete(name)
                                    propertyTable.activeProfile = ''
                                    refreshProfileList(propertyTable)
                                end
                            end)
                        end,
                    },
                    f:push_button {
                        title = "+ New",
                        action = function()
                            propertyTable.activeProfile=''; propertyTable.protocol='ftp'
                            propertyTable.ftpHost=''; propertyTable.ftpPort='21'
                            propertyTable.ftpUsername=''; propertyTable.ftpPassword=''; propertyTable.ftpRemotePath='/'
                            propertyTable.ftpPassive=true; propertyTable.subfolderMode='none'
                            propertyTable.customSubfolder=''; propertyTable.ftpOverwrite=false
                            propertyTable.generateCsv=true; propertyTable.csvOnly=false
                        end,
                    },
                },

                -- FTP fields for the selected profile
                f:separator { fill_horizontal = 1 },

                f:row {
                    f:static_text { title = "Protocol:", alignment='right', width = LrView.share 'lw' },
                    f:popup_menu {
                        value = bind 'protocol',
                        items = {
                            { title = "FTP (plain)",                value = 'ftp'  },
                            { title = "FTPS (FTP over TLS, via WinSCP)", value = 'ftps' },
                            { title = "SFTP (SSH)",                 value = 'sftp' },
                        },
                    },
                },
                f:row {
                    f:static_text { title = "FTP Host:", alignment='right', width = LrView.share 'lw' },
                    f:edit_field { value = bind 'ftpHost', fill_horizontal=1, placeholder_string="ftps.shutterstock.com" },
                },
                f:row {
                    f:static_text { title = "Port:", alignment='right', width = LrView.share 'lw' },
                    f:edit_field { value = bind 'ftpPort', width_in_chars=6 },
                    f:checkbox { title = "Passive (PASV)", value = bind 'ftpPassive' },
                },
                f:row {
                    f:static_text { title = "Username:", alignment='right', width = LrView.share 'lw' },
                    f:edit_field { value = bind 'ftpUsername', fill_horizontal=1 },
                },
                f:row {
                    f:static_text { title = "Password:", alignment='right', width = LrView.share 'lw' },
                    f:password_field { value = bind 'ftpPassword', fill_horizontal=1 },
                },
                f:row {
                    f:static_text { title = "Folder:", alignment='right', width = LrView.share 'lw' },
                    f:edit_field { value = bind 'ftpRemotePath', fill_horizontal=1, placeholder_string="/public_html/photos" },
                },
                f:row {
                    f:static_text { title = "Subfolder:", alignment='right', width = LrView.share 'lw' },
                    f:popup_menu {
                        value = bind 'subfolderMode',
                        items = {
                            { title="No subfolder",            value="none"   },
                            { title="By date YYYY-MM-DD",      value="date"   },
                            { title="Custom",                  value="custom" },
                        },
                    },
                    f:edit_field {
                        value = bind 'customSubfolder',
                        fill_horizontal = 1,
                        enabled = LrBinding.keyEquals('subfolderMode','custom',propertyTable),
                        placeholder_string = "my-photos",
                    },
                },
                f:row {
                    f:checkbox { title="Overwrite existing files", value = bind 'ftpOverwrite' },
                },
                f:row {
                    f:checkbox { title="Generate Shutterstock CSV (shutterstock_content_upload.csv)", value = bind 'generateCsv' },
                },
                f:row {
                    f:checkbox { title="CSV only — do NOT upload images (skip FTP)", value = bind 'csvOnly' },
                },
                f:row {
                    f:push_button {
                        title = "Test connection",
                        action = function()
                            LrTasks.startAsyncTask(function()
                                local proto = propertyTable.protocol or 'ftp'
                                if proto == 'ftps' then
                                    local ok, msg, logPath = WinScp.runTest({
                                        protocol   = 'ftps',
                                        host       = propertyTable.ftpHost,
                                        port       = tonumber(propertyTable.ftpPort) or 21,
                                        username   = propertyTable.ftpUsername,
                                        password   = propertyTable.ftpPassword,
                                        passive    = true, -- FTPS always passive
                                        remotePath = propertyTable.ftpRemotePath or '/',
                                    })
                                    LrDialogs.message(ok and 'Success' or 'Error',
                                        msg .. (logPath and ('\nLog: '..logPath) or ''),
                                        ok and 'info' or 'critical')
                                    return
                                end
                                local conn = LrFtp.create({
                                    protocol = (proto == 'sftp') and 'sftp' or 'ftp',
                                    server=propertyTable.ftpHost, port=tonumber(propertyTable.ftpPort) or 21,
                                    username=propertyTable.ftpUsername, password=propertyTable.ftpPassword,
                                    passive=propertyTable.ftpPassive,
                                }, false)
                                if conn then
                                    local ok = conn:existsOnServer(propertyTable.ftpRemotePath or '/')
                                    conn:disconnect()
                                    LrDialogs.message(ok~=nil and 'Success' or 'Warning',
                                        ok~=nil and 'Connection works.' or 'Connected, but folder not found.',
                                        ok~=nil and 'info' or 'warning')
                                else
                                    LrDialogs.message('Error','Cannot connect.','critical')
                                end
                            end)
                        end,
                    },
                },
            },
        },

        -----------------------------------------------------------------------
        -- SECTION 2 — Multi-FTP destination selection
        -----------------------------------------------------------------------
        {
            title = "Multi-FTP — Upload destinations",
            synopsis = bind { key = 'selectedCount', object = propertyTable },

            f:column {
                spacing = f:control_spacing(),
                fill_horizontal = 1,

                -- Info banner
                f:row {
                    f:static_text {
                        title = "Check all servers you want to upload the photos to simultaneously:",
                        fill_horizontal = 1,
                    },
                },

                -- Selected count
                f:row {
                    f:static_text {
                        title = "Selected servers: ",
                        font  = '<system/small>',
                    },
                    f:static_text {
                        value = bind { key='selectedCount', object=propertyTable,
                            transform = function(v) return tostring(v or 0) end },
                        font  = '<system/small/bold>',
                        text_color = LrColor(0.1, 0.5, 0.1),
                    },
                },

                f:separator { fill_horizontal = 1 },

                -- Dynamic list
                buildServerList(f, propertyTable),

                f:separator { fill_horizontal = 1 },

                -- Buttons: Select all / None
                f:row {
                    f:push_button {
                        title = "Select all",
                        action = function()
                            local names = ProfileManager.listNames()
                            local s = {}
                            for _, n in ipairs(names) do
                                s[n] = true
                                propertyTable['sel__'..n] = true
                            end
                            ProfileManager.saveSelected(s)
                            propertyTable.selectedCount = #names
                        end,
                    },
                    f:push_button {
                        title = "Select none",
                        action = function()
                            local names = ProfileManager.listNames()
                            for _, n in ipairs(names) do
                                propertyTable['sel__'..n] = false
                            end
                            ProfileManager.saveSelected({})
                            propertyTable.selectedCount = 0
                        end,
                    },
                },

                f:row {
                    f:static_text {
                        title = "The selection is remembered between sessions. Files are uploaded sequentially to each server.",
                        text_color = LrColor(0.5,0.5,0.5),
                        font = '<system/small>',
                        fill_horizontal = 1,
                    },
                },
            },
        },
    }
end

-------------------------------------------------------------------------------
-- Default fields
-------------------------------------------------------------------------------

local function getDefaultExportPresetFields()
    return {
        { key='activeProfile',    default='' },
        { key='protocol',         default='ftp' },
        { key='ftpHost',          default='' },
        { key='ftpPort',          default='21' },
        { key='ftpUsername',      default='' },
        { key='ftpPassword',      default='' },
        { key='ftpRemotePath',    default='/' },
        { key='ftpPassive',       default=true },
        { key='subfolderMode',    default='none' },
        { key='customSubfolder',  default='' },
        { key='ftpOverwrite',     default=false },
        { key='generateCsv',      default=true },
        { key='csvOnly',          default=false },
        { key='selectedCount',    default=0 },
        { key='profileItems',     default={ { title='— Select —', value='' } } },
    }
end

-------------------------------------------------------------------------------
-- Upload to one server
-------------------------------------------------------------------------------

local function uploadToServer(exportContext, data, nPhotos, subfolderMode, customSubfolder, overwrite)
    local remotePath = data.ftpRemotePath or '/'
    if subfolderMode == 'date' then
        remotePath = remotePath:gsub('/$','') .. '/' .. os.date('%Y-%m-%d')
    elseif subfolderMode == 'custom' and (customSubfolder or '') ~= '' then
        remotePath = remotePath:gsub('/$','') .. '/' .. customSubfolder
    end

    local conn = LrFtp.create({
        server   = data.ftpHost,
        port     = tonumber(data.ftpPort) or 21,
        username = data.ftpUsername,
        password = data.ftpPassword,
        passive  = data.ftpPassive,
    }, true)

    if not conn then
        return false, "Cannot connect to: " .. (data.ftpHost or '?')
    end

    if not conn:existsOnServer(remotePath) then
        if not conn:makeDirectory(remotePath) then
            conn:disconnect()
            return false, "Cannot create folder: " .. remotePath
        end
    end

    local errors = {}
    -- We iterate renditions via cached file list (passed in)
    conn:disconnect()
    return true, errors
end

-------------------------------------------------------------------------------
-- processRenderedPhotos — uploads to all selected servers
-------------------------------------------------------------------------------

-- Escape a single CSV field per RFC 4180.
local function csvEscape(v)
    if v == nil then return "" end
    local s = tostring(v)
    if s:find('[,"\r\n]') then
        s = '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

-- Build a Shutterstock-style content_upload.csv next to the rendered files.
-- Columns: Filename, Description, Keywords, Categories, Editorial, Mature content, illustration
-- Returns the path to the CSV file, or nil on failure.
local function buildShutterstockCsv(renderedFiles)
    if #renderedFiles == 0 then return nil end

    -- Write CSV next to the rendered files (used for upload).
    local firstDir = LrPathUtils.parent(renderedFiles[1].path)
    local csvPath  = LrPathUtils.child(firstDir, "shutterstock_content_upload.csv")

    local f, err = io.open(csvPath, "wb")
    if not f then
        return nil, "Cannot create CSV: " .. tostring(err)
    end

    -- Header
    f:write("Filename,Description,Keywords,Categories,Editorial,Mature content,illustration\r\n")

    for _, rf in ipairs(renderedFiles) do
        local photo    = rf.rendition.photo
        local filename = LrPathUtils.leafName(rf.path)

        local caption  = photo:getFormattedMetadata('caption')   or ''
        local title    = photo:getFormattedMetadata('title')     or ''
        local kwTable  = photo:getRawMetadata('keywords')        or {}

        -- Description: prefer caption, fall back to title.
        -- Strip out any "[Stock keywords: ...]" block (debug output from AI tools)
        -- and trim surrounding whitespace / blank lines.
        local description = (caption ~= '' and caption) or title
        description = description:gsub('%[%s*[Ss]tock%s+keywords:[^%]]*%]', '')
        description = description:gsub('^%s+', ''):gsub('%s+$', '')
        -- Collapse 3+ newlines into a single blank line
        description = description:gsub('[\r\n]+%s*[\r\n]+', '\n')

        -- Keywords: comma-separated leaf names (skip "Person" / hierarchy parents
        -- by using the keyword name directly). Shutterstock allows max 50 keywords.
        local keywords = {}
        local seen = {}
        for _, kw in ipairs(kwTable) do
            local name = kw:getName()
            if name and name ~= '' and not seen[name:lower()] then
                seen[name:lower()] = true
                keywords[#keywords+1] = name
                if #keywords >= 50 then break end
            end
        end
        local keywordsStr = table.concat(keywords, ",")

        -- Categories, Editorial, Mature content, illustration are left blank
        -- so the contributor can fill them in on the Shutterstock submit page,
        -- or pre-populate via dedicated metadata fields if added later.
        f:write(table.concat({
            csvEscape(filename),
            csvEscape(description),
            csvEscape(keywordsStr),
            "",     -- Categories
            "no",   -- Editorial
            "no",   -- Mature content
            "no",   -- illustration
        }, ",") .. "\r\n")
    end

    f:close()
    return csvPath
end

local function processRenderedPhotos(functionContext, exportContext)
    local exportSession  = exportContext.exportSession
    local exportSettings = exportContext.propertyTable
    local nPhotos        = exportSession:countRenditions()

    -- Collect selected profiles
    local selected = ProfileManager.loadSelected()
    local targets  = {}
    for name, isOn in pairs(selected) do
        if isOn then
            local data = ProfileManager.load(name)
            if data then targets[#targets+1] = { name=name, data=data } end
        end
    end

    -- If none selected, upload to active profile only
    if #targets == 0 then
        local name = exportSettings.activeProfile
        if name and name ~= '' then
            local data = ProfileManager.load(name)
            if data then targets[#targets+1] = { name=name, data=data } end
        end
        -- Final fallback — use the current settings as-is
        if #targets == 0 then
            targets[#targets+1] = { name='(current settings)', data={
                protocol       = exportSettings.protocol or 'ftp',
                ftpHost        = exportSettings.ftpHost,
                ftpPort        = exportSettings.ftpPort,
                ftpUsername    = exportSettings.ftpUsername,
                ftpPassword    = exportSettings.ftpPassword,
                ftpRemotePath  = exportSettings.ftpRemotePath,
                ftpPassive     = exportSettings.ftpPassive,
            }}
        end
    end

    -- Render all photos once and collect local paths,
    -- then upload to each server. Use LrProgressScope directly
    -- (exportContext:withExportProgress is not available in all SDK versions).
    local renderedFiles = {}
    local totalSteps = nPhotos * (#targets + 1) -- +1 for the rendering phase
    local step = 0

    local progressScope = LrProgressScope({
        title = "FTP / FTPS Export",
        functionContext = functionContext,
    })
    progressScope:setCancelable(true)

    local function bumpProgress()
        step = step + 1
        progressScope:setPortionComplete(step, totalSteps)
    end

    -- Phase 1: render
    progressScope:setCaption("Rendering photos…")
    for _, rendition in exportContext:renditions{ stopIfCanceled = true, progressScope = progressScope } do
        if progressScope:isCanceled() then break end
        local ok, pathOrMsg = rendition:waitForRender()
        if ok then
            renderedFiles[#renderedFiles+1] = { path=pathOrMsg, rendition=rendition }
        else
            rendition:recordPublishFailure(pathOrMsg)
        end
        bumpProgress()
    end

    -- Phase 1.5: build Shutterstock-style CSV with metadata
    local csvPath = nil
    if exportSettings.generateCsv ~= false and #renderedFiles > 0 then
        csvPath = buildShutterstockCsv(renderedFiles)
    end

    -- Phase 2: upload to each target (skipped if "CSV only" mode is on)
    if exportSettings.csvOnly then
        progressScope:setCaption("CSV only mode — skipping FTP upload.")
    else
    for _, target in ipairs(targets) do
        if progressScope:isCanceled() then break end
        local d    = target.data
        local tName= target.name

        progressScope:setCaption("Connecting to " .. tName .. "…")

        local remotePath = d.ftpRemotePath or '/'
        if exportSettings.subfolderMode == 'date' then
            remotePath = remotePath:gsub('/$','') .. '/' .. os.date('%Y-%m-%d')
        elseif exportSettings.subfolderMode == 'custom' and (exportSettings.customSubfolder or '') ~= '' then
            remotePath = remotePath:gsub('/$','') .. '/' .. exportSettings.customSubfolder
        end

        local proto = d.protocol or 'ftp'

        if proto == 'ftps' then
            -- WinSCP CLI path (LrFtp does not support FTPS)
            -- NOTE for Shutterstock: only upload images. The CSV manifest must be
            -- submitted later via the Shutterstock web UI (Portfolio → Upload CSV)
            -- AFTER the images are ingested. Uploading the CSV via FTP immediately
            -- after the images causes "MEDIA_MISSING_ASSET" errors because the
            -- server has not yet processed the JPGs.
            local imageFiles = {}
            for _, rf in ipairs(renderedFiles) do
                imageFiles[#imageFiles+1] = { localPath = rf.path }
            end

            progressScope:setCaption("[" .. tName .. "] FTPS upload via WinSCP…")
            local ok, msg, _, logPath = WinScp.runUpload({
                protocol   = 'ftps',
                host       = d.ftpHost,
                port       = tonumber(d.ftpPort) or 21,
                username   = d.ftpUsername,
                password   = d.ftpPassword,
                passive    = true, -- FTPS always passive
                remotePath = remotePath,
                files      = imageFiles,
                overwrite  = exportSettings.ftpOverwrite,
            })
            if not ok then
                for _, rf in ipairs(renderedFiles) do
                    rf.rendition:recordPublishFailure(
                        "[" .. tName .. "] FTPS images: " .. tostring(msg)
                        .. (logPath and (" (log: "..logPath..")") or ""))
                end
            end

            step = step + #renderedFiles
            progressScope:setPortionComplete(step, totalSteps)
        else
            local conn = LrFtp.create({
                protocol = (proto == 'sftp') and 'sftp' or 'ftp',
                server   = d.ftpHost,
                port     = tonumber(d.ftpPort) or 21,
                username = d.ftpUsername,
                password = d.ftpPassword,
                passive  = d.ftpPassive ~= false,
            }, false)

            if not conn then
                for _, rf in ipairs(renderedFiles) do
                    rf.rendition:recordPublishFailure("[" .. tName .. "] Cannot connect to " .. (d.ftpHost or '?'))
                end
            else
                if not conn:existsOnServer(remotePath) then
                    conn:makeDirectory(remotePath)
                end

                for _, rf in ipairs(renderedFiles) do
                    if progressScope:isCanceled() then conn:disconnect() break end
                    local filename   = LrPathUtils.leafName(rf.path)
                    local remoteFile = remotePath:gsub('/$','') .. '/' .. filename

                    progressScope:setCaption("[" .. tName .. "] " .. filename)

                    local exists = conn:existsOnServer(remoteFile)
                    if exists and not exportSettings.ftpOverwrite then
                        rf.rendition:recordPublishFailure("[" .. tName .. "] File already exists: " .. filename)
                    elseif not conn:putFile(rf.path, remoteFile) then
                        rf.rendition:recordPublishFailure("[" .. tName .. "] Upload failed: " .. filename)
                    end

                    bumpProgress()
                end

                -- Upload the CSV alongside the photos
                if csvPath then
                    local csvName   = LrPathUtils.leafName(csvPath)
                    local remoteCsv = remotePath:gsub('/$','') .. '/' .. csvName
                    progressScope:setCaption("[" .. tName .. "] " .. csvName)
                    conn:putFile(csvPath, remoteCsv)
                end

                conn:disconnect()
            end
        end
    end
    end -- end of "if not csvOnly" wrapper

    -- Clean up temporary files
    for _, rf in ipairs(renderedFiles) do
        LrFileUtils.delete(rf.path)
    end
    if csvPath then
        -- Save permanent copies of the CSV next to the source photos
        -- (one CSV per source folder, with a timestamp in the name).
        -- Read the temp CSV once into memory, then write it out to each source folder.
        local fin = io.open(csvPath, "rb")
        local csvData = fin and fin:read("*a") or nil
        if fin then fin:close() end

        local copyCount = 0
        local lastDest = nil
        if csvData then
            local stamp = os.date("%Y%m%d_%H%M%S")
            local seenDirs = {}
            for _, rf in ipairs(renderedFiles) do
                local srcPath = rf.rendition.photo:getRawMetadata('path')
                if srcPath then
                    local srcDir = LrPathUtils.parent(srcPath)
                    if srcDir and not seenDirs[srcDir] and LrFileUtils.exists(srcDir) then
                        seenDirs[srcDir] = true
                        local destCsv = LrPathUtils.child(srcDir,
                            "shutterstock_content_upload_" .. stamp .. ".csv")
                        local fout, werr = io.open(destCsv, "wb")
                        if fout then
                            fout:write(csvData)
                            fout:close()
                            copyCount = copyCount + 1
                            lastDest = destCsv
                        end
                    end
                end
            end
        end

        -- Inform the user where the CSV was saved
        if copyCount > 0 then
            LrDialogs.message("FTP Export — CSV saved",
                "Local CSV copies written: " .. copyCount
                .. "\nLast: " .. tostring(lastDest), "info")
        else
            LrDialogs.message("FTP Export — CSV NOT saved",
                "Could not write a local CSV copy.\nTemp path was: " .. tostring(csvPath),
                "warning")
        end

        -- Then delete the temp copy
        LrFileUtils.delete(csvPath)
    end

    progressScope:done()
end

-------------------------------------------------------------------------------
-- Export
-------------------------------------------------------------------------------

local function updateExportSettings(exportSettings)
    exportSettings.ftpPort = tostring(tonumber(exportSettings.ftpPort) or 21)
    if exportSettings.activeProfile and exportSettings.activeProfile ~= '' then
        ProfileManager.save(exportSettings.activeProfile, exportSettings)
    end
end

return {
    hideSections          = { 'fileNaming', 'exportLocation' },
    allowFileFormats      = { 'JPEG', 'PNG', 'TIFF', 'PSD' },
    canExportVideo        = false,
    exportPresetFields    = getDefaultExportPresetFields(),
    sectionsForTopOfDialog= sectionsForTopOfDialog,
    updateExportSettings  = updateExportSettings,
    processRenderedPhotos = processRenderedPhotos,
}
