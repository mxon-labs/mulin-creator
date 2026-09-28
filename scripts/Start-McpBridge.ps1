<#
.SYNOPSIS
    Bridge that connects to MuLiN Creator's MCP server over stdio (standard input/output).

.DESCRIPTION
    Bridges between a client that talks to an MCP server only over stdio (such as Claude Code
    or Codex) and MuLiN Creator, which speaks HTTP. The bridge is the session's MCP server —
    it answers `initialize`, `tools/list`, and `ping` itself, immediately, using its own
    bundled tool catalog rather than asking Creator. Only `tools/call` is sent to Creator,
    and the target window is resolved fresh on every call (Resolve-McpTarget) rather than
    fixed once at startup — this session is bound to a project, not to a Creator process, so
    restarting Creator and reopening the same project keeps working with no user action.

    If no Creator is running (or none matches), a tools/call fails with a `creator.*` tool
    error instead of the bridge waiting or exiting — the client never restarts a dead stdio
    server, so the bridge must never exit or block on Creator's absence.

    Runs on Windows PowerShell 5.1, which ships with Windows by default — no need to
    install PowerShell 7 separately.

.PARAMETER Port
    Pins this session to the Creator listening on this port. If omitted, checks the
    `MULIN_MCP_PORT` environment variable, and if that is not set either, the target is
    resolved automatically on every call.
    Priority: -Port > MULIN_MCP_PORT > automatic selection.
    A pinned port that has no lock file or does not answer is not a startup error — every
    tools/call reports `creator.not_running` for that port until it comes up.

.PARAMETER Doctor
    Instead of acting as a bridge, prints item by item whether it found a Creator to
    connect to, and if not, why — then exits. Most "the tool does not show up" problems
    are revealed here.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Start-McpBridge.ps1
    Acts as a stdio bridge. This is how an MCP client invokes it.

.EXAMPLE
    powershell.exe -NoProfile -File Start-McpBridge.ps1 -Doctor
    Lets a human read and confirm whether there is a Creator to connect to, and if not, why.
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$Doctor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Uses HttpClient — Windows PowerShell 5.1's Invoke-WebRequest decodes a JSON response whose
# character encoding is not stated as ISO-8859-1, which corrupts any non-ASCII text, and
# project paths and messages routinely carry it. Since System.Net.Http.* types are used as
# function parameter types, that type must already be loaded by the time the function
# definitions are parsed — Add-Type is placed before any function definition.
Add-Type -AssemblyName System.Net.Http

#region Lock files

<#
    The lock directory where Creator records connection info (port, token) when it starts.
    Located under the per-user local app data folder, and does not roam.
#>
function Get-McpLockDirectoryPath
{
    Join-Path $env:LOCALAPPDATA 'MXOn Corporation\MuLiN Creator\mcp'
}

<#
.SYNOPSIS
    Reads all *.lock files in the lock directory and returns them as an array of objects.
.DESCRIPTION
    Silently skips broken files (partially written, missing required fields). The returned
    objects carry the JSON fields of the lock file as-is
    (pid, port, token, transport, mcpUrl, projectPath, appName, version, startedAt).
#>
function Get-McpLockInfos
{
    param([Parameter(Mandatory)][string]$LockDirectory)

    $infos = @()
    if (-not (Test-Path -Path $LockDirectory)) {
        return $infos
    }

    $files = @(Get-ChildItem -Path $LockDirectory -Filter '*.lock' -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        <#
            Parsing and field validation are both placed inside a single try. Set-StrictMode
            -Version Latest turns even a reference to a missing property into an exception —
            if validation sat outside the try, a single lock file missing a required field
            like port (created when Creator died mid-write) would kill this function, and,
            meeting $ErrorActionPreference = 'Stop', the whole bridge. This actually happens,
            so it is handled as something that actually happens.
        #>
        try {
            # Specify -Encoding UTF8 explicitly — projectPath can carry a Korean path, and the
            # file is UTF-8 without a BOM, so reading it with the default code page corrupts it.
            $lock = Get-Content -Path $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json

            # If the content is the JSON literal null (which should not normally happen), the
            # field access below dies under StrictMode — treat it as unreadable and skip.
            if ($null -eq $lock) {
                continue
            }

            # Check whether the required fields exist via PSObject.Properties first — reading a
            # missing property directly (under StrictMode) throws. Lock files with fields
            # missing entirely do actually occur.
            $hasAllFields = ($null -ne $lock.PSObject.Properties['port']) -and
                            ($null -ne $lock.PSObject.Properties['token']) -and
                            ($null -ne $lock.PSObject.Properties['pid']) -and
                            ($null -ne $lock.PSObject.Properties['mcpUrl'])
            if (-not $hasAllFields) {
                continue
            }

            # A field can exist yet still be empty or 0, in which case it is a file we cannot
            # connect to.
            if ((-not $lock.port) -or (-not $lock.token) -or (-not $lock.pid) -or (-not $lock.mcpUrl)) {
                continue
            }
            $infos += $lock
        } catch {
            continue # A file truncated by a mid-write crash, a malformed file, or an unexpected shape
        }
    }
    return $infos
}

#endregion

#region Port specification

<#
.SYNOPSIS
    Settles -Port and MULIN_MCP_PORT into a single port. Priority: -Port > environment variable.
.DESCRIPTION
    A non-numeric value in the environment variable is a human typo. Using `[int]$env:...`
    directly would die with a raw .NET cast exception (ErrorActionPreference = Stop), leaving
    no way to tell what went wrong. So the cast happens only in this one function, and failure
    is returned as a value — the bridge sends it to stderr, and diagnostics print it to the screen.
.OUTPUTS
    A pscustomobject holding Port (0 means unspecified = automatic selection) and Error
    ($null if there is no problem).
#>
function Resolve-McpPreferredPort
{
    param([int]$Port = 0)

    if ($Port -ne 0) {
        return [pscustomobject]@{ Port = $Port; Error = $null }
    }

    $text = $env:MULIN_MCP_PORT
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [pscustomobject]@{ Port = 0; Error = $null }
    }

    $parsed = 0
    if (-not [int]::TryParse($text.Trim(), [ref]$parsed)) {
        return [pscustomobject]@{
            Port  = 0
            Error = "MULIN_MCP_PORT value '$text' is not a port number — enter digits only, such as 29500."
        }
    }
    if (($parsed -lt 1) -or ($parsed -gt 65535)) {
        return [pscustomobject]@{
            Port  = 0
            Error = "MULIN_MCP_PORT value '$text' is out of the port range (1-65535)."
        }
    }
    return [pscustomobject]@{ Port = $parsed; Error = $null }
}

#endregion

#region Choosing which Creator to connect to

<#
.SYNOPSIS
    Folds two paths into a shape that is easy to compare for "is this the same project".
.DESCRIPTION
    Creator tends to normalize paths with `/`, while a tool argument such as open_project's
    path or a lock file's projectPath can arrive with `\`. If the separators are not unified
    and case is not ignored (Windows paths are case-insensitive), the projectPath comparison
    would practically never match.
