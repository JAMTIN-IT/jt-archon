# =============================================================================
# archon.ps1 - launcher for Archon Portable (Windows PowerShell)
# macOS / Linux / WSL / Git Bash users: use ./archon with the same commands.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$EnvFile  = '.env'
$AuthFile = 'caddy/auth.conf'

# caddy/auth.conf holds a credential, so it is gitignored and absent from a
# fresh clone. Docker would silently create a DIRECTORY at that mount path,
# so materialise it from the tracked example before anything touches it.
if (-not (Test-Path $AuthFile) -and (Test-Path "$AuthFile.example")) {
    Copy-Item "$AuthFile.example" $AuthFile
}

# --- output ------------------------------------------------------------------
function Write-Ok   { param($m) Write-Host "OK  " -ForegroundColor Green -NoNewline; Write-Host $m }
function Write-Warn { param($m) Write-Host "!   " -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Write-Bad  { param($m) Write-Host "X   " -ForegroundColor Red -NoNewline; Write-Host $m }
function Write-Dim  { param($m) Write-Host $m -ForegroundColor DarkGray }
function Die        { param($m) Write-Bad $m; exit 1 }

# --- native commands ----------------------------------------------------------
function Test-Have { param($n) return [bool](Get-Command $n -ErrorAction SilentlyContinue) }

# Windows PowerShell 5.1 wraps ANY stderr line from a native .exe in a
# NativeCommandError record. With $ErrorActionPreference = 'Stop' that kills the
# script even when the program exited 0 - a single Docker warning on stderr
# (e.g. DOCKER_INSECURE_NO_IPTABLES_RAW) would abort every command. So all
# native calls run with the preference relaxed and are judged on $LASTEXITCODE.

# Runs a native command with its output visible. Returns the exit code.
function Invoke-Native {
    param([string]$Exe, [string[]]$NativeArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Exe @NativeArgs; return $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
}

# Runs a native command silently. Returns the exit code.
function Invoke-NativeQuiet {
    param([string]$Exe, [string[]]$NativeArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Exe @NativeArgs 2>&1 | Out-Null; return $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
}

# Runs a native command and returns its stdout as a trimmed string.
function Get-NativeOutput {
    param([string]$Exe, [string[]]$NativeArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return ((& $Exe @NativeArgs 2>$null | Out-String).Trim()) }
    finally { $ErrorActionPreference = $prev }
}

function Invoke-Compose {
    param([string[]]$ComposeArgs)
    $code = Invoke-Native 'docker' (@('compose') + $ComposeArgs)
    if ($code -ne 0) { exit $code }
}

function Require-Docker {
    if (-not (Test-Have docker)) {
        Die "docker is not installed or not on PATH. Install Docker Desktop: https://docs.docker.com/desktop/install/windows-install/"
    }
    if ((Invoke-NativeQuiet 'docker' @('info')) -ne 0) {
        Die "The Docker daemon is not reachable. Start Docker Desktop and retry."
    }
}

# --- .env helpers ------------------------------------------------------------
function Require-EnvFile {
    if (-not (Test-Path $EnvFile)) { Die "No .env yet. Run '.\archon.ps1 init' first." }
}

function Get-EnvValue {
    param([string]$Key)
    if (-not (Test-Path $EnvFile)) { return '' }
    $line = Get-Content $EnvFile | Where-Object { $_ -match "^\s*$([regex]::Escape($Key))=" } | Select-Object -Last 1
    if (-not $line) { return '' }
    $v = ($line -split '=', 2)[1]
    return $v.Trim().Trim('"').Trim("'")
}

# Writes UTF-8 without a BOM - Docker Compose mis-parses a BOM on the first key.
function Write-TextFile {
    param([string]$Path, [string[]]$Lines)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        (Join-Path $PSScriptRoot $Path),
        (($Lines -join "`n") + "`n"),
        $enc)
}

function Set-EnvValue {
    param([string]$Key, [string]$Value)
    $lines = @(Get-Content $EnvFile)
    $pattern = "^\s*#?\s*$([regex]::Escape($Key))="
    $done = $false
    $out = foreach ($l in $lines) {
        if (-not $done -and $l -match $pattern) { $done = $true; "$Key=$Value" }
        else { $l }
    }
    if (-not $done) { $out = $out + "$Key=$Value" }
    Write-TextFile -Path $EnvFile -Lines $out
}

# --- mode --------------------------------------------------------------------
$script:ModeOverride = ''

function Get-CurrentMode {
    if ($script:ModeOverride) { return $script:ModeOverride }
    $p = Get-EnvValue 'COMPOSE_PROFILES'
    if ($p) { return $p }
    return 'local'
}
function Test-Mode { param($n) return ((Get-CurrentMode) -split ',' | ForEach-Object { $_.Trim() }) -contains $n }

# Every profile at once. Used by down/ps/logs/restart so a stack started in one
# mode is still fully seen (and fully torn down) from another.
function Invoke-ComposeAll {
    param([string[]]$ComposeArgs)
    Invoke-Compose (@('--profile','local','--profile','lan','--profile','public','--profile','db') + $ComposeArgs)
}

function Invoke-ComposeProfiles {
    param([string[]]$ComposeArgs)
    $pre = @()
    foreach ($p in ((Get-CurrentMode) -split ',')) {
        $p = $p.Trim()
        if ($p) { $pre += @('--profile', $p) }
    }
    if ($script:ModeOverride) { $env:COMPOSE_PROFILES = $script:ModeOverride }
    Invoke-Compose ($pre + $ComposeArgs)
}

# --- network -----------------------------------------------------------------
function Get-LanIPs {
    try {
        return @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
            Select-Object -ExpandProperty IPAddress -Unique)
    } catch {
        return @((Get-NativeOutput 'ipconfig' @()) -split "`n" | Select-String 'IPv4 Address' |
            ForEach-Object { ($_ -split ':')[1].Trim() } |
            Where-Object { $_ -notmatch '^(127\.|169\.254\.)' })
    }
}

# --- commands ----------------------------------------------------------------

function Cmd-Init {
    if (Test-Path $EnvFile) { Write-Warn ".env already exists - leaving it alone." }
    else { Copy-Item '.env.example' $EnvFile; Write-Ok "Created .env from .env.example" }
    if (-not (Test-Path $AuthFile)) { Die "caddy/auth.conf.example is missing - re-clone the repo." }
    Write-Host ""
    Write-Host "Next:"
    Write-Host "  1. .\archon.ps1 auth claude    give Archon your Claude credentials"
    Write-Host "  2. .\archon.ps1 auth github    (optional) reuse your gh login"
    Write-Host "  3. edit .env                   set GITHUB_ALLOWED_USERS and the mode"
    Write-Host "  4. .\archon.ps1 up             start it"
}

# Archon expands $VAR only inside an MCP config's `headers` and `env` - never
# inside `url` (packages/providers/src/mcp/config.ts has no url branch). So a
# query parameter like Supabase's project_ref cannot be a $VAR: it would reach
# the server as the literal string and fail as a confusing 4xx that reads like
# a bad token. Rather than make you maintain the ref inside a committed JSON
# file, render the URL here from .env into a gitignored *.local.json.
#
# The token deliberately stays a $VAR. It lives in `headers`, which Archon does
# expand at run time, so no secret is ever written to a file on disk.
#
# No comment marker inside the JSON: Archon reads every top-level key as a
# server name, so a "_generated" note would fail validation as a server whose
# config is a string.
function Render-McpLocal {
    if (-not (Test-Path $EnvFile)) { return }

    $ref = Get-EnvValue 'SUPABASE_PROJECT_REF'
    $query = 'read_only=true'
    if ((Get-EnvValue 'SUPABASE_READ_ONLY') -eq 'false') { $query = '' }
    if ($ref) {
        if ($query) { $query = "project_ref=$ref&$query" } else { $query = "project_ref=$ref" }
    }

    $url = 'https://mcp.supabase.com/mcp'
    if ($query) { $url = "$url`?$query" }

    Write-TextFile -Path 'mcp/supabase.local.json' -Lines @(
        '{',
        '  "supabase": {',
        '    "type": "http",',
        "    ""url"": ""$url"",",
        '    "headers": {',
        '      "Authorization": "Bearer $SUPABASE_ACCESS_TOKEN"',
        '    }',
        '  }',
        '}'
    )
}

function Cmd-Up {
    Require-Docker; Require-EnvFile
    if (-not (Get-EnvValue 'CLAUDE_CODE_OAUTH_TOKEN') -and -not (Get-EnvValue 'CLAUDE_API_KEY')) {
        Die "No Claude credentials. Run '.\archon.ps1 auth claude' (or set CLAUDE_API_KEY in .env)."
    }
    if (Test-Mode 'public') {
        $d = Get-EnvValue 'DOMAIN'
        if (-not $d -or $d -eq 'archon.example.com') {
            Die "public mode needs a real DOMAIN in .env, with its DNS A record pointing here."
        }
    }
    if ((Test-Mode 'lan') -or (Test-Mode 'public')) {
        if (-not (Select-String -Path $AuthFile -Pattern '^\s*basic_auth' -Quiet -ErrorAction SilentlyContinue)) {
            Write-Warn "No password set - anyone who can reach this machine gets full control of your agent."
            Write-Warn "Fix with: .\archon.ps1 password 'some-strong-password'"
        }
    }
    # Persist the mode so down/logs/status/doctor all act on what is really
    # running. Without this, `.\archon.ps1 down` after `.\archon.ps1 up lan`
    # would leave the gateway container behind.
    if ($script:ModeOverride -and $script:ModeOverride -ne (Get-EnvValue 'COMPOSE_PROFILES')) {
        Set-EnvValue 'COMPOSE_PROFILES' $script:ModeOverride
        Write-Dim "mode: $(Get-CurrentMode)  (saved to .env)"
    } else {
        Write-Dim "mode: $(Get-CurrentMode)"
    }
    Render-McpLocal
    Invoke-ComposeProfiles @('up', '-d', '--remove-orphans')
    Write-Host ""
    Cmd-Ip
}

function Cmd-Ip {
    Require-EnvFile
    $port = Get-EnvValue 'PORT';     if (-not $port) { $port = '3000' }
    $lanp = Get-EnvValue 'LAN_PORT'; if (-not $lanp) { $lanp = '8080' }

    Write-Host "Web UI" -ForegroundColor White
    Write-Host "  this machine   " -NoNewline; Write-Host "http://localhost:$port" -ForegroundColor Cyan

    if (Test-Mode 'lan') {
        $bind = Get-EnvValue 'LAN_BIND'
        if ($bind -and $bind -ne '0.0.0.0') {
            Write-Host "  teammates      " -NoNewline
            Write-Host "http://${bind}:$lanp" -ForegroundColor Cyan -NoNewline
            Write-Dim "  (pinned via LAN_BIND)"
        } else {
            $ips = Get-LanIPs
            if ($ips.Count -gt 0) {
                foreach ($ip in $ips) {
                    Write-Host "  teammates      " -NoNewline
                    Write-Host "http://${ip}:$lanp" -ForegroundColor Cyan
                }
            } else {
                Write-Dim "  teammates      http://<this-machine-ip>:$lanp (could not detect an IP)"
            }
            Write-Dim "  Pin one of these as LAN_BIND in .env for a fixed address,"
            Write-Dim "  and reserve it for this machine in your router's DHCP settings."
        }
    }
    if (Test-Mode 'public') {
        Write-Host "  teammates      " -NoNewline
        Write-Host "https://$(Get-EnvValue 'DOMAIN')" -ForegroundColor Cyan
    }
    if (-not (Test-Mode 'lan') -and -not (Test-Mode 'public')) {
        Write-Dim "  Mode is 'local' - nobody else can reach this."
        Write-Dim "  Share it with: .\archon.ps1 up lan"
    }
}

function Convert-ToContainerPath {
    param([string]$HostPath)
    $root = Get-EnvValue 'PROJECTS_DIR'
    if (-not $root) {
        Die "PROJECTS_DIR is not set in .env - set it to the folder that holds your repos, then .\archon.ps1 restart"
    }
    # Normalise backslashes, drive-letter case and trailing slashes so
    # C:\DEV-KC\app\, C:/dev-kc/app and c:/DEV-KC/app all match.
    # .Replace() and not -replace: the latter takes a regex, in which a lone
    # backslash is an invalid pattern.
    $n = $HostPath.Replace([char]92, '/').ToLower().TrimEnd('/')
    $r = $root.Replace([char]92, '/').ToLower().TrimEnd('/')
    if ($n -eq $r) { return '/projects' }
    if ($n.StartsWith("$r/")) { return '/projects/' + $n.Substring($r.Length + 1) }
    Write-Warn "'$HostPath' is not inside PROJECTS_DIR ($root)."
    Write-Warn "Either move it there, or point PROJECTS_DIR at a parent folder of both."
    exit 1
}

# Translate a host path into the container path Archon needs. Nothing in the
# UI can find a host path, so this is the answer to "Path does not exist".
function Cmd-Path {
    Require-EnvFile
    if ($Rest.Count -lt 1 -or -not $Rest[0]) { Die "Usage: .\archon.ps1 path <host-path-to-your-repo>" }
    Write-Host (Convert-ToContainerPath $Rest[0])
}

function Cmd-Projects {
    Require-EnvFile
    $root = Get-EnvValue 'PROJECTS_DIR'
    if (-not $root) {
        Write-Warn "PROJECTS_DIR is not set in .env - no host code is visible to Archon."
        Write-Dim "Set it to the folder holding your repos, then .\archon.ps1 restart"
        return
    }
    Write-Host "Host $root  ->  container /projects"
    Write-Host ""
    if (-not (Test-Path $root)) {
        Write-Warn "$root does not exist on this machine."
        return
    }
    # Listed from the host, so this works whether or not the stack is running.
    $dirs = @(Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue)
    if ($dirs.Count -eq 0) { Write-Dim "  (no folders in $root)"; return }
    Write-Host "Use these paths when adding a codebase in the Web UI:"
    foreach ($d in $dirs) {
        $tag = if (Test-Path (Join-Path $d.FullName '.git')) { '   (git repo)' } else { '' }
        Write-Host "  /projects/$($d.Name)$tag"
    }
}

# Prove an MCP server is usable from a workflow node, rather than merely
# reachable. Runs Archon's own config loader plus a real MCP handshake inside
# the container, so the network namespace, the .env expansion and the JSON
# parsing are all the ones a node actually gets. See mcp/_verify.ts.
function Cmd-Mcp {
    Require-Docker
    if ($Rest.Count -lt 1) {
        Die "Usage: .\archon.ps1 mcp <name|path> [tool] [json-args]   (e.g. mcp figma-remote)"
    }
    $name = $Rest[0]
    $rest = @(); if ($Rest.Count -gt 1) { $rest = $Rest[1..($Rest.Count - 1)] }

    # A bare name is a file in mcp/, which the compose file mounts read-only at
    # /opt/archon-mcp. Anything with a slash is passed through untouched so a
    # per-repo config (/projects/app/.archon/mcp.json) also works.
    if ($name -like '*/*') {
        $path = $name
    } else {
        # Prefer the tracked <name>.json, then a generated <name>.local.json, so
        # `mcp supabase` finds the rendered config without the suffix.
        $base = $name -replace '\.json$', ''
        if (Test-Path "mcp/$base.json") {
            $path = "/opt/archon-mcp/$base.json"
        } elseif (Test-Path "mcp/$base.local.json") {
            $path = "/opt/archon-mcp/$base.local.json"
        } else {
            $path = "/opt/archon-mcp/$base.json"
        }
    }

    $running = @((Get-NativeOutput 'docker' @('compose', 'ps', '--status', 'running', '--services')) -split "`n" |
                ForEach-Object { $_.Trim() })
    if ($running -notcontains 'app') {
        Die "Archon is not running. Start it with .\archon.ps1 up, then retry."
    }

    Invoke-ComposeProfiles (@('exec', '-T', 'app', 'bun', '/opt/archon-mcp/_verify.ts', $path) + $rest)
}

# Install a shared skill from skills/ into a project's .claude/skills/.
#
# Project-local is the only skill root Archon searches in every execution mode:
# a node running under container isolation skips the user-global root entirely,
# and the server runs as appuser (not root), so "just mount it into a home
# directory" resolves differently depending on how the node was launched.
# Copying into the repo also means the skill is committed and the whole team
# gets it, which is how Claude skills are meant to be shared.
function Cmd-Skill {
    if ($Rest.Count -lt 1) {
        Die "Usage: .\archon.ps1 skill <project> [skill-name]   (project = folder under PROJECTS_DIR, or an absolute path)"
    }
    $target = $Rest[0]
    $name = if ($Rest.Count -gt 1) { $Rest[1] } else { '' }

    if (Test-Path -PathType Container $target) {
        $root = $target
    } else {
        $base = Get-EnvValue 'PROJECTS_DIR'
        if (-not $base) { Die "PROJECTS_DIR is not set in .env, so '$target' cannot be resolved." }
        $root = Join-Path $base $target
        if (-not (Test-Path -PathType Container $root)) { Die "No such project: $root" }
    }

    $dest = Join-Path $root '.claude/skills'
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Force $dest | Out-Null }

    $n = 0
    foreach ($src in (Get-ChildItem -Directory 'skills' -ErrorAction SilentlyContinue)) {
        if ($name -and $src.Name -ne $name) { continue }
        if (-not (Test-Path (Join-Path $src.FullName 'SKILL.md'))) {
            Write-Warn "skipping $($src.Name) - no SKILL.md"; continue
        }
        $to = Join-Path $dest $src.Name
        if (Test-Path $to) { Remove-Item -Recurse -Force $to }
        Copy-Item -Recurse $src.FullName $to
        Write-Ok "$($src.Name) -> $to"
        $n++
    }

    if ($n -eq 0) { Die "No skill copied. Check the name against: $((Get-ChildItem -Directory 'skills').Name -join ', ')" }
    Write-Host ""
    $label = if ($name) { $name } else { '<name>' }
    Write-Dim "Reference it from a node as:  skills: [$label]"
    Write-Dim "Commit .claude/skills/ so your team gets it too."
}

