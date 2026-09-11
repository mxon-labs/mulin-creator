<#
.SYNOPSIS
    Bridge that connects to MuLiN Creator's MCP server over stdio (standard input/output).

.DESCRIPTION
    Bridges between a client that talks to an MCP server only over stdio (such as Claude Code
    or Codex) and MuLiN Creator, which speaks HTTP. Since the port Creator uses can differ
    each time it runs, the bridge finds a running Creator on its own and connects to it.

    What it does is simple — it forwards a line sent by the client to Creator as-is, and
    returns Creator's response as one line, unchanged. If Creator rejects the request, it
    turns that into an error response the client can understand.

    Runs on Windows PowerShell 5.1, which ships with Windows by default — no need to
    install PowerShell 7 separately.

.PARAMETER Port
    Specifies the port of the Creator to connect to directly. If omitted, checks the
    `MULIN_MCP_PORT` environment variable, and if that is not set either, automatically
    finds a running Creator.
    Priority: -Port > MULIN_MCP_PORT > automatic selection.

.PARAMETER WaitSeconds
    How long the bridge waits, on the first request, for a Creator to appear when none is
    running yet. Defaults to 1800 (30 minutes), matching the startup timeout the plugin
    declares in .mcp.json. Set it to 0 to not wait at all.

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
    [int]$WaitSeconds = 1800,
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
    Creator tends to normalize paths with `/`, while PowerShell's working directory uses
    `\`. If the separators are not unified and case is not ignored (Windows paths are
    case-insensitive), the projectPath comparison would practically never match.
#>
function ConvertTo-ComparablePath
{
    param([string]$Path)

    if ([string]::IsNullOrEmpty($Path)) {
        return ''
    }
    return ($Path -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
}

<#
.SYNOPSIS
    Picks one Creator to connect to among several lock file candidates.
.DESCRIPTION
    Order:
      1) If PreferredPort is set, only look at that port's lock file (and whether it is
         alive too).
      2) Otherwise, if there is exactly one alive candidate (PingTest is true), pick it.
      3) If there are several, pick one only when exactly one has a projectPath matching
         WorkingDirectory.
      4) If it still cannot be decided, reject — enumerate the candidates and mention
         MULIN_MCP_PORT.
    Liveness (PingTest) is passed in by the caller — diagnostics (-Doctor) reuse ping results
    it already obtained, while the bridge sends a ping on the spot.
.PARAMETER Locks
    An array of lock file info (the shape Get-McpLockInfos returns). Objects carrying pid,
    port, token, projectPath, and so on.
.PARAMETER WorkingDirectory
    The current working directory — used for projectPath comparison when there are multiple
    candidates.
.PARAMETER PreferredPort
    The port given via -Port or MULIN_MCP_PORT. 0 means unspecified (automatic selection).
.PARAMETER PingTest
    A scriptblock that takes one lock object and returns $true if it is alive.
.OUTPUTS
    A pscustomobject holding Selected (the chosen lock object, $null if none could be chosen)
    and Reason (the rejection reason, $null if one was chosen).
#>
function Select-McpInstance
{
    param(
        [array]$Locks,
        [string]$WorkingDirectory,
        [int]$PreferredPort = 0,
        [Parameter(Mandatory)][scriptblock]$PingTest
    )

    $candidates = @($Locks)

    if ($PreferredPort -ne 0) {
        $pinned = @($candidates | Where-Object { [int]$_.port -eq $PreferredPort })
        if ($pinned.Count -eq 0) {
            return [pscustomobject]@{
                Selected = $null
                Reason   = "There is no lock file for the specified port ($PreferredPort) — check whether Creator is running on that port."
            }
        }
        if (-not (& $PingTest $pinned[0])) {
            return [pscustomobject]@{
                Selected = $null
                Reason   = "The specified port ($PreferredPort) is not responding (ping failed) — check whether Creator is running."
            }
        }
        return [pscustomobject]@{ Selected = $pinned[0]; Reason = $null }
    }

    $alive = @($candidates | Where-Object { & $PingTest $_ })

    if ($alive.Count -eq 0) {
        return [pscustomobject]@{
            Selected = $null
            Reason   = 'No MuLiN Creator is responding — start Creator and try again in a moment.'
        }
    }
    if ($alive.Count -eq 1) {
        return [pscustomobject]@{ Selected = $alive[0]; Reason = $null }
    }

    $here = ConvertTo-ComparablePath $WorkingDirectory
    $matched = @($alive | Where-Object {
        ($here -ne '') -and ((ConvertTo-ComparablePath $_.projectPath) -eq $here)
    })
    if ($matched.Count -eq 1) {
        return [pscustomobject]@{ Selected = $matched[0]; Reason = $null }
    }

    $list = ($alive | ForEach-Object { "port $($_.port) (pid $($_.pid), project '$($_.projectPath)')" }) -join ', '
    return [pscustomobject]@{
        Selected = $null
        Reason   = "Multiple MuLiN Creator instances are running, so one cannot be decided: $list — specify one with the MULIN_MCP_PORT environment variable or -Port."
    }
}

<#
.SYNOPSIS
    Repeats Select-McpInstance until a Creator to connect to appears, or the deadline passes.
.DESCRIPTION
    Exists because of what happens when there is no Creator at the moment the bridge starts.
    If the bridge exits there, the client records the server as "failed to connect" and does
    not launch the bridge again — so starting Creator afterwards changes nothing, and the
    tools stay missing for the rest of that session. And the first request is `initialize`,
    so answering it with an error leads to the same place. Waiting is the only way out.

    The clock, the sleep, and the selection attempt are all taken as callbacks. That keeps
    this function pure — the tests drive it without waiting a single real second, and
    without HTTP or lock files.
.PARAMETER SelectAttempt
    A scriptblock that tries once and returns a Select-McpInstance-shaped object
    (Selected / Reason).
.PARAMETER Sleep
    A scriptblock that takes seconds and waits that long.
.PARAMETER Now
    A scriptblock that returns the current time.
.PARAMETER DeadlineSeconds
    How long to keep trying. 0 means try once and return right away.
.PARAMETER PollSeconds
    How long to wait between attempts.
.PARAMETER OnWaitStart
    Called once with the rejection reason, the moment waiting begins. Optional — the bridge
    uses it to write one line to stderr saying why it is not connected yet. It is called
    once no matter how long the wait runs, so the same line does not bury the rest of stderr.
.OUTPUTS
    The same shape as Select-McpInstance. On a deadline overrun, Reason carries how long it
    waited along with the last rejection reason.
#>
function Wait-McpInstance
{
    param(
        [Parameter(Mandatory)][scriptblock]$SelectAttempt,
        [Parameter(Mandatory)][scriptblock]$Sleep,
        [Parameter(Mandatory)][scriptblock]$Now,
        [double]$DeadlineSeconds = 0,
        [double]$PollSeconds = 1,
        [scriptblock]$OnWaitStart = $null
    )

    $start = & $Now
    $result = & $SelectAttempt
    if ($null -ne $result.Selected) {
        return $result
    }

    $announced = $false
    while ((((& $Now) - $start).TotalSeconds) -lt $DeadlineSeconds) {
        if (-not $announced) {
            $announced = $true
            if ($null -ne $OnWaitStart) {
                & $OnWaitStart $result.Reason
            }
        }

        & $Sleep $PollSeconds

        $result = & $SelectAttempt
        if ($null -ne $result.Selected) {
            return $result
        }
    }

    $waited = [int]((((& $Now) - $start)).TotalSeconds)
    return [pscustomobject]@{
        Selected = $null
        Reason   = "Waited $waited seconds for MuLiN Creator without connecting — $($result.Reason)"
    }
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
    Pings every candidate and reports {port, pid, projectPath, alive} for each. This is the
    shape both list_creator_instances and the creator.instance_changed error detail use.
#>
function Get-McpInstanceCandidates
{
    param([array]$Locks, [Parameter(Mandatory)][scriptblock]$PingTest)

    return @($Locks | ForEach-Object {
        [pscustomobject]@{
            port        = [int]$_.port
            pid         = [int]$_.pid
            projectPath = $_.projectPath
            alive       = [bool](& $PingTest $_)
        }
    })
}

<#
.SYNOPSIS
    Decides what to do with a reselection made after a connection-refused retry, given the
    instance this session is pinned to (design §8.1, D10).
.DESCRIPTION
    Three outcomes:
      - 'reject'  — reselection itself found nothing to connect to. The caller falls back to
        its existing "could not reconnect" handling — nothing changes here.
      - 'retry'   — reselection landed on the exact instance (same port and pid) this session
        was already pinned to. That is a flaky connection, not a different window, so it is
        safe to resend the original request.
      - 'changed' — reselection found a *different* instance. The caller must not resend the
        original request to it. Previous/Candidates are exactly the creator.instance_changed
        error detail (design §8.1).
.PARAMETER Pinned
    The lock object this session is currently pinned to.
.PARAMETER Reselection
    A Select-McpInstance-shaped result ({Selected, Reason}) computed from FreshLocks.
.PARAMETER FreshLocks
    The lock files Reselection was computed from — reused here to build Candidates without
    reading the lock directory a second time.
.PARAMETER PingTest
    The same ping callback Select-McpInstance was given.
#>
function Resolve-McpPinnedReselection
{
    param(
        $Pinned,
        $Reselection,
        [array]$FreshLocks,
        [Parameter(Mandatory)][scriptblock]$PingTest
    )

    if ($null -eq $Reselection.Selected) {
        return [pscustomobject]@{ Action = 'reject' }
    }
    if (Test-McpInstanceMatches $Pinned $Reselection.Selected) {
        return [pscustomobject]@{ Action = 'retry'; Instance = $Reselection.Selected }
    }

    return [pscustomobject]@{
        Action     = 'changed'
        Previous   = [pscustomobject]@{ port = [int]$Pinned.port; pid = [int]$Pinned.pid; projectPath = $Pinned.projectPath }
        Candidates = Get-McpInstanceCandidates -Locks $FreshLocks -PingTest $PingTest
    }
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
        [Parameter(Mandatory)][byte[]]$BodyBytes
    )

    $content = New-Object System.Net.Http.ByteArrayContent(, $BodyBytes)
    $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/json')

    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $Url)
    $request.Content = $content
    $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Token)

    # No Timeout is set here (the caller sets HttpClient.Timeout to infinite) — a tool that
    # takes a long time, such as a build, does not respond within minutes. Cancellation is not
    # handled here — how long to wait is up to the client.
    $response = $HttpClient.SendAsync($request).GetAwaiter().GetResult()

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
    shape Creator's own tools/list entries use (name/description/inputSchema). Merge-
    McpBridgeToolsList appends these to Creator's own catalog (design §8.2, D11).
#>
function Get-McpBridgeExtraTools
{
    return @(
        [ordered]@{
            name        = 'list_creator_instances'
            description = 'Lists every MuLiN Creator instance this bridge can currently ' +
                'detect from its lock files: port, pid, open project path, and whether it ' +
                'answers a ping. The instance this bridge is pinned to is marked ' +
                'current: true. A window stuck behind a dialog (for example a crash-recovery ' +
                'prompt) still shows up here with an empty projectPath — that is how to find ' +
                'it and pin to it with use_creator_instance so list_dialogs / ' +
                'click_dialog_button can close it.'
            inputSchema = [ordered]@{
                type                 = 'object'
                properties           = [ordered]@{}
                additionalProperties = $false
            }
        },
        [ordered]@{
            name        = 'use_creator_instance'
            description = 'Re-pins this bridge to the MuLiN Creator instance listening on ' +
                'the given port, without restarting the client session. Call this after a ' +
                'creator.instance_changed error to confirm which instance to keep talking ' +
                'to, or to attach to a window found via list_creator_instances (including ' +
                'one with no open project). Rejects the port if there is no lock file for it ' +
                'or it does not answer a ping.'
            inputSchema = [ordered]@{
                type                 = 'object'
                properties           = [ordered]@{
                    port = [ordered]@{
                        type        = 'integer'
                        description = 'The port from list_creator_instances (or from the ' +
                            'candidates listed in a creator.instance_changed error) to pin to.'
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
    Appends Get-McpBridgeExtraTools to the tools array of a tools/list response line, leaving
    everything else in the line untouched.
.DESCRIPTION
    This is the one response the bridge rebuilds instead of forwarding byte-for-byte (design
    §8.2) — the two tools this bridge answers on its own must appear in the catalog for a
    caller to find them. Every other response, tools/call results in particular, is still
    carried through unchanged; Send-McpBody's doc comment on why is unaffected by this.

    If the line does not parse as JSON, or does not have the {result:{tools:[...]}} shape (an
    error response, for instance), it is returned unchanged — only a recognizable successful
    tools/list body is touched.
#>
function Merge-McpBridgeToolsList
{
    param([string]$Line)

    if ([string]::IsNullOrEmpty($Line)) {
        return $Line
    }

    try {
        $parsed = $Line | ConvertFrom-Json
    } catch {
        return $Line
    }

    $hasTools = ($null -ne $parsed) -and
                ($null -ne $parsed.PSObject.Properties['result']) -and
                ($null -ne $parsed.result.PSObject.Properties['tools'])
    if (-not $hasTools) {
        return $Line
    }

    $parsed.result.tools = @($parsed.result.tools) + (Get-McpBridgeExtraTools)
    return ($parsed | ConvertTo-Json -Depth 40 -Compress)
}

<#
.SYNOPSIS
    Implements list_creator_instances as a pure function of the lock files, a ping callback,
    and the currently pinned instance (if any) — kept separate from I/O so it can be tested
    without a real lock directory or HTTP.
#>
function Invoke-McpListCreatorInstancesTool
{
    param([array]$Locks, [Parameter(Mandatory)][scriptblock]$PingTest, $Pinned)

    $instances = @(Get-McpInstanceCandidates -Locks $Locks -PingTest $PingTest | ForEach-Object {
        [ordered]@{
            port        = $_.port
            pid         = $_.pid
            projectPath = $_.projectPath
            alive       = $_.alive
            current     = (Test-McpInstanceMatches $Pinned $_)
        }
    })
    return [ordered]@{ instances = $instances }
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
        $alive = Test-McpPing -HttpClient $httpClient -Url $lock.mcpUrl -Token $lock.token
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

    # 5. Which Creator would be chosen, and why
    $preferredPort = $portResolution.Port
    $workingDirectory = (Get-Location).Path
    $pingTest = {
        param($lock)
        $key = [int]$lock.port
        if ($pingResults.ContainsKey($key)) {
            return $pingResults[$key]
        }
        return $false
    }
    $selection = Select-McpInstance -Locks $locks -WorkingDirectory $workingDirectory `
        -PreferredPort $preferredPort -PingTest $pingTest

    Write-Host '5. Selection result' -ForegroundColor Yellow
    Write-Host "   Working directory: $workingDirectory"
    if ($null -ne $selection.Selected) {
        Write-Host "   Choosing port $($selection.Selected.port) (pid $($selection.Selected.pid))."
    } else {
        Write-Host "   Could not choose — $($selection.Reason)"
    }
    Write-Host ''

    # 6. If it could not choose, one line on what to do next
    $aliveCount = 0
    foreach ($lock in $locks) {
        $key = [int]$lock.port
        if ($pingResults.ContainsKey($key) -and $pingResults[$key]) {
            $aliveCount++
        }
    }

    Write-Host '6. Next step' -ForegroundColor Yellow
    if ($null -ne $selection.Selected) {
        Write-Host '   Ready to connect.'
        Write-Host '   If you turned Creator off and back on during the session, you do not need to do anything — the next tool call reconnects on its own.'
        Write-Host '   If the tools still do not show up, a client with an /mcp panel (claude in a terminal) should Reconnect there,'
        Write-Host '   and a client without /mcp (such as the Code tab in the desktop app) should start a new session.'
    } elseif ((-not $directoryExists) -or ($locks.Count -eq 0) -or ($aliveCount -eq 0)) {
        # There is no lock file at all, or none of them respond — since there is no living
        # candidate at all, saying "there are several, so it cannot choose" would be a wrong
        # diagnosis.
        Write-Host '   Start Creator. If it is already running, check whether the MCP server is on and whether the lock file is stale.'
    } elseif ($preferredPort -ne 0) {
        Write-Host '   The specified port is not responding — double-check the port number, or clear the specification and try automatic selection.'
    } else {
        Write-Host '   Multiple Creator instances are running — specify which one to connect to with the MULIN_MCP_PORT environment variable or -Port.'
    }
}