#>
function ConvertTo-ComparablePath
{
    param([string]$Path)

    if ([string]::IsNullOrEmpty($Path)) {
        return ''
    }
    return ($Path -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
}

#endregion

#region Instance pinning

<#
.SYNOPSIS
    Whether two lock-file-shaped objects refer to the same MuLiN Creator process.
.DESCRIPTION
    Both port and pid must match. Matching by port alone would treat a new process that
    happens to reuse a port a dead one held as "the same instance" it was talking to before.
#>
function Test-McpInstanceMatches
{
    param($A, $B)

    if (($null -eq $A) -or ($null -eq $B)) {
        return $false
    }
    return (([int]$A.port) -eq ([int]$B.port)) -and (([int]$A.pid) -eq ([int]$B.pid))
}

<#
.SYNOPSIS
    Whether a process id is still running, without any network round trip.
.DESCRIPTION
    A closed port on Windows takes roughly two seconds to answer a connection attempt with
    "refused" (measured: Test-McpPing against a closed 127.0.0.1 port returns after
    2000-2245 ms), and every tools/call pings every lock file candidate at least once. Most
    stale lock files belong to a process that has already exited, and that is checkable
    locally and instantly — so it is checked first, and a dead pid never gets a ping at all.

    Only "no such process" is treated as dead. GetProcessById throws exactly
    System.ArgumentException for a pid nothing is running under — that, and HasExited being
    true, are the only two cases returned as $false. Any other exception (most notably a
    Win32Exception "Access is denied") is NOT evidence the process is gone — it means Creator
    is running as a different user or a higher elevation level than this bridge (for example
    started with "Run as administrator" while Claude Code/the bridge is not elevated), and
    HasExited can throw for that even though the process is very much alive. Treating "could
    not tell" as dead here would make that Creator unreachable on every call with no
    fallback, so this returns $true instead — the caller then falls through to the real ping,
    which still works across that boundary.
#>
function Test-McpProcessAlive
{
    param([Parameter(Mandatory)][int]$ProcessId)

    try {
        $process = [System.Diagnostics.Process]::GetProcessById($ProcessId)
        return -not $process.HasExited
    } catch [System.ArgumentException] {
        return $false
    } catch {
        return $true
    }
}

<#
.SYNOPSIS
    Pings every candidate and reports {port, pid, projectPath, version, alive} for each. This is the
    shape list_creator_instances and the creator.target_ambiguous / creator.project_mismatch
    error detail use.
#>
function Get-McpInstanceCandidates
{
    param([array]$Locks, [Parameter(Mandatory)][scriptblock]$PingTest)

    return @($Locks | ForEach-Object {
        $version = ''
        if ($null -ne $_.PSObject.Properties['version']) {
            $version = [string]$_.version
        }
        [pscustomobject]@{
            port        = [int]$_.port
            pid         = [int]$_.pid
            projectPath = $_.projectPath
            version     = $version
            alive       = [bool](& $PingTest $_)
        }
    })
}

#endregion

#region Target resolution

<#
.SYNOPSIS
    Decides which Creator a tools/call goes to, from the lock files, a ping callback, the
    session's current target and the call itself. Pure — no HTTP, no lock directory.
.DESCRIPTION
    The session is bound to a project, not to a process: restarting Creator and reopening the
    same project lands on the same target. Rules are applied top to bottom; the first match
    wins. What each rule protects against is in the comments next to it.
.OUTPUTS
    Target (the lock to send to) — or Code/Message/Detail for a tool error.
#>
function Resolve-McpTarget
{
    param(
        [array]$Locks,
        [Parameter(Mandatory)][scriptblock]$PingTest,
        $Current = $null,
        [string]$ToolName = '',
        $ToolArgs = $null,
        [int]$PinnedPort = 0
    )

    $alive = @($Locks | Where-Object { & $PingTest $_ })

    if ($PinnedPort -ne 0) {
        $hit = @($alive | Where-Object { [int]$_.port -eq $PinnedPort })
        if ($hit.Count -gt 0) {
            return New-McpTargetResult -Target $hit[0]
        }
        return New-McpTargetResult -Code 'creator.not_running' -Detail ([ordered]@{ pinnedPort = $PinnedPort }) -Message (
            "This session is pinned to port $PinnedPort (MULIN_MCP_PORT or -Port), and no MuLiN Creator " +
            'answers there. Ask the user to start Creator or fix the port, then retry this call. ' +
            'Do not work around it by other means.')
    }

    if ($alive.Count -eq 0) {
        return New-McpTargetResult -Code 'creator.not_running' -Message (
            'No MuLiN Creator is running. Ask the user to start MuLiN Creator, then retry this same ' +
            'call. Do not work around it by editing project files or using other tools.')
    }

    $currentAlive = $null
    if ($null -ne $Current) {
        $currentAlive = @($alive | Where-Object { Test-McpInstanceMatches $Current $_ }) | Select-Object -First 1
    }
    $currentPath = ''
    if (($null -ne $Current) -and ($null -ne $Current.PSObject.Properties['projectPath'])) {
        $currentPath = ConvertTo-ComparablePath $Current.projectPath
    }

    if (($ToolName -eq 'open_project') -or ($ToolName -eq 'create_project')) {
        # Opening the same project in two windows is its own accident — go where it already is.
        $wanted = ''
        if (($ToolName -eq 'open_project') -and ($null -ne $ToolArgs) -and ($null -ne $ToolArgs.PSObject.Properties['path'])) {
            $rawPath = [string]$ToolArgs.path
            # Creator's lock projectPath is the project DIRECTORY (fileInfo.absolutePath() in
            # MainWindow.cpp), but open_project receives the .mdp FILE inside it — compare the
            # file's parent directory, or rule (1) never hits and every open_project falls
            # through to the idle/ambiguous rules below.
            if ($rawPath -match '\.mdp$') {
                $wanted = ConvertTo-ComparablePath (Split-Path -Parent $rawPath)
            } else {
                $wanted = ConvertTo-ComparablePath $rawPath
            }
        }
        if ($wanted -ne '') {
            $already = @($alive | Where-Object { (ConvertTo-ComparablePath $_.projectPath) -eq $wanted })
            if ($already.Count -gt 0) {
                return New-McpTargetResult -Target $already[0]
            }
        }
        if ($null -ne $currentAlive) {
            return New-McpTargetResult -Target $currentAlive
        }
        $idle = @($alive | Where-Object { (ConvertTo-ComparablePath $_.projectPath) -eq '' })
        if ($idle.Count -eq 1) {
            return New-McpTargetResult -Target $idle[0]
        }
        if ($alive.Count -eq 1) {
            return New-McpTargetResult -Target $alive[0]
        }
        return New-McpAmbiguousResult -Locks $Locks -PingTest $PingTest
    }

    if ($null -ne $currentAlive) {
        return New-McpTargetResult -Target $currentAlive
    }

    if ($currentPath -ne '') {
        $reopened = @($alive | Where-Object { (ConvertTo-ComparablePath $_.projectPath) -eq $currentPath })
        if ($reopened.Count -eq 1) {
            return New-McpTargetResult -Target $reopened[0]
        }
    }

    if ($alive.Count -eq 1) {
        $only = $alive[0]
        $onlyPath = ConvertTo-ComparablePath $only.projectPath
        if (($currentPath -eq '') -or ($onlyPath -eq '')) {
            return New-McpTargetResult -Target $only
        }
        # The window this session worked on is gone and the only one left has another project
        # open — sending an edit meant for one project into another is the accident (F-20).
        $previous = [ordered]@{ port = [int]$Current.port; pid = [int]$Current.pid; projectPath = $Current.projectPath }
        return New-McpTargetResult -Code 'creator.project_mismatch' -Message (
            "The MuLiN Creator this session was working with (project '$($Current.projectPath)') is gone, " +
            "and the only running Creator has a different project open ('$($only.projectPath)'). " +
            'This call was not sent. Ask the user whether to reopen the original project or to continue ' +
            'in that window, then call use_creator_instance with its port. Do not guess.') `
            -Detail ([ordered]@{ previous = $previous; candidates = @(Get-McpInstanceCandidates -Locks $Locks -PingTest $PingTest) })
    }

    return New-McpAmbiguousResult -Locks $Locks -PingTest $PingTest
}

function New-McpTargetResult
{
    param($Target = $null, [string]$Code = $null, [string]$Message = $null, $Detail = $null)

    if ([string]::IsNullOrEmpty($Code)) {
        $Code = $null
        $Message = $null
    }
    return [pscustomobject]@{ Target = $Target; Code = $Code; Message = $Message; Detail = $Detail }
}

function New-McpAmbiguousResult
{
    param([array]$Locks, [Parameter(Mandatory)][scriptblock]$PingTest)

    return New-McpTargetResult -Code 'creator.target_ambiguous' -Message (
        'Several MuLiN Creator windows are running and this call cannot tell which one is meant. ' +
        'Show the user the candidates (port and open project) and ask which one to use, then call ' +
        'use_creator_instance with that port and retry. Do not guess.') `
        -Detail ([ordered]@{ candidates = @(Get-McpInstanceCandidates -Locks $Locks -PingTest $PingTest) })
}

#endregion

#region Local protocol

# Kept in step with Creator's g_mcpProtocolSupported (McpServer.cpp) — the bridge now answers
# initialize itself, but the tools/call bodies it forwards are still Creator's to interpret.
$script:McpProtocolSupported = @('2025-03-26', '2025-06-18')
$script:McpProtocolLatest = '2025-06-18'

function Get-McpCatalogPath
{
    Join-Path (Split-Path -Parent $PSScriptRoot) 'catalog/tools.json'
}

<#
.SYNOPSIS
    Reads the bundled tool catalog without parsing the tools array.
.DESCRIPTION
    The catalog is a few hundred KB of descriptions and schemas, and Windows PowerShell 5.1's
    ConvertFrom-Json is slow enough on that to eat into the client's startup timeout. The file's
    contract is that "tools" is its last key, so the array text is cut out as-is and spliced into
    the tools/list response. Only creatorVersion is pulled out, from the part before the array.
#>
function Read-McpCatalog
{
    param([Parameter(Mandatory)][string]$Path)

    $fail = { param($why) [pscustomobject]@{ ToolsJson = '[]'; CreatorVersion = ''; Error = $why } }

    if (-not (Test-Path -LiteralPath $Path)) {
        return (& $fail "The bundled tool catalog is missing ($Path) — reinstall the plugin.")
    }
    try {
        $text = [IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        return (& $fail "The bundled tool catalog could not be read: $($_.Exception.Message)")
    }

    $key = $text.IndexOf('"tools":[')
    $end = $text.LastIndexOf(']')
    if (($key -lt 0) -or ($end -lt $key)) {
        return (& $fail 'The bundled tool catalog has no "tools" array — reinstall the plugin.')
    }
    $arrayStart = $key + '"tools":'.Length
    $toolsJson = $text.Substring($arrayStart, $end - $arrayStart + 1)

    $version = ''
    $match = [regex]::Match($text.Substring(0, $key), '"creatorVersion"\s*:\s*"([^"]*)"')
    if ($match.Success) {
        $version = $match.Groups[1].Value
    }
    return [pscustomobject]@{ ToolsJson = $toolsJson; CreatorVersion = $version; Error = $null }
}

<#
    What the model is told about this server, in its system prompt. Carries over the three
    working rules Creator's own initialize used to deliver (g_mcpInstructions) — the bridge
    answers initialize now, so those would otherwise be lost — plus the connection rules. Kept
    under 2,000 UTF-8 bytes; the client truncates beyond that (the tests measure it).
#>
function Get-McpServerInstructions
{
    return (
        'Remote control for MuLiN Creator, a PLC ladder IDE. ' +
        'Connection: this server always answers; the Creator window is found at call time. ' +
        'Check the connection with list_creator_instances, never by guessing. ' +
        'Never start MuLiN Creator yourself (no shell command, no launching the exe) — only the ' +
        'user starts it. Never tell the user to reconnect /mcp or restart this session to fix a ' +
        'connection problem; retry the same tool call instead. ' +
        'creator.not_running: ask the user to start MuLiN Creator and stop; do not work around it ' +
        'by editing files or using other tools; retry the same call once they say it is running. ' +
        'creator.target_ambiguous or creator.project_mismatch: show the user the candidates, ask ' +
        'which window or project to use, then call use_creator_instance with its port. ' +
        'creator.connection_lost: the result is unknown; query the state before sending anything again. ' +
        'creator.tool_unsupported: that Creator version lacks the tool; tell the user. ' +
        'Editing: ladder edits go through the open editor''s undo stack, so a person can undo them ' +
        'with Ctrl+Z; call open_page (for example "/pou/prg/<name>") before editing (reading does not ' +
        'need it). Use coordinates (n) and revision exactly as returned by get_ld_networks. ' +
        'A failed tool result (isError) carries an error code and what to do next; follow it.'
    )
}

function ConvertTo-McpIdJson
{
    param($Id)

    if ($null -eq $Id) {
        return 'null'
    }
    return ($Id | ConvertTo-Json -Compress)
}

function New-McpInitializeJson
{
    param($Id, [string]$RequestedVersion, [string]$PluginVersion)

    $negotiated = $script:McpProtocolLatest
    if ($script:McpProtocolSupported -contains $RequestedVersion) {
        $negotiated = $RequestedVersion
    }
    $response = [ordered]@{
        jsonrpc = '2.0'
        id      = $Id
        result  = [ordered]@{
            protocolVersion = $negotiated
            # tools is an empty object on purpose — listChanged is not declared, because the
            # tool list never changes within a session (the catalog is bundled).
            capabilities    = [ordered]@{ tools = [ordered]@{} }
            serverInfo      = [ordered]@{ name = 'mulin-creator'; version = $PluginVersion }
            instructions    = (Get-McpServerInstructions)
        }
    }
    return ($response | ConvertTo-Json -Depth 10 -Compress)
}

function New-McpToolsListJson
{
    param($Id, [Parameter(Mandatory)][string]$CatalogToolsJson)

    $extra = @(Get-McpBridgeExtraTools | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress }) -join ','
    $inner = $CatalogToolsJson.Trim()
    $inner = $inner.Substring(1, $inner.Length - 2).Trim()
    $items = $extra
    if ($inner -ne '') {
        $items = "$inner,$extra"
    }
    $items = $items -replace "`r", '' -replace "`n", ''
    return '{"jsonrpc":"2.0","id":' + (ConvertTo-McpIdJson $Id) + ',"result":{"tools":[' + $items + ']}}'
}

function New-McpRpcErrorJson
{
    param($Id, [Parameter(Mandatory)][int]$Code, [Parameter(Mandatory)][string]$Message)

    $response = [ordered]@{ jsonrpc = '2.0'; id = $Id; error = [ordered]@{ code = $Code; message = $Message } }
    return ($response | ConvertTo-Json -Depth 5 -Compress)
}

<#
    Creator answers a tools/call for a tool it does not have with JSON-RPC -32602 (McpServer.cpp)
    — the one place it uses that code. Does not depend on "code" being the first key inside the
    error object — a JSON object's member order is not guaranteed by the writer (PowerShell's own
    ConvertTo-Json over an unordered hashtable has been observed to emit "message" before "code"),
    so this matches "code" anywhere inside the error object's braces, not just right after "error":.
    Still requires unescaped quotes, so the same text inside a tool result (where quotes are
    escaped) does not match.
#>
function Test-McpUnknownToolResponse
{
    param([string]$Line)

    if ([string]::IsNullOrEmpty($Line)) {
        return $false
    }
    return [regex]::IsMatch($Line, '"error"\s*:\s*\{[^{}]*"code"\s*:\s*-32602\b')
}

#endregion

#region HTTP

<#
.SYNOPSIS
    Sends a ping to determine whether Creator is alive. Doing it this way instead of matching
    process ids avoids mistakenly connecting to a lock file left behind by a dead Creator.
#>
function Test-McpPing
{
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpClient]$HttpClient,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Token,
        [int]$TimeoutMilliseconds = 3000
    )

    try {
        $bodyBytes = [Text.Encoding]::UTF8.GetBytes('{"jsonrpc":"2.0","id":0,"method":"ping"}')
        $content = New-Object System.Net.Http.ByteArrayContent(, $bodyBytes)
        $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/json')

        $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $Url)
        $request.Content = $content
        $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Token)

        # The judgment itself must not wait long — session startup must not stall because one
        # unresponsive lock delays the selection step. This limit is not applied to the actual
        # request send (Send-McpBody) — cutting off a slow request is up to the client.
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter($TimeoutMilliseconds)

        $response = $HttpClient.SendAsync($request, $cts.Token).GetAwaiter().GetResult()
        return $response.IsSuccessStatusCode
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
    Builds a ping callback that checks a lock's process id before ever sending a ping, and
    remembers the answer for the rest of one call.