function Cmd-Auth {
    Require-EnvFile
    $what = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    switch ($what) {
        'claude' {
            if (-not (Test-Have claude)) {
                Die "Claude Code is not installed on this machine.
Install it (irm https://claude.ai/install.ps1 | iex), or paste a key into .env
manually: CLAUDE_API_KEY=sk-ant-... from console.anthropic.com/settings/keys"
            }
            Write-Host "Running 'claude setup-token' - approve in the browser when prompted."
            Write-Dim "This mints a long-lived token billed to your Claude subscription."
            Write-Host ""
            $out = Get-NativeOutput 'claude' @('setup-token')
            $m = [regex]::Matches($out, 'sk-ant-[A-Za-z0-9_\-]+')
            if ($m.Count -eq 0) {
                Die "Could not read a token from 'claude setup-token'. Run it yourself and paste the value into CLAUDE_CODE_OAUTH_TOKEN in .env."
            }
            $token = $m[$m.Count - 1].Value
            Set-EnvValue 'CLAUDE_CODE_OAUTH_TOKEN' $token
            Write-Ok "Wrote CLAUDE_CODE_OAUTH_TOKEN to .env ($($token.Substring(0,14))...)"
            Write-Dim "Apply it with: .\archon.ps1 restart"
        }
        'github' {
            if (-not (Test-Have gh)) {
                Die "The GitHub CLI is not installed. Get it from https://cli.github.com/, or paste a token into GH_TOKEN and GITHUB_TOKEN in .env."
            }
            $token = Get-NativeOutput 'gh' @('auth', 'token')
            if (-not $token) { Die "Not logged in. Run 'gh auth login' first." }
            Set-EnvValue 'GH_TOKEN' $token
            Set-EnvValue 'GITHUB_TOKEN' $token
            Write-Ok "Wrote GH_TOKEN and GITHUB_TOKEN to .env"
            $me = Get-NativeOutput 'gh' @('api', 'user', '--jq', '.login')
            if ($me -and -not (Get-EnvValue 'GITHUB_ALLOWED_USERS')) {
                Set-EnvValue 'GITHUB_ALLOWED_USERS' $me
                Write-Ok "Set GITHUB_ALLOWED_USERS=$me - add teammates as a comma-separated list."
            }
            Write-Dim "Apply it with: .\archon.ps1 restart"
        }
        default { Die "Usage: .\archon.ps1 auth claude | github" }
    }
}

function Cmd-Password {
    Require-Docker
    if ($Rest.Count -lt 1 -or -not $Rest[0]) {
        Die "Usage: .\archon.ps1 password '<password>' [username]   (default username: team)"
    }
    $pw = $Rest[0]
    $user = if ($Rest.Count -gt 1) { $Rest[1] } else { 'team' }
    $hash = Get-NativeOutput 'docker' @('run', '--rm', 'caddy:2-alpine', 'caddy', 'hash-password', '--plaintext', $pw)
    if (-not $hash) { Die "Failed to generate a password hash." }
    Write-TextFile -Path $AuthFile -Lines @(
        "# Archon Web UI password gate - imported by both Caddyfiles.",
        "# GENERATED by '.\archon.ps1 password'. Do not hand-edit; re-run the command instead.",
        "#",
        "# Username: $user",
        "# The value below is a bcrypt hash, not a plaintext password - but it is still",
        "# a credential. Do not commit this file to a public repository.",
        "",
        "@protected not path /webhooks/* /api/health /internal/*",
        "basic_auth @protected {",
        "`t$user $hash",
        "}"
    )
    Write-Ok "Password set for user '$user'"
    # Reload only the gateway that is actually up, so this works in any mode.
    $running = @((Get-NativeOutput 'docker' @('compose',
        '--profile','local','--profile','lan','--profile','public','--profile','db',
        'ps','--services','--filter','status=running')) -split "`n" |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -like 'caddy-*' })
    if ($running.Count -gt 0) {
        Invoke-ComposeAll (@('restart') + $running)
        Write-Ok "Gateway reloaded"
    } else {
        Write-Dim "Takes effect on the next .\archon.ps1 up"
    }
}

