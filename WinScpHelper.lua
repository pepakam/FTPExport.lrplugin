-- WinScpHelper.lua
-- FTPS upload chrez vunshen WinSCP CLI (LrFtp ne podderzha FTPS).
-- WinSCP: https://winscp.net/  (free, GPL).

local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks     = import 'LrTasks'

local M = {}

-- Standard install paths (relative to user home or absolute)
local CANDIDATE_PATHS = {
    [[C:\Program Files (x86)\WinSCP\WinSCP.com]],
    [[C:\Program Files\WinSCP\WinSCP.com]],
}

local function homeDir()
    return LrPathUtils.getStandardFilePath('home') or ''
end

function M.findExecutable()
    -- Per-user install (most common with non-admin install)
    local home = homeDir()
    if home ~= '' then
        local p = home .. [[\AppData\Local\Programs\WinSCP\WinSCP.com]]
        if LrFileUtils.exists(p) == 'file' then return p end
    end
    for _, p in ipairs(CANDIDATE_PATHS) do
        if LrFileUtils.exists(p) == 'file' then return p end
    end
    return nil
end

-- URL-encode for use inside open ftpes://user:pass@host
local function urlEncode(s)
    if s == nil then return '' end
    return (tostring(s):gsub('[^A-Za-z0-9%-_%.~]', function(c)
        return string.format('%%%02X', string.byte(c))
    end))
end

local function protocolScheme(proto)
    if proto == 'ftps' then return 'ftpes' end   -- explicit FTPS over TLS
    if proto == 'sftp' then return 'sftp'  end
    return 'ftp'
end

-- Normalize a remote path: ensure single leading '/', strip trailing '/'
local function normPath(p)
    if not p or p == '' then return '/' end
    if p:sub(1,1) ~= '/' then p = '/' .. p end
    if #p > 1 then p = p:gsub('/+$','') end
    return p
end