.DESCRIPTION
    One tools/call can ping the same port more than once — Resolve-McpTarget's own alive
    filter, then Get-McpInstanceCandidates again for a target_ambiguous/project_mismatch error
    detail, then once more on a connection-refused retry — and each ping against a closed port
    costs about two seconds on Windows (see Test-McpProcessAlive). Memoizing means that cost is
    paid at most once per port for the request being handled.

    The cache is deliberately scoped to a single call — the caller builds a fresh one for the
    next line read from stdin — because a lock that answered a moment ago can stop being true a
    moment later, and staleness carried across separate tool calls would be wrong, not just slow.
.OUTPUTS
    A pscustomobject with Test (the scriptblock to pass as -PingTest) and Cache (the backing
    hashtable, keyed by port) — Cache is exposed so the caller can force one port to "not
    alive" after a connection-refused retry, rather than trusting a cached "was alive a moment
    ago" answer for the immediate re-resolve.
#>
function New-McpMemoizingPingTest
{
    param([Parameter(Mandatory)][System.Net.Http.HttpClient]$HttpClient)

    $cache = @{}
    $test = {
        param($lock)
        $port = [int]$lock.port
        if ($cache.ContainsKey($port)) {
            return $cache[$port]
        }
        $alive = $false
        if (Test-McpProcessAlive -ProcessId ([int]$lock.pid)) {
            $alive = Test-McpPing -HttpClient $HttpClient -Url $lock.mcpUrl -Token $lock.token
        }
        $cache[$port] = $alive
        return $alive
    }.GetNewClosure()

    return [pscustomobject]@{ Test = $test; Cache = $cache }
}