#endregion

#region Bridge body

<#
.SYNOPSIS
    The bridge body. Attaches to a Creator on the first request — waiting for one to appear
    if none is running yet — then forwards each line sent by the client to Creator one at a
    time, in the order received.
#>
function Start-McpBridgeLoop
{
    param([int]$Port = 0, [int]$WaitSeconds = 1800)

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

    $portResolution = Resolve-McpPreferredPort -Port $Port
    if ($null -ne $portResolution.Error) {
        # This is a human typo — better to say what is wrong and stop than to connect to the
        # wrong window.
        $errWriter.WriteLine($portResolution.Error)
        exit 1
    }
    $preferredPort = $portResolution.Port
    $workingDirectory = (Get-Location).Path
    $lockDirectory = Get-McpLockDirectoryPath

    $pingTest = { param($lock) Test-McpPing -HttpClient $httpClient -Url $lock.mcpUrl -Token $lock.token }

    $selectAttempt = {
        $locks = @(Get-McpLockInfos -LockDirectory $lockDirectory)
        Select-McpInstance -Locks $locks -WorkingDirectory $workingDirectory `
            -PreferredPort $preferredPort -PingTest $pingTest
    }

    <#
        Nothing is chosen here, and the bridge never exits over a missing Creator. People do
        start the client first and Creator second; exiting at that point makes the client
        record the server as "failed to connect" and stop launching the bridge, so starting
        Creator afterwards changes nothing for the rest of that session. Selection is put off
        until the first request arrives, and waits there instead.
    #>
    $instance = $null

    while ($null -ne ($line = $reader.ReadLine())) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        <#
            Only the id is read from the request line via ConvertFrom-Json — needed to attach
            to an error response. The body itself is just the UTF-8 bytes of this line sent
            as-is, never rebuilt.
        #>
        $parsedOk = $true
        $parsed = $null
        try {
            $parsed = $line | ConvertFrom-Json
        } catch {
            $parsedOk = $false
        }

        $hasId = $parsedOk -and ($null -ne $parsed) -and ($null -ne $parsed.PSObject.Properties['id'])
        $requestId = $null
        if ($hasId) {
            $requestId = $parsed.id
        }

        $rpcMethod = $null
        if ($parsedOk -and ($null -ne $parsed) -and ($null -ne $parsed.PSObject.Properties['method'])) {
            $rpcMethod = $parsed.method
        }

        <#
            list_creator_instances and use_creator_instance never reach Creator — they read
            or change $instance (the pinned target) directly, right here, before Creator is
            even attached to. This is what breaks the F-21 deadlock: a window stuck behind a
            recovery dialog can be pinned to by port without waiting for automatic selection
            to succeed first (design §8.2, D11).
        #>
        $toolName = $null
        $toolArgs = $null
        if ($rpcMethod -eq 'tools/call') {
            $callParams = $null
            if (($null -ne $parsed) -and ($null -ne $parsed.PSObject.Properties['params'])) {
                $callParams = $parsed.params
            }
            if ($null -ne $callParams) {
                if ($null -ne $callParams.PSObject.Properties['name']) {
                    $toolName = $callParams.name
                }
                if ($null -ne $callParams.PSObject.Properties['arguments']) {
                    $toolArgs = $callParams.arguments
                }
            }
        }

        if ($toolName -eq 'list_creator_instances') {
            $freshLocks = @(Get-McpLockInfos -LockDirectory $lockDirectory)
            $value = Invoke-McpListCreatorInstancesTool -Locks $freshLocks -PingTest $pingTest -Pinned $instance
            if ($hasId) {
                $writer.WriteLine((New-McpToolResultJson -Id $requestId -Value $value))
            }
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

            $freshLocks = @(Get-McpLockInfos -LockDirectory $lockDirectory)
            $outcome = Invoke-McpUseCreatorInstanceTool -Locks $freshLocks -PingTest $pingTest -Port $portArg
            if ($outcome.Ok) {
                $instance = $outcome.Instance
                $value = [ordered]@{
                    pinned = [ordered]@{
                        port        = [int]$instance.port
                        pid         = [int]$instance.pid
                        projectPath = $instance.projectPath
                    }
                }
                if ($hasId) {
                    $writer.WriteLine((New-McpToolResultJson -Id $requestId -Value $value))
                }
            } else {
                if ($hasId) {
                    $writer.WriteLine((New-McpToolErrorJson -Id $requestId -Code 'creator.instance_not_found' -Message $outcome.Message))
                }
            }
            continue
        }

        $bodyBytes = [Text.Encoding]::UTF8.GetBytes($line)

        <#
            Not attached yet — this is the first request, which is `initialize`. Answering it
            with an error puts the client in the same place as exiting would, so it waits for
            a Creator to appear instead. Only the first attach waits; once attached, a later
            failure is reported as an error and the next request retries (see below).
        #>
        if ($null -eq $instance) {
            $attach = Wait-McpInstance -SelectAttempt $selectAttempt `
                -Sleep { param([double]$seconds) Start-Sleep -Seconds $seconds } `
                -Now { Get-Date } `
                -DeadlineSeconds $WaitSeconds -PollSeconds 1 `
                -OnWaitStart {
                    param([string]$reason)
                    $errWriter.WriteLine("Waiting up to $WaitSeconds seconds for MuLiN Creator to start — $reason")
                }

            if ($null -eq $attach.Selected) {
                if ($hasId) {
                    $writer.WriteLine((New-McpErrorJson -Id $requestId `
                        -Message "Could not connect to MuLiN Creator: $($attach.Reason)"))
                }
                continue
            }
            $instance = $attach.Selected
        }

        $sendResult = $null
        $sendError = $null
        try {
            $sendResult = Send-McpBody -HttpClient $httpClient -Url $instance.mcpUrl -Token $instance.token -BodyBytes $bodyBytes
        } catch {
            $sendError = $_
        }

        if ($null -ne $sendError) {
            if (Test-IsConnectionRefused $sendError) {
                <#
                    Only connection-refused is retried — the lock files are reread and a
                    Creator to connect to is chosen once more. This is where restarting
                    Creator with a different port quietly recovers. Other failures such as
                    timeouts are not retried — sending a tool twice when Creator has already
                    received it and is running could apply the same edit twice.
                #>
                $freshLocks = @(Get-McpLockInfos -LockDirectory $lockDirectory)
                $reselection = Select-McpInstance -Locks $freshLocks -WorkingDirectory $workingDirectory `
                    -PreferredPort $preferredPort -PingTest $pingTest

                <#
                    Reselecting is not enough by itself — it must also be checked against the
                    instance this session is pinned to (Resolve-McpPinnedReselection, design
                    §8.1, D10). Silently resending the original request body to a different
                    window than the one that went away is exactly the bug this pin closes
                    (F-20).
                #>
                $decision = Resolve-McpPinnedReselection -Pinned $instance -Reselection $reselection `
                    -FreshLocks $freshLocks -PingTest $pingTest

                if ($decision.Action -eq 'retry') {
                    $instance = $decision.Instance
                    $sendError = $null
                    try {
                        $sendResult = Send-McpBody -HttpClient $httpClient -Url $instance.mcpUrl -Token $instance.token -BodyBytes $bodyBytes
                    } catch {
                        $sendError = $_
                    }
                } elseif ($decision.Action -eq 'changed') {
                    <#
                        A different instance answered than the one this session was pinned
                        to. The original request is not resent to it — the pin is left as it
                        was (not updated to the new instance), so the next request hits the
                        same dead pin and reports the same error again, until the caller
                        resolves it with use_creator_instance.
                    #>
                    if ($hasId) {
                        $writer.WriteLine((New-McpToolErrorJson -Id $requestId -Code 'creator.instance_changed' -Message (
                            "The MuLiN Creator instance this session was talking to (port $($decision.Previous.port), " +
                            "pid $($decision.Previous.pid)) is gone, and a different instance answered in its place. " +
                            'This request was not resent to it. Call use_creator_instance with the port of the ' +
                            'instance you want to keep talking to (see the candidates in this error, or call ' +
                            'list_creator_instances) before retrying.'
                        ) -Detail ([ordered]@{ previous = $decision.Previous; candidates = $decision.Candidates })))
                    }
                    continue
                }
                # $decision.Action -eq 'reject' — reselection itself failed too; falls through
                # to the generic "could not reconnect" handling below, unchanged from before.
            }
        }

        if ($null -ne $sendError) {
            # Even the retry failed (or it was not a retry target). The bridge does not die
            # and stays running — the next request can reconnect.
            if ($hasId) {
                $writer.WriteLine((New-McpErrorJson -Id $requestId `
                    -Message "Could not reconnect to MuLiN Creator: $($sendError.Exception.Message)"))
            }
            continue
        }

        <#
            Status code judgment and stripping line breaks is handled by
            Resolve-McpResponseLine — 202 (notification response) writes nothing, and
            anything not 2xx turns Creator's error body into a JSON-RPC error.
        #>
        $text = [Text.Encoding]::UTF8.GetString($sendResult.Bytes)
        $resolved = Resolve-McpResponseLine -StatusCode $sendResult.StatusCode -BodyText $text `
            -RequestId $requestId -HasId $hasId

        <#
            tools/list is the one response this bridge rebuilds instead of forwarding as-is —
            the two tools it answers on its own (list_creator_instances, use_creator_instance)
            must show up in the catalog for the caller to find them. Everything else (in
            particular tools/call results) is still carried through byte-for-byte, unchanged.
        #>
        if ($rpcMethod -eq 'tools/list') {
            $resolved = [pscustomobject]@{ Line = (Merge-McpBridgeToolsList -Line $resolved.Line) }
        }

        if ($null -ne $resolved.Line) {
            $writer.WriteLine($resolved.Line)
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
    Start-McpBridgeLoop -Port $Port -WaitSeconds $WaitSeconds
}
