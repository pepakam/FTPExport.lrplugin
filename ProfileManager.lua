-- ProfileManager.lua
-- Manage FTP profiles via LrPrefs

local LrPrefs = import 'LrPrefs'

local ProfileManager = {}
local prefs = LrPrefs.prefsForPlugin()

local PROFILES_KEY = 'ftp_profiles'
local ACTIVE_KEY   = 'active_profile'

local function loadRawProfiles()
    local raw = prefs[PROFILES_KEY]
    return type(raw) == 'table' and raw or {}
end

local function saveRawProfiles(profiles)
    prefs[PROFILES_KEY] = profiles
end

function ProfileManager.listNames()
    local profiles = loadRawProfiles()
    local names = {}
    for name in pairs(profiles) do names[#names+1] = name end
    table.sort(names)
    return names
end

function ProfileManager.load(name)
    if not name or name == '' then return nil end
    return loadRawProfiles()[name]
end

function ProfileManager.save(name, settings)
    if not name or name == '' then return false end
    local profiles = loadRawProfiles()
    profiles[name] = {
        protocol        = settings.protocol       or 'ftp',  -- 'ftp' | 'ftps' | 'sftp'
        ftpHost         = settings.ftpHost        or '',
        ftpPort         = settings.ftpPort        or '21',
        ftpUsername     = settings.ftpUsername    or '',
        ftpPassword     = settings.ftpPassword    or '',
        ftpRemotePath   = settings.ftpRemotePath  or '/',
        ftpPassive      = settings.ftpPassive     ~= false,
        subfolderMode   = settings.subfolderMode  or 'none',
        customSubfolder = settings.customSubfolder or '',
        ftpOverwrite    = settings.ftpOverwrite   == true,
        generateCsv     = settings.generateCsv    ~= false,
        csvOnly         = settings.csvOnly        == true,
    }
    saveRawProfiles(profiles)
    prefs[ACTIVE_KEY] = name
    return true
end

function ProfileManager.delete(name)
    if not name or name == '' then return end
    local profiles = loadRawProfiles()
    profiles[name] = nil
    saveRawProfiles(profiles)
    if prefs[ACTIVE_KEY] == name then prefs[ACTIVE_KEY] = nil end
end

function ProfileManager.rename(oldName, newName)
    if not oldName or not newName or newName == '' then return false end
    local profiles = loadRawProfiles()
    if not profiles[oldName] or profiles[newName] then return false end
    profiles[newName] = profiles[oldName]
    profiles[oldName] = nil
    saveRawProfiles(profiles)
    if prefs[ACTIVE_KEY] == oldName then prefs[ACTIVE_KEY] = newName end
    return true
end

function ProfileManager.getLastUsed()   return prefs[ACTIVE_KEY] end
function ProfileManager.setLastUsed(n)  prefs[ACTIVE_KEY] = n    end

-- Stores which profiles are selected for multi-upload (table {name=true})
function ProfileManager.saveSelected(selectedMap)
    prefs['selected_profiles'] = selectedMap
end

function ProfileManager.loadSelected()
    local s = prefs['selected_profiles']
    return type(s) == 'table' and s or {}
end

return ProfileManager