<#
.SYNOPSIS
    Sends the UTF-8 bytes of a line received from the client as the HTTP body, unchanged.
.DESCRIPTION
    Does not rebuild the body — it just forwards the bytes it received. Sends only the
    authentication (Authorization) and Content-Type headers — since protocol negotiation
    happens directly between the client and Creator through the body, the bridge does not
    fake a negotiation it is not part of via headers.
#>
function Send-McpBody
{
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpClient]$HttpClient,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][byte[]]$BodyBytes,
        [int]$TimeoutMilliseconds = 0
    )

    $content = New-Object System.Net.Http.ByteArrayContent(, $BodyBytes)
    $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/json')

    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $Url)
    $request.Content = $content
    $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Token)

    <#
        -TimeoutMilliseconds is 0 (no timeout) by default — the caller also sets HttpClient.Timeout
        to infinite, because a tool that takes a long time (such as a build) does not respond
        within minutes, and how long to wait on an ordinary tools/call is up to the client, not
        this bridge. The one exception is forwarding notifications/cancelled: that send has no
        request id and nothing is waiting on its result, so a Creator that has hung must not be
        allowed to block the bridge's next line forever — the caller passes a short
        -TimeoutMilliseconds there instead.
    #>
    if ($TimeoutMilliseconds -gt 0) {
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter($TimeoutMilliseconds)
        $response = $HttpClient.SendAsync($request, $cts.Token).GetAwaiter().GetResult()
    } else {
        $response = $HttpClient.SendAsync($request).GetAwaiter().GetResult()
    }

    # The response is received as bytes and decoded as UTF-8 by the caller directly —
    # ReadAsByteArrayAsync does not corrupt Korean text whether or not the response states a
    # character encoding.
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()

    return [pscustomobject]@{
        StatusCode = [int]$response.StatusCode
        Bytes      = $bytes
    }
}

<#
.SYNOPSIS
    Determines whether a send failure is a "connection refused". Only connection-refused
    failures are retried; other failures such as timeouts are not — because a tool that
    changes something may already be running.
#>
function Test-IsConnectionRefused
{
    param($ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [System.Net.Sockets.SocketException]) {
            return ($exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionRefused)
        }
        $exception = $exception.InnerException
    }
    return $false
}

<#
.SYNOPSIS
    Produces the JSON-RPC error response (code -32001) the bridge builds on its own.
.DESCRIPTION
    This object is newly built, not a re-wrap of Creator's response. It is shallow and fixed
    in size, so there is no risk of content being truncated during serialization.
#>
function New-McpErrorJson
{
    param($Id, [Parameter(Mandatory)][string]$Message)

    $errorObject = [ordered]@{
        jsonrpc = '2.0'
        id      = $Id
        error   = [ordered]@{ code = -32001; message = $Message }
    }
    return ($errorObject | ConvertTo-Json -Depth 5 -Compress)
}

<#
.SYNOPSIS
    Decides, from the status code and body, the one line to write to the client (or nothing
    at all).
.DESCRIPTION
    Creator can emit errors in a shape that is not JSON-RPC (`{"error":{"code":...,
    "message":...}}`, with no jsonrpc/id). Passing that through as-is would be a protocol
    violation for the client, and the original request, which carries an id, would never get
    a response and would stay blocked until the client's own timeout runs out. So only
    non-2xx responses are touched by the bridge and turned into a JSON-RPC error, while
    normal responses (2xx) are carried through as-is (not rebuilt).