-- Build a script file. files = array of {localPath = '...', remoteName = '...'}
local function buildScript(opts)
    local lines = {}
    lines[#lines+1] = 'option batch abort'
    lines[#lines+1] = 'option confirm off'
    -- Note: passive mode is the WinSCP default for FTP/FTPS;
    -- 'option ftp:passive' is NOT a valid WinSCP scripting option.
    -- If active mode is ever needed, pass -rawsettings FtpPasvMode=0 on the open command.

    local scheme = protocolScheme(opts.protocol)
    local hostPart = opts.host or ''
    local portPart = opts.port and (':' .. tostring(opts.port)) or ''
    -- Use -username and -password switches: they accept raw values without URL-encoding,
    -- avoiding any breakage with special characters in passwords.
    local userArg = string.format(' -username="%s"', (opts.username or ''):gsub('"','""'))
    local passArg = ((opts.password or '') ~= '')
        and string.format(' -password="%s"', opts.password:gsub('"','""'))
        or ''
    local hostKeyOpt = (scheme == 'sftp') and '-hostkey=*' or '-certificate=*'
    local openLine = string.format('open %s://%s%s/ %s%s%s -timeout=30',
        scheme, hostPart, portPart, hostKeyOpt, userArg, passArg)
    if (scheme == 'ftp' or scheme == 'ftpes') and opts.passive == false then
        openLine = openLine .. ' -rawsettings FtpPasvMode=0'
    end
    lines[#lines+1] = openLine

    local remoteDir = normPath(opts.remotePath)
    if remoteDir ~= '/' then
        -- mkdir may fail if exists; tolerate.
        lines[#lines+1] = 'option batch on'
        lines[#lines+1] = string.format('mkdir "%s"', remoteDir)
        lines[#lines+1] = 'option batch abort'
    end
    lines[#lines+1] = string.format('cd "%s"', remoteDir)

    local putFlag = opts.overwrite and '' or '-neweronly'
    for _, f in ipairs(opts.files or {}) do
        -- Inside script, double quotes around path; remote name implicit.
        local remoteName = f.remoteName or LrPathUtils.leafName(f.localPath)
        if putFlag ~= '' then
            lines[#lines+1] = string.format('put %s "%s" "%s"',
                putFlag, f.localPath, remoteName)
        else
            lines[#lines+1] = string.format('put "%s" "%s"',
                f.localPath, remoteName)
        end
    end

    lines[#lines+1] = 'exit'
    return table.concat(lines, '\r\n')
end

local function writeTempFile(content, ext)
    local tempDir = LrPathUtils.getStandardFilePath('temp')
    local name = string.format('lr_winscp_%d_%d.%s',
        os.time(), math.random(10000, 99999), ext or 'txt')
    local path = LrPathUtils.child(tempDir, name)
    local fh, err = io.open(path, 'wb')
    if not fh then return nil, err end
    fh:write(content)
    fh:close()
    return path
end

local function readFileSafe(path)
    local fh = io.open(path, 'rb')
    if not fh then return '' end
    local s = fh:read('*all') or ''
    fh:close()
    return s
end

-- Public: run upload. opts: {executable, protocol, host, port, username, password,
--                            passive, remotePath, files, overwrite}
-- Returns ok(boolean), message(string), perFileErrors(table or nil)
function M.runUpload(opts)
    local exe = opts.executable or M.findExecutable()
    if not exe then
        return false, 'WinSCP not found. Install from https://winscp.net/'
    end

    local script = buildScript(opts)
    local scriptPath, err = writeTempFile(script, 'txt')
    if not scriptPath then
        return false, 'Cannot write temp script: ' .. tostring(err)
    end

    local logPath = scriptPath .. '.log'

    -- Build command line. LrTasks.execute on Windows wraps in cmd /c, so
    -- we wrap whole thing in extra quotes.
    local cmd = string.format('""%s" /script="%s" /log="%s" /loglevel=0 /ini=nul"',
        exe, scriptPath, logPath)

    local exitCode = LrTasks.execute(cmd)
    local logText  = readFileSafe(logPath)

    -- Cleanup
    pcall(LrFileUtils.delete, scriptPath)
    -- Keep log only on failure
    if exitCode == 0 then
        pcall(LrFileUtils.delete, logPath)
        return true, 'OK'
    end

    -- Try to extract a useful error line from the log
    local errMsg = ''
    for line in (logText .. '\n'):gmatch('([^\r\n]+)') do
        if line:match('[Ee]rror') or line:match('[Ff]ailed') or line:match('[Cc]annot') then
            errMsg = line
            break
        end
    end
    if errMsg == '' then errMsg = 'WinSCP exit code ' .. tostring(exitCode) end

    return false, errMsg, nil, logPath
end

-- Public: simple connection test (login + list root)
function M.runTest(opts)
    local exe = opts.executable or M.findExecutable()
    if not exe then
        return false, 'WinSCP not found. Install from https://winscp.net/'
    end

    local lines = {
        'option batch abort',
        'option confirm off',
    }
    local scheme = protocolScheme(opts.protocol)
    local portPart = opts.port and (':' .. tostring(opts.port)) or ''
    local userArg = string.format(' -username="%s"', (opts.username or ''):gsub('"','""'))
    local passArg = ((opts.password or '') ~= '')
        and string.format(' -password="%s"', opts.password:gsub('"','""'))
        or ''
    local hostKeyOpt = (scheme == 'sftp') and '-hostkey=*' or '-certificate=*'
    local openLine = string.format('open %s://%s%s/ %s%s%s -timeout=30',
        scheme, opts.host or '', portPart, hostKeyOpt, userArg, passArg)
    if (scheme == 'ftp' or scheme == 'ftpes') and opts.passive == false then
        openLine = openLine .. ' -rawsettings FtpPasvMode=0'
    end
    lines[#lines+1] = openLine
    lines[#lines+1] = string.format('ls "%s"', normPath(opts.remotePath))
    lines[#lines+1] = 'exit'

    local script = table.concat(lines, '\r\n')
    local scriptPath = writeTempFile(script, 'txt')
    if not scriptPath then return false, 'Cannot write temp script' end

    local logPath = scriptPath .. '.log'
    local cmd = string.format('""%s" /script="%s" /log="%s" /loglevel=0 /ini=nul"',
        exe, scriptPath, logPath)

    local exitCode = LrTasks.execute(cmd)
    local logText  = readFileSafe(logPath)
    pcall(LrFileUtils.delete, scriptPath)

    if exitCode == 0 then
        pcall(LrFileUtils.delete, logPath)
        return true, 'Connection works.'
    end

    local errMsg = ''
    for line in (logText .. '\n'):gmatch('([^\r\n]+)') do
        if line:match('[Ee]rror') or line:match('[Ff]ailed') or line:match('[Cc]annot')
           or line:match('[Aa]uthent') then
            errMsg = line
            break
        end
    end
    if errMsg == '' then errMsg = 'WinSCP exit code ' .. tostring(exitCode) end
    return false, errMsg, logPath
end

return M
