# MCP 传输层冒烟（真机）：负向用例 + initialize / tools/list / status。
#
# 只做只读/协议级检查，不修改保险库数据。未提供密钥时跳过已认证用例。
# 退出码：0 = 全部通过；1 = 有失败/连接错误。
param(
    [string]$KeyFile = '',
    [int]$TimeoutSeconds = 20,
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'easypass-ui-probe' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$reportFile = Join-Path $OutDir 'mcp_smoke.json'

$base = 'http://127.0.0.1:47821/mcp'
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
$results = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$name, [int]$status, [string]$detail, [bool]$pass, [string]$body = '') {
    $results.Add([pscustomobject]@{ name = $name; status = $status; pass = $pass; detail = $detail; bodyPreview = $body })
}

function Invoke-Mcp([string]$body, [hashtable]$extraHeaders = @{}, [string]$method = 'POST', [switch]$noAuth) {
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($method), $base)
    if ($method -eq 'POST') {
        $req.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
    }
    if (-not $noAuth -and $script:auth) {
        $req.Headers.TryAddWithoutValidation('Authorization', $script:auth) | Out-Null
    }
    $req.Headers.TryAddWithoutValidation('Accept', 'application/json, text/event-stream') | Out-Null
    foreach ($k in $extraHeaders.Keys) {
        if ($k -eq 'Host') { $req.Headers.Host = $extraHeaders[$k] }
        else { $req.Headers.TryAddWithoutValidation($k, $extraHeaders[$k]) | Out-Null }
    }
    try {
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{
            Status = [int]$resp.StatusCode
            Body = [System.Text.Encoding]::UTF8.GetString($bytes)
            Headers = $resp.Headers
        }
    } catch {
        return [pscustomobject]@{ Status = -1; Body = $_.Exception.Message; Headers = $null }
    }
}

# ── 密钥（可选）─────────────────────────────────────────────
$script:auth = $null
if (-not $KeyFile) {
    $KeyFile = Join-Path $env:USERPROFILE '.dsh\profiles\desktop\cordis.patch.yml'
}
if (Test-Path $KeyFile) {
    $config = Get-Content $KeyFile -Raw
    $m = [regex]::Match($config, 'Authorization:\s*"Bearer\s+([A-Za-z0-9]+)"')
    if (-not $m.Success) { $m = [regex]::Match($config, 'Authorization:\s*"([^"]+)"') }
    if ($m.Success) {
        $key = $m.Groups[1].Value.Trim()
        $script:auth = if ($key.StartsWith('Bearer ')) { $key } else { "Bearer $key" }
    }
}
if (-not $script:auth) {
    Write-Host "WARN: 未找到 MCP 密钥（$KeyFile），跳过已认证用例" -ForegroundColor Yellow
}

$init = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ui-probe","version":"1"}}}'

# ── 未认证/协议负向 ─────────────────────────────────────────
$r = Invoke-Mcp $init -noAuth
Add-Result 'no-auth' $r.Status '期望 401' ($r.Status -eq 401) $r.Body
$r = Invoke-Mcp $init @{ Origin = 'http://evil.example' }
Add-Result 'origin-rejected' $r.Status '期望 403' ($r.Status -eq 403) $r.Body
$r = Invoke-Mcp $init @{ Host = 'evil.example:47821' }
Add-Result 'bad-host' $r.Status '期望 403' ($r.Status -eq 403) $r.Body
$r = Invoke-Mcp '' @{} 'GET'
Add-Result 'get-method' $r.Status '期望 405' ($r.Status -eq 405) $r.Body
if ($script:auth) {
    $saved = $script:auth
    $script:auth = 'Bearer ' + ('0' * 64)
    $r = Invoke-Mcp $init
    $script:auth = $saved
    Add-Result 'wrong-key' $r.Status '期望 401' ($r.Status -eq 401) $r.Body
}

# ── 已认证：initialize / tools/list / status ────────────────
$initJson = $null
if ($script:auth) {
    $r = Invoke-Mcp $init
    $ok = $r.Status -eq 200
    Add-Result 'initialize' $r.Status '期望 200' $ok $r.Body
    if ($ok) { try { $initJson = $r.Body | ConvertFrom-Json } catch {} }

    $r = Invoke-Mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    Add-Result 'tools/list' $r.Status '期望 200' ($r.Status -eq 200) $r.Body

    $r = Invoke-Mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"status","arguments":{}}}'
    Add-Result 'status' $r.Status '期望 200' ($r.Status -eq 200) $r.Body
}

# ── 汇总 ────────────────────────────────────────────────────
$failed = @($results | Where-Object { -not $_.pass })
foreach ($item in $results) {
    $mark = if ($item.pass) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1} status={2} ({3})" -f $mark, $item.name, $item.status, $item.detail)
}
if ($initJson) {
    $si = $initJson.result.serverInfo
    Write-Host ("server={0} version={1} surfaceVersion={2} protocol={3}" -f `
        $si.name, $si.version, $si.surfaceVersion, $initJson.result.protocolVersion)
}
[pscustomobject]@{
    at = (Get-Date).ToString('o')
    endpoint = $base
    authUsed = [bool]$script:auth
    results = $results
} | ConvertTo-Json -Depth 8 | Set-Content -Path $reportFile -Encoding utf8
Write-Host ("report={0} failed={1}" -f $reportFile, $failed.Count)
$client.Dispose()
if ($failed.Count -gt 0) { exit 1 }