.PARAMETER StatusCode
    HTTP status code.
.PARAMETER BodyText
    The response body (a string already decoded as UTF-8). May contain line breaks.
.PARAMETER RequestId
    The id of the original request (used only when HasId is true).
.PARAMETER HasId
    Whether the original request had an id (false for a notification) — if false, there is
    no response to build and attach.
.OUTPUTS
    A pscustomobject holding only Line (the line to write to the client, $null if there is
    nothing to write).
#>
function Resolve-McpResponseLine
{
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [string]$BodyText,
        $RequestId,
        [bool]$HasId
    )

    if ($StatusCode -eq 202) {
        # A notification (no id) response — Creator receives it as 202 with no body. Write nothing.
        return [pscustomobject]@{ Line = $null }
    }

    # Transmission is line-based — if the response body contains line breaks, strip them so it
    # becomes one line.
    $text = $BodyText -replace "`r", '' -replace "`n", ''

    if (($StatusCode -ge 200) -and ($StatusCode -le 299)) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            # A successful response with no body — an empty line is not a protocol-level
            # message, so it is not forwarded, but if the request had an id, it is not left
            # without any response either — it is reported as an error.
            if ($HasId) {
                return [pscustomobject]@{
                    Line = (New-McpErrorJson -Id $RequestId `
                        -Message "MuLiN Creator sent a response with no body (HTTP $StatusCode).")
                }
            }
            return [pscustomobject]@{ Line = $null }
        }
        # Does not rebuild the body — just forwards the line it received.
        return [pscustomobject]@{ Line = $text }
    }

    # Not 2xx. If Creator already sent a JSON-RPC error (it has a jsonrpc field), pass it
    # through as-is — so that if Creator later starts sending proper JSON-RPC even on errors,
    # the bridge does not spoil it. Only reads it, never rewrites it, and checks via
    # PSObject.Properties first so it does not die on a missing property under StrictMode.
    $isJsonRpc = $false
    try {
        $parsedBody = $text | ConvertFrom-Json
        $isJsonRpc = ($null -ne $parsedBody) -and ($null -ne $parsedBody.PSObject.Properties['jsonrpc'])
    } catch {
        $isJsonRpc = $false
    }
    if ($isJsonRpc) {
        return [pscustomobject]@{ Line = $text }
    }

    if (-not $HasId) {
        # Does not build a response for a notification.
        return [pscustomobject]@{ Line = $null }
    }

    $bodyForMessage = $text
    if ([string]::IsNullOrWhiteSpace($bodyForMessage)) {
        $bodyForMessage = '(no body)'
    } elseif ($bodyForMessage.Length -gt 500) {
        # The body can be very long — truncate it so one error line does not flood the log.
        $bodyForMessage = $bodyForMessage.Substring(0, 500) + '…'
    }
    return [pscustomobject]@{
        Line = (New-McpErrorJson -Id $RequestId `
            -Message "MuLiN Creator rejected the request with HTTP ${StatusCode}: $bodyForMessage")
    }
}

#endregion

#region Bridge-handled tools

<#
.SYNOPSIS
    Builds the JSON-RPC success line for a tool this bridge answers on its own — never sent
    to Creator. Mirrors the {content, structuredContent, isError} shape Creator's own tool
    results use (McpServer.cpp's toolResultJson), so a client that only reads content/text
    sees the same shape it would from a server-answered tool.
#>
function New-McpToolResultJson
{
    param($Id, $Value)

    $text = ($Value | ConvertTo-Json -Depth 20 -Compress)
    $result = [ordered]@{
        content           = @([ordered]@{ type = 'text'; text = $text })
        structuredContent = $Value
        isError           = $false
    }
    $response = [ordered]@{ jsonrpc = '2.0'; id = $Id; result = $result }
    return ($response | ConvertTo-Json -Depth 20 -Compress)
}

<#
.SYNOPSIS
    Builds the JSON-RPC failure line for a tool this bridge answers on its own. Mirrors
    Creator's toolErrorJson shape (isError: true, with error.code/message/detail inside
    structuredContent) rather than the bridge's own protocol-level New-McpErrorJson — this is
    a tool failure the model can read and act on, not a transport failure.