function Cmd-NoPassword {
    Write-TextFile -Path $AuthFile -Lines @(
        "# Archon Web UI password gate - imported by both Caddyfiles.",
        "#",
        "# This file is EMPTY, which means NO PASSWORD is required.",
        "# Generate a real gate with:  .\archon.ps1 password '<password>'"
    )
    Write-Warn "Password removed - the Web UI is now open to anyone who can reach it."
}

function Cmd-Secret {
    $kind = if ($Rest.Count -gt 0) { $Rest[0] } else { 'b64' }
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    if ($kind -eq 'hex') { Write-Host (($bytes | ForEach-Object { $_.ToString('x2') }) -join '') }
    else { Write-Host ([Convert]::ToBase64String($bytes)) }
}

function Cmd-Build {
    Require-Docker; Require-EnvFile
    if (-not (Test-Path 'Dockerfile.user')) { Die "Dockerfile.user is missing - re-clone the repo." }
    # Only the image NAME changes; ARCHON_VERSION keeps naming the upstream
    # release it is built from, so running this twice stays correct.
    $v = Get-EnvValue 'ARCHON_VERSION'; if (-not $v) { $v = 'latest' }
    if ($v -eq 'local') { $v = 'latest'; Set-EnvValue 'ARCHON_VERSION' 'latest' }
    Write-Host "Building archon-portable:$v on ghcr.io/coleam00/archon:$v (adds Node LTS for npx-based MCP servers)..."
    $code = Invoke-Native 'docker' @('build', '-f', 'Dockerfile.user', '-t', "archon-portable:$v",
                                     '--build-arg', "ARCHON_VERSION=$v", '.')
    if ($code -ne 0) { exit $code }
    Set-EnvValue 'ARCHON_IMAGE' 'archon-portable'
    Write-Ok "Built archon-portable:$v and pointed .env at it."
    Write-Dim "Start it with: .\archon.ps1 up"
    Write-Dim "Rebuild after an upstream release with: .\archon.ps1 build"
    Write-Dim "Go back to the stock image by setting ARCHON_IMAGE=ghcr.io/coleam00/archon in .env."
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Windows only. Opens the LAN gateway port through the Windows firewall so
# teammates can actually connect. Needs an elevated PowerShell.
function Cmd-AllowLan {
    Require-EnvFile
    $port = Get-EnvValue 'LAN_PORT'; if (-not $port) { $port = '8080' }

    if (-not (Test-Admin)) {
        Write-Bad "This needs an elevated shell."
        Write-Host "  Right-click PowerShell -> Run as administrator, then re-run:"
        Write-Host "      cd '$PSScriptRoot'; .\archon.ps1 allow-lan"
        exit 1
    }

    New-NetFirewallRule -DisplayName "Archon Web UI (LAN) $port" `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port `
        -Profile Private -ErrorAction SilentlyContinue | Out-Null
    Write-Ok "Windows Defender: allowed inbound TCP $port on private networks"

    # WSL's "mirrored" networking mode puts Docker Desktop's published ports in
    # a separate Hyper-V firewall namespace that the rule above does not cover.
    # Without a matching Hyper-V rule the port listens on the LAN address but
    # every inbound connection is dropped.
    $wslConf = Join-Path $env:USERPROFILE '.wslconfig'
    $mirrored = (Test-Path $wslConf) -and
                ((Get-Content $wslConf -Raw) -match '(?im)^\s*networkingMode\s*=\s*mirrored')
    if ($mirrored) {
        Write-Dim "WSL networkingMode=mirrored detected - adding the Hyper-V rule too."
        $wslCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
        try {
            New-NetFirewallHyperVRule -Name "Archon-LAN-$port" `
                -DisplayName "Archon Web UI (LAN) $port" `
                -Direction Inbound -Action Allow -Protocol TCP -LocalPorts $port `
                -VMCreatorId $wslCreatorId -ErrorAction Stop | Out-Null
            Write-Ok "Hyper-V firewall: allowed inbound TCP $port to the WSL namespace"
        } catch {
            Write-Warn "Could not add the Hyper-V rule: $($_.Exception.Message)"
            Write-Dim  "Add it by hand, or set networkingMode=NAT in $wslConf and restart WSL."
        }
        Write-Dim "Note: in mirrored mode this machine cannot reach its own LAN IP."
        Write-Dim "Test from a teammate's machine, not this one."
    }

    Write-Host ""
    Cmd-Ip
}

function Cmd-Doctor {
    $fail = $false
    Write-Host "Archon Portable - preflight" -ForegroundColor White
    Write-Host ""

    if ((Test-Have docker) -and (Invoke-NativeQuiet 'docker' @('info')) -eq 0) {
        Write-Ok "Docker daemon reachable ($(Get-NativeOutput 'docker' @('version', '--format', '{{.Server.Version}}')))"
    } else { Write-Bad "Docker daemon not reachable"; $fail = $true }

    if ((Invoke-NativeQuiet 'docker' @('compose', 'version')) -eq 0) { Write-Ok "Docker Compose available" }
    else { Write-Bad "Docker Compose missing"; $fail = $true }

    if (Test-Path $EnvFile) { Write-Ok ".env present" }
    else { Write-Bad ".env missing - run .\archon.ps1 init"; $fail = $true }

    if (Test-Path $EnvFile) {
        if (Get-EnvValue 'CLAUDE_CODE_OAUTH_TOKEN') { Write-Ok "Claude: OAuth token set (subscription billing)" }
        elseif (Get-EnvValue 'CLAUDE_API_KEY') { Write-Ok "Claude: API key set (metered billing)" }
        else { Write-Bad "Claude: no credentials - run .\archon.ps1 auth claude"; $fail = $true }

        if ((Get-EnvValue 'CLAUDE_USE_GLOBAL_AUTH') -eq 'true') {
            Write-Warn "CLAUDE_USE_GLOBAL_AUTH=true has no effect in Docker - remove it to avoid confusion."
        }

        if (Get-EnvValue 'GH_TOKEN') {
            $allow = Get-EnvValue 'GITHUB_ALLOWED_USERS'
            if ($allow) { Write-Ok "GitHub: PAT set, restricted to [$allow]" }
            else { Write-Warn "GitHub: PAT set but GITHUB_ALLOWED_USERS is empty - ANY GitHub user can trigger workflows." }
        }
        if (Get-EnvValue 'GITHUB_APP_ID') {
            if (Get-EnvValue 'GH_TOKEN') {
                Write-Bad "GitHub: both PAT and App mode configured - Archon will refuse to start. Pick one."; $fail = $true
            }
            if ((Get-EnvValue 'ARCHON_ALLOW_INTERNAL_ON_PUBLIC_BIND') -ne '1') {
                Write-Bad "GitHub App mode needs ARCHON_ALLOW_INTERNAL_ON_PUBLIC_BIND=1 in this stack (see .env comments)."; $fail = $true
            }
        }

        Write-Ok "Mode: $(Get-CurrentMode)"
        if ((Test-Mode 'lan') -or (Test-Mode 'public')) {
            if (Select-String -Path $AuthFile -Pattern '^\s*basic_auth' -Quiet -ErrorAction SilentlyContinue) {
                Write-Ok "Web UI password gate: enabled"
            } else {
                Write-Warn "Web UI password gate: OFF while exposing the UI - run .\archon.ps1 password '<password>'"
            }
        }
        if (Test-Mode 'public') {
            $d = Get-EnvValue 'DOMAIN'
            if ($d -and $d -ne 'archon.example.com') { Write-Ok "DOMAIN: $d" }
            else { Write-Bad "public mode requires a real DOMAIN in .env"; $fail = $true }
        }
        if (Test-Mode 'lan') {
            $wslConf = Join-Path $env:USERPROFILE '.wslconfig'
            if ((Test-Path $wslConf) -and ((Get-Content $wslConf -Raw) -match '(?im)^\s*networkingMode\s*=\s*mirrored')) {
                Write-Warn "WSL networkingMode=mirrored: teammates are blocked until you run '.\archon.ps1 allow-lan' from an elevated shell."
            }
        }
        $pdir = Get-EnvValue 'PROJECTS_DIR'
        if (-not $pdir) {
            Write-Warn "PROJECTS_DIR is unset - Archon cannot see any code on this machine. Adding a local codebase will fail with 'Path does not exist'."
        } elseif (Test-Path $pdir) {
            Write-Ok "Local code: $pdir -> /projects"
        } else {
            Write-Bad "PROJECTS_DIR points at '$pdir', which does not exist on this machine."; $fail = $true
        }

        if ((Get-EnvValue 'ARCHON_APP_BIND') -eq '0.0.0.0') {
            Write-Warn "ARCHON_APP_BIND=0.0.0.0 publishes Archon to the network with NO authentication. Use lan mode instead."
        }
    }

    if ((Invoke-NativeQuiet 'docker' @('compose', 'config', '-q')) -eq 0) { Write-Ok "docker-compose.yml is valid" }
    else { Write-Bad "docker-compose.yml failed validation - run: docker compose config"; $fail = $true }

    Write-Host ""
    if ($fail) { Die "Fix the items above, then re-run .\archon.ps1 doctor" }
    Write-Ok "Ready. Start with .\archon.ps1 up"
}

function Cmd-Help {
    Write-Host @"
Archon Portable - a fully configured Archon on any machine with Docker.

Setup
  .\archon.ps1 init                    create .env from the template
  .\archon.ps1 auth claude             mint a Claude token and store it in .env
  .\archon.ps1 auth github             copy your gh CLI token into .env
  .\archon.ps1 password '<pw>' [user]  set the Web UI password (default user: team)
  .\archon.ps1 nopassword              remove the Web UI password
  .\archon.ps1 secret [hex]            print a random secret for WEBHOOK_SECRET etc.
  .\archon.ps1 doctor                  check the configuration before starting

Run
  .\archon.ps1 up [mode]               start (mode: local | lan | public, +,db)
  .\archon.ps1 down                    stop, keeping all data
  .\archon.ps1 down -v                 stop and DELETE all data
  .\archon.ps1 restart [service]       restart
  .\archon.ps1 status                  container status
  .\archon.ps1 logs [service]          follow logs
  .\archon.ps1 update                  pull a newer Archon image and recreate
  .\archon.ps1 ip                      show the URLs to share with teammates

Inside the container
  .\archon.ps1 shell                   interactive bash
  .\archon.ps1 mcp <name> [tool]       verify an MCP server: handshake + list tools
  .\archon.ps1 exec <cmd...>           run one command
  .\archon.ps1 build                   rebuild the image with Node LTS added

Modes
  local    Web UI on 127.0.0.1 only. The default.
  lan      Web UI on your LAN IP behind a password (LAN_PORT, default 8080).
  public   Web UI on DOMAIN with automatic HTTPS.
  Add ,db for PostgreSQL, e.g. .\archon.ps1 up lan,db

Configuration lives in .env; the mode is COMPOSE_PROFILES there.
"@
}

# --- dispatch ----------------------------------------------------------------
switch ($Command) {
    'up' {
        if ($Rest.Count -gt 0 -and ($Rest[0] -in @('local', 'lan', 'public', 'db') -or $Rest[0] -like '*,*')) {
            $script:ModeOverride = $Rest[0]
            $Rest = @($Rest | Select-Object -Skip 1)
        }
        Cmd-Up
    }
    'init'       { Cmd-Init }
    'down'       { Require-Docker; Invoke-ComposeAll (@('down', '--remove-orphans') + $Rest) }
    'restart'    { Require-Docker; Require-EnvFile; Render-McpLocal; Invoke-ComposeProfiles (@('up', '-d', '--force-recreate', '--remove-orphans') + $Rest) }
    { $_ -in 'status', 'ps' } { Require-Docker; Invoke-ComposeAll @('ps') }
    'logs'       { Require-Docker; Invoke-ComposeAll (@('logs', '-f', '--tail=100') + $Rest) }
    { $_ -in 'update', 'upgrade' } {
        Require-Docker; Require-EnvFile
        Invoke-ComposeProfiles @('pull')
        Invoke-ComposeProfiles @('up', '-d', '--remove-orphans')
        Write-Ok "Updated. Data in the archon_data volume is untouched."
    }
    { $_ -in 'ip', 'url', 'urls' } { Cmd-Ip }
    { $_ -in 'shell', 'bash', 'sh' } { Require-Docker; Invoke-ComposeProfiles @('exec', 'app', 'bash') }
    'exec'       { Require-Docker; Invoke-ComposeProfiles (@('exec', 'app') + $Rest) }
    'mcp'        { Cmd-Mcp }
    'skill'      { Cmd-Skill }
    'skills'     { Cmd-Skill }
    'path'       { Cmd-Path }
    'projects'   { Cmd-Projects }
    'auth'       { Cmd-Auth }
    { $_ -in 'password', 'passwd' } { Cmd-Password }
    'nopassword' { Cmd-NoPassword }
    'secret'     { Cmd-Secret }
    'build'      { Cmd-Build }
    { $_ -in 'allow-lan', 'allowlan' } { Cmd-AllowLan }
    { $_ -in 'doctor', 'check' } { Cmd-Doctor }
    default      { Cmd-Help }
}
