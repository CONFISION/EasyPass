# 发一条已认证的 MCP tools/call（真机），结果写到 %TEMP%\easypass-ui-probe\mcp_result.json。
#
# 密钥来源：MCP 客户端配置文件里的 Authorization 头（默认 DSH 配置，可用 -KeyFile 覆盖）。
# 密钥只在内存中使用，不打印。只在本地运行中的 EasyPass 上使用。
param(
    [Parameter(Mandatory = $true)][string]$Tool,
    [string]$ArgsJson = '{}',
    [int]$TimeoutSeconds = 70,
    [string]$KeyFile = '',
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'

if (-not $KeyFile) {
    $KeyFile = Join-Path $env:USERPROFILE '.dsh\profiles\desktop\cordis.patch.yml'
}
if (-not (Test-Path $KeyFile)) {
    throw "找不到 MCP 客户端配置：$KeyFile（用 -KeyFile 指向含 `Authorization: Bearer <key>` 的文件）"
}
$config = Get-Content $KeyFile -Raw
$m = [regex]::Match($config, 'Authorization:\s*"Bearer\s+([A-Za-z0-9]+)"')
if (-not $m.Success) { $m = [regex]::Match($config, 'Authorization:\s*"([^"]+)"') }
if (-not $m.Success) { throw "配置里没有 Authorization 头：$KeyFile" }
$auth = $m.Groups[1].Value.Trim()
if (-not $auth.StartsWith('Bearer ')) { $auth = "Bearer $auth" }

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'easypass-ui-probe' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$outFile = Join-Path $OutDir 'mcp_result.json'

$body = @{
    jsonrpc = '2.0'
    id = 100
    method = 'tools/call'
    params = @{ name = $Tool; arguments = (ConvertFrom-Json $ArgsJson) }
} | ConvertTo-Json -Depth 12 -Compress

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
$req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, 'http://127.0.0.1:47821/mcp')
$req.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
$req.Headers.TryAddWithoutValidation('Authorization', $auth) | Out-Null
$req.Headers.TryAddWithoutValidation('Accept', 'application/json, text/event-stream') | Out-Null
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $status = [int]$resp.StatusCode
} catch {
    $text = $_.Exception.Message
    $status = -1
}
$sw.Stop()
[pscustomobject]@{
    at = (Get-Date).ToString('o')
    tool = $Tool
    args = $ArgsJson
    status = $status
    elapsedMs = $sw.ElapsedMilliseconds
    body = $text
} | ConvertTo-Json -Depth 8 | Set-Content -Path $outFile -Encoding utf8
Write-Host ("tool={0} status={1} elapsedMs={2} result={3}" -f $Tool, $status, $sw.ElapsedMilliseconds, $outFile)
$client.Dispose()