#>
function New-McpToolErrorJson
{
    param($Id, [Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Message, $Detail = $null)

    $errorObject = [ordered]@{ code = $Code; message = $Message }
    if ($null -ne $Detail) {
        $errorObject.detail = $Detail
    }
    $payload = [ordered]@{ error = $errorObject }
    $text = ($payload | ConvertTo-Json -Depth 20 -Compress)
    $result = [ordered]@{
        content           = @([ordered]@{ type = 'text'; text = $text })
        structuredContent = $payload
        isError           = $true
    }
    $response = [ordered]@{ jsonrpc = '2.0'; id = $Id; result = $result }
    return ($response | ConvertTo-Json -Depth 20 -Compress)
}

<#
.SYNOPSIS
    The tool definitions for list_creator_instances and use_creator_instance, in the same
    shape Creator's own tools/list entries use (name/description/inputSchema). New-
    McpToolsListJson appends these to the bundled catalog.
#>
function Get-McpBridgeExtraTools
{
    return @(
        [ordered]@{
            name        = 'list_creator_instances'
            description = 'Shows how this session is connected to MuLiN Creator: the plugin ' +
                'version, the Creator version its tool list was taken from, the current target ' +
                'window, and every Creator window found (port, pid, open project, version, whether ' +
                'it answers). Use it whenever the connection is in doubt instead of guessing. A ' +
                'window stuck behind a dialog still appears (often with an empty projectPath) and ' +
                'can be targeted with use_creator_instance so list_dialogs / click_dialog_button ' +
                'can close it.'
            inputSchema = [ordered]@{
                type                 = 'object'
                properties           = [ordered]@{}
                additionalProperties = $false
            }
        },
        [ordered]@{
            name        = 'use_creator_instance'
            description = 'Makes the Creator window listening on the given port the target of ' +
                'this session, without restarting it. Call it after the user picks a window in ' +
                'answer to creator.target_ambiguous or creator.project_mismatch, or to reach a ' +
                'window found with list_creator_instances. Rejects a port with no lock file or no ' +
                'ping answer.'
            inputSchema = [ordered]@{
                type                 = 'object'
                properties           = [ordered]@{
                    port = [ordered]@{
                        type        = 'integer'
                        description = 'The port from list_creator_instances (or from the ' +
                            'candidates listed in a creator.target_ambiguous error) to pin to.'
                    }
                }
                required             = @('port')
                additionalProperties = $false
            }
        }
    )
}

<#
.SYNOPSIS
    Implements list_creator_instances as a pure function of the lock files, a ping callback,
    and the session's current target (if any) — kept separate from I/O so it can be tested
    without a real lock directory or HTTP.
#>
function Invoke-McpListCreatorInstancesTool
{
    param([array]$Locks, [Parameter(Mandatory)][scriptblock]$PingTest, $Current,
          [string]$PluginVersion = '', [string]$CatalogVersion = '')

    $instances = @(Get-McpInstanceCandidates -Locks $Locks -PingTest $PingTest | ForEach-Object {
        [ordered]@{
            port        = $_.port
            pid         = $_.pid
            projectPath = $_.projectPath
            version     = $_.version
            alive       = $_.alive
            current     = (Test-McpInstanceMatches $Current $_)
        }
    })
    $currentValue = $null
    if ($null -ne $Current) {
        $currentValue = [ordered]@{ port = [int]$Current.port; pid = [int]$Current.pid; projectPath = $Current.projectPath }
    }
    return [ordered]@{
        pluginVersion         = $PluginVersion
        catalogCreatorVersion = $CatalogVersion
        current               = $currentValue
        instances             = $instances
    }
}

<#
.SYNOPSIS
    Implements use_creator_instance — validates that Port has a lock file and answers a
    ping. Does not touch $instance itself; the caller updates the pin on success.
.OUTPUTS
    A pscustomobject with Ok, and either Instance (the chosen lock) or Message (why it was
    refused).
#>
function Invoke-McpUseCreatorInstanceTool
{
    param([array]$Locks, [Parameter(Mandatory)][scriptblock]$PingTest, [int]$Port)

    $matching = @($Locks | Where-Object { [int]$_.port -eq $Port })
    if ($matching.Count -eq 0) {
        return [pscustomobject]@{
            Ok      = $false
            Message = "No lock file for port $Port — check whether a MuLiN Creator is " +
                'running on that port (list_creator_instances shows every port this bridge ' +
                'can detect).'
        }
    }

    $candidate = $matching[0]
    if (-not (& $PingTest $candidate)) {
        return [pscustomobject]@{
            Ok      = $false
            Message = "Port $Port is not responding to a ping — the window may have " +
                'closed. Call list_creator_instances again to see current candidates.'
        }
    }

    return [pscustomobject]@{ Ok = $true; Instance = $candidate }
}

#endregion

#region Diagnostics (-Doctor)

<#
.SYNOPSIS
    Prints, in six items, whether it found a Creator to connect to, and if not, why. Does not
    act as a bridge.
#>
# The plugin's own version, read straight from its manifest. Derived from this script's
# location rather than $env:CLAUDE_PLUGIN_ROOT: that variable is expanded by the client when
# it builds the command line out of .mcp.json, and is not guaranteed to exist in the process
# environment. Diagnostics must never fail over a missing or malformed manifest, so anything
# unreadable reports as 'unknown' rather than throwing.
function Get-PluginVersion
{
    $manifest = Join-Path (Split-Path -Parent $PSScriptRoot) '.claude-plugin/plugin.json'
    if (-not (Test-Path -LiteralPath $manifest)) {
        return 'unknown'
    }
    try {
        $version = (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).version
    } catch {
        # -Version Latest turns a missing 'version' property into an exception too, so this
        # covers both unparsable JSON and a manifest without the field.
        return 'unknown'
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
        return 'unknown'
    }
    return $version
}

function Invoke-McpDoctor
{
    param(
        [int]$Port = 0,
        [string]$LockDirectory = (Get-McpLockDirectoryPath)
    )

    <#
        Pins stdout to UTF-8. Windows PowerShell sends redirected output through the console
        code page (CP949 on Korean Windows), which corrupts Korean text for anything reading
        it as UTF-8 (shell capture, log files). -Doctor is diagnostic text meant for a human,
        so pinning it here is safe — bridge mode takes a different path that never touches
        the console.
    #>
    [Console]::OutputEncoding = [Text.Encoding]::UTF8

    Write-Host '=== MuLiN MCP Bridge Diagnostics ===' -ForegroundColor Cyan
    Write-Host ''

    # Which plugin this bridge came out of. Read together with the Creator versions in
    # section 2, this is what tells whether the two are a matching set — CHANGELOG.md at the
    # repository root records which Creator each plugin release needs.
    Write-Host "Plugin: mulin-creator $(Get-PluginVersion)"
    $catalog = Read-McpCatalog -Path (Get-McpCatalogPath)
    Write-Host "Catalog: Creator $($catalog.CreatorVersion)"
    if ($null -ne $catalog.Error) {
        Write-Host "   $($catalog.Error)"
    }
    Write-Host ''

    # 1. Does the lock directory exist
    Write-Host '1. Lock directory' -ForegroundColor Yellow
    Write-Host "   $LockDirectory"
    $directoryExists = Test-Path -Path $LockDirectory
    if ($directoryExists) {
        Write-Host '   Exists'
    } else {
        Write-Host '   Does not exist — Creator may never have been started, or the MCP server may be off.'
    }
    Write-Host ''

    # 2. *.lock listing — port, pid, project, version, start time
    # Wrapped in @() — if there are 0 or 1 candidates, PowerShell returns $null or a scalar
    # instead of an array, and .Count access fails under StrictMode.
    $locks = @(Get-McpLockInfos -LockDirectory $LockDirectory)
    Write-Host "2. Lock file list ($($locks.Count) found)" -ForegroundColor Yellow
    if ($locks.Count -eq 0) {
        Write-Host '   None'
    } else {
        foreach ($lock in $locks) {
            Write-Host "   port $($lock.port) - pid $($lock.pid) - project '$($lock.projectPath)' - version $($lock.version) - started $($lock.startedAt)"
        }
    }
    Write-Host ''

    $httpClient = New-Object System.Net.Http.HttpClient
    $httpClient.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan

    # 3. Ping each candidate — does it respond
    Write-Host '3. Ping response' -ForegroundColor Yellow
    $pingResults = @{}
    if ($locks.Count -eq 0) {
        Write-Host '   No targets'
    }
    foreach ($lock in $locks) {
        # The pid check is local and instant; a dead process never gets a ping at all (see
        # Test-McpProcessAlive) — most stale lock files are exactly this case.
        $alive = $false
        if (Test-McpProcessAlive -ProcessId ([int]$lock.pid)) {
            $alive = Test-McpPing -HttpClient $httpClient -Url $lock.mcpUrl -Token $lock.token
        }
        $pingResults[[int]$lock.port] = $alive
        $mark = 'no response'
        if ($alive) {
            $mark = 'responded'
        }
        Write-Host "   port $($lock.port): $mark"
    }
    Write-Host ''

    # 4. Is MULIN_MCP_PORT set
    Write-Host '4. Port specification' -ForegroundColor Yellow
    $portResolution = Resolve-McpPreferredPort -Port $Port
    if ($Port -ne 0) {
        Write-Host "   Specified via -Port: $Port"
    } elseif ($null -ne $portResolution.Error) {
        # Diagnostics do not stop here — report that the value is wrong and keep going with
        # automatic selection. A human needs to know that "the specification was ignored" too.
        Write-Host "   $($portResolution.Error)"
        Write-Host '   Ignoring the specification and falling back to automatic selection.'
    } elseif ($portResolution.Port -ne 0) {
        Write-Host "   Specified via the MULIN_MCP_PORT environment variable: $($portResolution.Port)"
    } else {
        Write-Host '   Not specified (automatic selection)'
    }
    Write-Host ''

    # 5. Where a tools/call would go right now
    $preferredPort = $portResolution.Port
    $pingTest = {
        param($lock)
        $key = [int]$lock.port
        if ($pingResults.ContainsKey($key)) {
            return $pingResults[$key]
        }
        return $false
    }
    $selection = Resolve-McpTarget -Locks $locks -PingTest $pingTest -Current $null `
        -ToolName 'get_creator_status' -PinnedPort $preferredPort

    Write-Host '5. Target resolution' -ForegroundColor Yellow
    if ($null -ne $selection.Target) {
        Write-Host "   Choosing port $($selection.Target.port) (pid $($selection.Target.pid))."
    } elseif ($null -ne $selection.Code) {
        Write-Host "   $($selection.Message)"
    }
    Write-Host ''

    # 6. One line on what to do next
    Write-Host '6. Next step' -ForegroundColor Yellow
    if ($null -ne $selection.Target) {
        Write-Host '   Ready — tool calls go to this window. Nothing to do.'
    } elseif ($selection.Code -eq 'creator.not_running') {
        Write-Host '   Start MuLiN Creator. The session does not need to be restarted — the next tool call connects.'
    } else {
        Write-Host '   Several windows — the AI asks which one to use. To fix one for good, set MULIN_MCP_PORT.'
    }
}

#endregion

#region Bridge body

<#
.SYNOPSIS
    The bridge body. Answers initialize/tools/list/ping itself, immediately, and resolves a
    target Creator window fresh for every tools/call — never waits for or exits over a
    missing Creator (design §4).
#>
function Start-McpBridgeLoop
{
    param([int]$Port = 0)

    <#
        None of stdin, stdout, or stderr pass through the console code page. A UTF-8 (no BOM)
        StreamReader/StreamWriter is laid directly over OpenStandardInput/Output/Error, with
        AutoFlush turned on. [Console]::InputEncoding assignment is not used — it throws on
        some hosts when the input is a pipe.
    #>
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $utf8NoBom)
    $writer = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8NoBom)
    $errWriter = New-Object System.IO.StreamWriter([Console]::OpenStandardError(), $utf8NoBom)
    $writer.AutoFlush = $true
    $errWriter.AutoFlush = $true

    <#
        The line terminator is pinned to LF — StreamWriter's Windows default is CRLF. Since
        MCP separates messages only by line breaks, a leftover CR can look like a stray byte
        stuck after the JSON, depending on the client. LF is kept because it is safe for any
        client.
    #>
    $writer.NewLine = "`n"
    $errWriter.NewLine = "`n"

    $httpClient = New-Object System.Net.Http.HttpClient
    $httpClient.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan

    <#
        A bad -Port / MULIN_MCP_PORT is reported, but the bridge does not exit — an exit is
        recorded by the client as "failed to connect" and cached, so the session would have no
        tools at all. The typo is ignored and automatic resolution is used instead.
    #>
    $portResolution = Resolve-McpPreferredPort -Port $Port
    if ($null -ne $portResolution.Error) {
        $errWriter.WriteLine("$($portResolution.Error) Ignoring it and choosing the Creator window automatically.")
    }
    $pinnedPort = $portResolution.Port
    $lockDirectory = Get-McpLockDirectoryPath
    $pluginVersion = Get-PluginVersion

    $catalog = Read-McpCatalog -Path (Get-McpCatalogPath)
    if ($null -ne $catalog.Error) {
        $errWriter.WriteLine($catalog.Error)
    }

    # The session's current target — the last Creator a tools/call succeeded against.
    $current = $null

    while ($null -ne ($line = $reader.ReadLine())) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $hasId = $false
        $requestId = $null
        try {
            # A fresh memoizing ping callback for this line only — never carried over to the
            # next one (see New-McpMemoizingPingTest). All of list_creator_instances,
            # use_creator_instance, and the tools/call resolution below share this single
            # instance, so a port already found dead or alive earlier in this same call is not
            # pinged again.
            $pingHarness = New-McpMemoizingPingTest -HttpClient $httpClient
            $pingTest = $pingHarness.Test

            $parsed = $null
            try {
                $parsed = $line | ConvertFrom-Json
            } catch {
                $writer.WriteLine((New-McpRpcErrorJson -Id $null -Code -32700 -Message 'Parse error: the line is not JSON.'))
                continue
            }
            if ($null -eq $parsed) {
                continue
            }

            $hasId = $null -ne $parsed.PSObject.Properties['id']
            $requestId = $null
            if ($hasId) {
                $requestId = $parsed.id
            }
            $rpcMethod = ''
            if ($null -ne $parsed.PSObject.Properties['method']) {
                $rpcMethod = [string]$parsed.method
            }
            $params = $null
            if ($null -ne $parsed.PSObject.Properties['params']) {
                $params = $parsed.params
            }

            # Notifications carry no id and get no answer. Only a cancellation is worth passing
            # on, and only to a Creator this session is already talking to.
            if (-not $hasId) {
                if (($rpcMethod -eq 'notifications/cancelled') -and ($null -ne $current) -and
                    (Test-McpProcessAlive -ProcessId ([int]$current.pid))) {
                    try {
                        <#
                            A short timeout, not the infinite one this bridge otherwise uses —
                            nothing is waiting on this send's result (a notification gets no
                            response either way), so a Creator that has hung must not be allowed
                            to block the next line read from stdin forever.
                        #>
                        Send-McpBody -HttpClient $httpClient -Url $current.mcpUrl -Token $current.token `
                            -BodyBytes ([Text.Encoding]::UTF8.GetBytes($line)) -TimeoutMilliseconds 2000 | Out-Null
                    } catch {
                        # Best effort — the call it cancels reports its own outcome.
                    }
                }
                continue
            }

            if ($rpcMethod -eq 'initialize') {
                $requested = ''
                if (($null -ne $params) -and ($null -ne $params.PSObject.Properties['protocolVersion'])) {
                    $requested = [string]$params.protocolVersion
                }
                $writer.WriteLine((New-McpInitializeJson -Id $requestId -RequestedVersion $requested -PluginVersion $pluginVersion))
                continue
            }
            if ($rpcMethod -eq 'ping') {
                $writer.WriteLine('{"jsonrpc":"2.0","id":' + (ConvertTo-McpIdJson $requestId) + ',"result":{}}')
                continue
            }
            if ($rpcMethod -eq 'tools/list') {
                $writer.WriteLine((New-McpToolsListJson -Id $requestId -CatalogToolsJson $catalog.ToolsJson))
                continue
            }
            if ($rpcMethod -ne 'tools/call') {
                $writer.WriteLine((New-McpRpcErrorJson -Id $requestId -Code -32601 -Message "Method not supported: $rpcMethod"))
                continue
            }

            $toolName = ''
            $toolArgs = $null
            if ($null -ne $params) {
                if ($null -ne $params.PSObject.Properties['name']) {
                    $toolName = [string]$params.name
                }
                if ($null -ne $params.PSObject.Properties['arguments']) {
                    $toolArgs = $params.arguments
                }
            }

            if ($toolName -eq 'list_creator_instances') {
                $value = Invoke-McpListCreatorInstancesTool -Locks @(Get-McpLockInfos -LockDirectory $lockDirectory) `
                    -PingTest $pingTest -Current $current -PluginVersion $pluginVersion -CatalogVersion $catalog.CreatorVersion
                $writer.WriteLine((New-McpToolResultJson -Id $requestId -Value $value))
                continue
            }

            if ($toolName -eq 'use_creator_instance') {
                $portArg = 0
                $havePort = $false
                if (($null -ne $toolArgs) -and ($null -ne $toolArgs.PSObject.Properties['port'])) {
                    $havePort = [int]::TryParse([string]$toolArgs.port, [ref]$portArg)
                }

                if (-not $havePort) {
                    if ($hasId) {
                        $writer.WriteLine((New-McpToolErrorJson -Id $requestId -Code 'params.invalid' `
                            -Message 'use_creator_instance requires an integer "port" argument — see list_creator_instances for the ports currently available.'))
                    }
                    continue
                }

                $outcome = Invoke-McpUseCreatorInstanceTool -Locks @(Get-McpLockInfos -LockDirectory $lockDirectory) `
                    -PingTest $pingTest -Port $portArg
                if ($outcome.Ok) {
                    $current = $outcome.Instance
                    if ($pinnedPort -ne 0) {
                        # A pin (-Port/MULIN_MCP_PORT) otherwise makes Resolve-McpTarget ignore
                        # $Current entirely, so use_creator_instance would silently do nothing —
                        # an explicit user choice made through this tool overrides the env/-Port
                        # pin for the rest of this session.
                        $pinnedPort = [int]$current.port
                    }
                    $writer.WriteLine((New-McpToolResultJson -Id $requestId -Value ([ordered]@{
                        current = [ordered]@{ port = [int]$current.port; pid = [int]$current.pid; projectPath = $current.projectPath }
                    })))
                } else {
                    $writer.WriteLine((New-McpToolErrorJson -Id $requestId -Code 'creator.instance_not_found' -Message $outcome.Message))
                }
                continue
            }

            $bodyBytes = [Text.Encoding]::UTF8.GetBytes($line)
            $resolution = $null
            $sendResult = $null
            $sendError = $null

            <#
                At most two attempts. The second happens only after connection-refused — the
                request never reached anyone, so re-resolving and sending again cannot apply
                anything twice. Any other failure is not retried: Creator may already be running
                the call.
            #>
            for ($attempt = 0; $attempt -lt 2; $attempt++) {
                $resolution = Resolve-McpTarget -Locks @(Get-McpLockInfos -LockDirectory $lockDirectory) `
                    -PingTest $pingTest -Current $current -ToolName $toolName -ToolArgs $toolArgs -PinnedPort $pinnedPort
                if ($null -eq $resolution.Target) {
                    break
                }
                $sendError = $null
                try {
                    $sendResult = Send-McpBody -HttpClient $httpClient -Url $resolution.Target.mcpUrl `
                        -Token $resolution.Target.token -BodyBytes $bodyBytes
                } catch {
                    $sendError = $_
                }
                if (($null -eq $sendError) -or (-not (Test-IsConnectionRefused $sendError))) {
                    break
                }
                # Connection refused — the port just failed, so it is not "alive" any more no
                # matter what the memoized cache says from a moment ago. Force it false so the
                # re-resolve above does not just replay the stale answer and pick it again.
                $pingHarness.Cache[[int]$resolution.Target.port] = $false
            }
            # The loop only reaches its natural end (attempt counted up to 2, not a break) when
            # both attempts were connection-refused — the request never reached Creator either
            # time, which reads very differently from "it reached Creator and then broke".
            $bothAttemptsRefused = ($attempt -ge 2) -and ($null -ne $sendError) -and (Test-IsConnectionRefused $sendError)

            if ($null -eq $resolution.Target) {
                $writer.WriteLine((New-McpToolErrorJson -Id $requestId -Code $resolution.Code -Message $resolution.Message -Detail $resolution.Detail))
                continue
            }

            $target = $resolution.Target
            if ($null -ne $sendError) {
                if ($bothAttemptsRefused) {
                    # Both attempts were connection-refused: the request never reached Creator at
                    # all (as opposed to reaching it and then the connection breaking), so nothing
                    # was applied — a plain retry is safe, not just a state query.
                    $writer.WriteLine((New-McpToolErrorJson -Id $requestId -Code 'creator.connection_lost' -Message (
                        "This call did not reach MuLiN Creator (port $($target.port), pid $($target.pid) refused the " +
                        'connection both times) — nothing was applied. Retry the same call.') `
                        -Detail ([ordered]@{ port = [int]$target.port; pid = [int]$target.pid; reason = $sendError.Exception.Message })))
                } else {
                    $writer.WriteLine((New-McpToolErrorJson -Id $requestId -Code 'creator.connection_lost' -Message (
                        "The connection to MuLiN Creator (port $($target.port), pid $($target.pid)) broke during this call, " +
                        'so whether it took effect is unknown. Query the current state (for example ' +
                        'get_creator_status or the matching get_* tool) before sending it again.') `
                        -Detail ([ordered]@{ port = [int]$target.port; pid = [int]$target.pid; reason = $sendError.Exception.Message })))
                }
                continue
            }

            $text = [Text.Encoding]::UTF8.GetString($sendResult.Bytes)
            $resolved = Resolve-McpResponseLine -StatusCode $sendResult.StatusCode -BodyText $text -RequestId $requestId -HasId $true

            if (Test-McpUnknownToolResponse $resolved.Line) {
                $windowVersion = ''
                if ($null -ne $target.PSObject.Properties['version']) {
                    $windowVersion = [string]$target.version
                }
                $writer.WriteLine((New-McpToolErrorJson -Id $requestId -Code 'creator.tool_unsupported' -Message (
                    "The MuLiN Creator this call went to (version $windowVersion) does not have the tool '$toolName'. " +
                    "This plugin's tool list was taken from Creator $($catalog.CreatorVersion). Tell the user; " +
                    'updating Creator (or using a plugin version that matches it) resolves it.') `
                    -Detail ([ordered]@{ tool = $toolName; creatorVersion = $windowVersion; catalogCreatorVersion = $catalog.CreatorVersion })))
                continue
            }

            <#
                The call reached Creator — that window is now the session's current target.
                $target is the lock as read BEFORE this call, so its projectPath can still be
                the project the window had open before an open_project/create_project call just
                changed it. Re-reading the lock directory now and matching by port and pid picks
                up that change immediately, instead of waiting for some later call to refresh it
                (spec §5: re-read the window's lock file on every successful tools/call). Falls
                back to $target itself if the lock cannot be found fresh (window closed between
                the response and this read).
            #>
            $freshAfterCall = @(Get-McpLockInfos -LockDirectory $lockDirectory)
            $refreshedCurrent = @($freshAfterCall | Where-Object { Test-McpInstanceMatches $target $_ }) | Select-Object -First 1
            if ($null -ne $refreshedCurrent) {
                $current = $refreshedCurrent
            } else {
                $current = $target
            }

            if ($null -ne $resolved.Line) {
                $writer.WriteLine($resolved.Line)
            }
        } catch {
            if ($hasId) {
                $writer.WriteLine((New-McpRpcErrorJson -Id $requestId -Code -32603 -Message "Bridge internal error: $($_.Exception.Message)"))
            }
            $errWriter.WriteLine($_.ScriptStackTrace)
        }
    }
}

#endregion

<#
    This only actually runs when the file is executed directly. When dot-sourced
    (`. Start-McpBridge.ps1`) just to load the functions above, nothing runs — if what
    follows ran then, it would wait on stdin or terminate the process.
#>
if ($MyInvocation.InvocationName -ne '.') {
    if ($Doctor) {
        Invoke-McpDoctor -Port $Port
        exit 0
    }
    Start-McpBridgeLoop -Port $Port
}
