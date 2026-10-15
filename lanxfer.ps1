# LanXfer - Ethernet kablosu / yerel ag uzerinden iki PC arasinda dosya aktarimi.
# Kurulum gerektirmez, tamamen RAM'de calisir:
#   irm https://raw.githubusercontent.com/OgeaN/lanxfer/main/lanxfer.ps1 | iex
# Ayarlar (istege bagli, calistirmadan once):
#   $env:LANXFER_PORT = 8765        HTTP portu
#   $env:LANXFER_DIR  = 'D:\Gelen'  gelen dosyalarin klasoru
#   $env:LANXFER_NOBROWSER = 1      uygulama penceresini acma
#   $env:LANXFER_LANG = 'en'        dil: tr / en (varsayilan: Windows dili)
& {
$ErrorActionPreference = 'Stop'
$Version = '1.1.0'
$Lang    = if ($env:LANXFER_LANG) { $env:LANXFER_LANG.ToLowerInvariant() } elseif ((Get-Culture).TwoLetterISOLanguageName -eq 'tr') { 'tr' } else { 'en' }
if ($Lang -notin 'tr', 'en') { $Lang = 'en' }
$Text = @{
    tr = @{
        ui = 'Arayüz'; inbox = 'Gelen klasörü'; cable = 'kablo'; offline = 'İnternetsiz PC için: '
        fwOk = 'Güvenlik duvarı: geçici izin eklendi'
        fwWarn = 'Güvenlik duvarı uyarısı çıkarsa "Ortak/Public" ağlar için de izin verin (veya PowerShell''i yönetici olarak açın).'
        quit = 'Kapatmak için LanXfer penceresini kapatın veya Ctrl+C'
        portBusy = 'Port {0} kullanılamıyor (LanXfer zaten açık olabilir). Başka port için: $env:LANXFER_PORT = 8800'
        winClosed = 'Pencere kapatıldı.'; stopped = 'LanXfer kapatıldı.'
        peer = 'Karşı PC bulundu: {0} ({1})'; served = 'Betik {0} adresine verildi'
        sent = 'GÖNDERİLDİ -> {0} : {1}'; recv = 'ALINDI <- {0} : {1} ({2:N1} MB)'; partial = 'YARIM KALDI <- {0} : {1}'
        err = 'HATA: {0}'; lang = 'Dil: Türkçe'
    }
    en = @{
        ui = 'Interface'; inbox = 'Inbox folder'; cable = 'cable'; offline = 'For a PC without internet: '
        fwOk = 'Firewall: temporary rule added'
        fwWarn = 'If a firewall prompt appears, allow "Public" networks too (or run PowerShell as Administrator).'
        quit = 'Close the LanXfer window or press Ctrl+C to quit'
        portBusy = 'Port {0} is unavailable (LanXfer may already be running). For another port: $env:LANXFER_PORT = 8800'
        winClosed = 'Window closed.'; stopped = 'LanXfer stopped.'
        peer = 'Found peer: {0} ({1})'; served = 'Script sent to {0}'
        sent = 'SENT -> {0} : {1}'; recv = 'RECEIVED <- {0} : {1} ({2:N1} MB)'; partial = 'INCOMPLETE <- {0} : {1}'
        err = 'ERROR: {0}'; lang = 'Language: English'
    }
}
$Port    = if ($env:LANXFER_PORT) { [int]$env:LANXFER_PORT } else { 8765 }
$UdpPort = if ($env:LANXFER_UDP)  { [int]$env:LANXFER_UDP }  else { 8766 }
$Share   = if ($env:LANXFER_DIR)  { $env:LANXFER_DIR } else { Join-Path $env:USERPROFILE 'Downloads\LanXfer' }
$Share   = [IO.Path]::GetFullPath($Share).TrimEnd('\')
# Kendi kaynak kodu: internetsiz PC'ye "irm http://<ip>:<port>/s | iex" ile servis edilir.
$Self    = '& {' + $MyInvocation.MyCommand.ScriptBlock.ToString() + '}'

# Aktif IPv4 adresleri ve yayin (broadcast) adresleri. Runspace'lerde de kullanildigi icin metin olarak tutulur.
$AddrSrc = {
    foreach ($ni in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne 'Up') { continue }
        if ("$($ni.NetworkInterfaceType)" -in 'Loopback', 'Tunnel') { continue }
        foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
            $ip = $ua.Address.GetAddressBytes()
            $m  = $ua.IPv4Mask.GetAddressBytes()
            $b  = [byte[]]::new(4)
            for ($i = 0; $i -lt 4; $i++) { $b[$i] = $ip[$i] -bor (255 -bxor $m[$i]) }
            $s = $ua.Address.ToString()
            [pscustomobject]@{
                ip        = $s
                bcast     = ([Net.IPAddress]::new($b)).ToString()
                adapter   = $ni.Name
                kind      = "$($ni.NetworkInterfaceType)"
                linkLocal = $s.StartsWith('169.254.')
            }
        }
    }
}.ToString()

# ---------------------------------------------------------------- HTTP istek isleyici (her baglanti ayri runspace'te)
$Handler = {
    param($Client, $S)
    $Latin = [Text.Encoding]::GetEncoding(28591)
    $Utf8  = [Text.UTF8Encoding]::new($false)
    $ns = $null

    function Log([string]$Msg) { $S.Log.Enqueue(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Msg)) }
    function T([string]$Key) { $S.Text[$S.Lang][$Key] }

    function Head([int]$Code, [string]$Type, [long]$Len, [string]$Extra = '') {
        $reason = @{ 200 = 'OK'; 204 = 'No Content'; 400 = 'Bad Request'; 403 = 'Forbidden'; 404 = 'Not Found'; 500 = 'Internal Server Error' }[$Code]
        $h = "HTTP/1.1 $Code $reason`r`nContent-Type: $Type`r`nContent-Length: $Len`r`nConnection: close`r`nCache-Control: no-store`r`n" +
             "Access-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, PUT, POST, OPTIONS`r`n" +
             "Access-Control-Allow-Headers: *`r`nAccess-Control-Allow-Private-Network: true`r`n$Extra`r`n"
        $b = $Utf8.GetBytes($h)
        $ns.Write($b, 0, $b.Length)
    }

    function Reply([int]$Code, [string]$Type, $Body) {
        if ($Body -is [string]) { $Body = $Utf8.GetBytes($Body) }
        if ($null -eq $Body) { $Body = [byte[]]@() }
        Head $Code $Type $Body.Length
        if ($Body.Length) { $ns.Write($Body, 0, $Body.Length) }
    }

    function Json($Obj, [int]$Code = 200) {
        Reply $Code 'application/json; charset=utf-8' (ConvertTo-Json -InputObject $Obj -Depth 5 -Compress)
    }

    # "a/b/../c.txt" gibi isimleri guvenli goreli yola cevirir; klasor disina cikisi engeller.
    function SafeRel([string]$Name) {
        $bad = [IO.Path]::GetInvalidFileNameChars()
        $parts = foreach ($p in ($Name -split '[\\/]')) {
            $p = (-join ($p.ToCharArray() | Where-Object { $bad -notcontains $_ })).Trim().TrimEnd('.')
            if ($p) { $p }
        }
        if (-not $parts) { return $null }
        $parts -join '\'
    }

    function InShare([string]$Rel) {
        $root = $S.Share + '\'
        $full = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $Rel))
        if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $full } else { $null }
    }

    function UniquePath([string]$Path) {
        if (-not [IO.File]::Exists($Path) -and -not [IO.File]::Exists("$Path.part")) { return $Path }
        $dir  = [IO.Path]::GetDirectoryName($Path)
        $base = [IO.Path]::GetFileNameWithoutExtension($Path)
        $ext  = [IO.Path]::GetExtension($Path)
        for ($i = 1; ; $i++) {
            $c = [IO.Path]::Combine($dir, "$base ($i)$ext")
            if (-not [IO.File]::Exists($c) -and -not [IO.File]::Exists("$c.part")) { return $c }
        }
    }

    try {
        $Client.ReceiveBufferSize = 1MB
        $Client.SendBufferSize = 1MB
        $ns = $Client.GetStream()
        $ns.ReadTimeout = 60000
        $ns.WriteTimeout = 60000
        $buf = [byte[]]::new(1MB)

        # Basliklari oku; basliktan sonra gelen govde parcasi $raw icinde kalir.
        $acc = [IO.MemoryStream]::new()
        $end = -1
        while ($end -lt 0) {
            $n = $ns.Read($buf, 0, 65536)
            if ($n -le 0) { return }
            $acc.Write($buf, 0, $n)
            $end = $Latin.GetString($acc.GetBuffer(), 0, [int]$acc.Length).IndexOf("`r`n`r`n")
            if ($end -lt 0 -and $acc.Length -gt 65536) { return }
        }
        $raw  = $acc.ToArray()
        $rest = $raw.Length - ($end + 4)

        $lines  = $Utf8.GetString($raw, 0, $end) -split "`r`n"
        $req    = $lines[0] -split ' '
        $method = $req[0].ToUpperInvariant()
        $target = $req[1]
        $hd = @{}
        foreach ($l in ($lines | Select-Object -Skip 1)) {
            $i = $l.IndexOf(':')
            if ($i -gt 0) { $hd[$l.Substring(0, $i).Trim().ToLowerInvariant()] = $l.Substring($i + 1).Trim() }
        }
        $path = $target
        $q = @{}
        $qi = $target.IndexOf('?')
        if ($qi -ge 0) {
            $path = $target.Substring(0, $qi)
            foreach ($kv in $target.Substring($qi + 1).Split('&')) {
                if (-not $kv) { continue }
                $p = $kv.Split([char[]]'=', 2)
                $q[[Uri]::UnescapeDataString($p[0].Replace('+', ' '))] = if ($p.Count -gt 1) { [Uri]::UnescapeDataString($p[1].Replace('+', ' ')) } else { '' }
            }
        }
        $remote  = $Client.Client.RemoteEndPoint.Address
        $isLocal = [Net.IPAddress]::IsLoopback($remote)

        if ($method -eq 'OPTIONS') {
            Reply 204 'text/plain' $null
        }
        elseif ($method -eq 'GET' -and $path -eq '/') {
            Reply 200 'text/html; charset=utf-8' $S.Html
        }
        elseif ($method -eq 'GET' -and ($path -eq '/s' -or $path -eq '/lanxfer.ps1')) {
            Reply 200 'text/plain; charset=utf-8' $S.Self
            Log ((T 'served') -f $remote)
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/info') {
            Json @{
                lang    = $S.Lang
                name    = $S.Name
                id      = $S.Id
                port    = $S.Port
                version = $S.Version
                share   = $(if ($isLocal) { $S.Share } else { $null })
                addrs   = @(& ([scriptblock]::Create($S.AddrSrc)))
            }
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/files') {
            $files = @(Get-ChildItem -LiteralPath $S.Share -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -ne '.part' } |
                Sort-Object LastWriteTimeUtc -Descending |
                ForEach-Object {
                    [pscustomobject]@{
                        name  = $_.FullName.Substring($S.Share.Length + 1).Replace('\', '/')
                        size  = $_.Length
                        mtime = [long]($_.LastWriteTimeUtc - [datetime]::new(1970, 1, 1)).TotalMilliseconds
                    }
                })
            Json @{ files = $files }
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/peers') {
            $now = [DateTime]::UtcNow.Ticks
            $list = @(foreach ($k in @($S.Peers.Keys)) {
                $p = $S.Peers[$k]
                if (($now - $p.seen) -lt 80000000) { [pscustomobject]@{ ip = $p.ip; port = $p.port; name = $p.name; id = $p.id } }
            })
            Json @{ peers = $list }
        }
        elseif ($method -eq 'GET' -and $path -eq '/dl') {
            $rel  = SafeRel $q['n']
            $full = if ($rel) { InShare $rel }
            if (-not $full -or -not [IO.File]::Exists($full)) { Json @{ error = 'File not found' } 404; return }
            $fs = [IO.FileStream]::new($full, 'Open', 'Read', 'ReadWrite', 1MB)
            try {
                $fn = [Uri]::EscapeDataString([IO.Path]::GetFileName($full))
                Head 200 'application/octet-stream' $fs.Length "Content-Disposition: attachment; filename*=UTF-8''$fn`r`n"
                $fs.CopyTo($ns, 1MB)
            }
            finally { $fs.Dispose() }
            Log ((T 'sent') -f $remote, $rel)
        }
        elseif ($method -eq 'PUT' -and $path -eq '/up') {
            $rel = SafeRel $q['name']
            if (-not $rel -or -not $hd.ContainsKey('content-length')) { Json @{ error = 'Bad request' } 400; return }
            $dest = InShare $rel
            if (-not $dest) { Json @{ error = 'Invalid path' } 403; return }
            $len  = [long]$hd['content-length']
            $dest = UniquePath $dest
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
            $part = "$dest.part"
            $fs = [IO.FileStream]::new($part, 'Create', 'Write', 'None', 1MB)
            $ok = $false
            if ($hd['expect'] -eq '100-continue') {
                $b = $Utf8.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
                $ns.Write($b, 0, $b.Length)
            }
            try {
                $left = $len
                $pre = [Math]::Min([long]$rest, $left)
                if ($pre -gt 0) { $fs.Write($raw, $end + 4, [int]$pre); $left -= $pre }
                while ($left -gt 0) {
                    $n = $ns.Read($buf, 0, [int][Math]::Min([long]$buf.Length, $left))
                    if ($n -le 0) { throw 'Connection closed' }
                    $fs.Write($buf, 0, $n)
                    $left -= $n
                }
                $ok = $true
            }
            finally {
                $fs.Dispose()
                if (-not $ok) {
                    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                    Log ((T 'partial') -f $remote, $rel)
                }
            }
            [IO.File]::Move($part, $dest)
            Log ((T 'recv') -f $remote, $rel, ($len / 1MB))
            Json @{ ok = $true; name = $dest.Substring($S.Share.Length + 1).Replace('\', '/') }
        }
        elseif ($method -eq 'POST' -and $path -eq '/api/open') {
            if (-not $isLocal) { Json @{ error = 'Local only' } 403; return }
            Start-Process explorer.exe -ArgumentList "`"$($S.Share)`""
            Json @{ ok = $true }
        }
        elseif ($method -eq 'POST' -and $path -eq '/api/lang') {
            if (-not $isLocal) { Json @{ error = 'Local only' } 403; return }
            if ($q['l'] -in 'tr', 'en' -and $q['l'] -ne $S.Lang) { $S.Lang = $q['l']; Log (T 'lang') }
            Json @{ ok = $true }
        }
        else {
            Json @{ error = 'Not found' } 404
        }
    }
    catch {
        Log ((T 'err') -f $_.Exception.Message)
    }
    finally {
        if ($ns) { $ns.Dispose() }
        $Client.Close()
    }
}

# ---------------------------------------------------------------- UDP ile karsi PC'yi otomatik bulma
$Discovery = {
    param($S)
    $GetAddrs = [scriptblock]::Create($S.AddrSrc)
    $enc = [Text.UTF8Encoding]::new($false)
    $rx = [Net.Sockets.UdpClient]::new()
    $rx.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $rx.Client.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Any, $S.UdpPort))
    $rx.Client.ReceiveTimeout = 500
    $next = [DateTime]::MinValue
    try {
        while (-not $S.Stop) {
            if ([DateTime]::UtcNow -ge $next) {
                $next = [DateTime]::UtcNow.AddSeconds(2)
                $msg = $enc.GetBytes("LANXFER1|$($S.Id)|$($S.Port)|$($S.Name)")
                foreach ($a in @(& $GetAddrs)) {
                    $tx = $null
                    try {
                        $tx = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Parse($a.ip), 0))
                        $tx.EnableBroadcast = $true
                        [void]$tx.Send($msg, $msg.Length, [Net.IPEndPoint]::new([Net.IPAddress]::Parse($a.bcast), $S.UdpPort))
                    }
                    catch {}
                    finally { if ($tx) { $tx.Close() } }
                }
            }
            try {
                $ep = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
                $data = $rx.Receive([ref]$ep)
                $p = $enc.GetString($data).Split([char[]]'|', 4)
                if ($p.Count -eq 4 -and $p[0] -eq 'LANXFER1' -and $p[1] -ne $S.Id) {
                    $ip = $ep.Address.ToString()
                    $key = "${ip}:$($p[2])"
                    if (-not $S.Peers.ContainsKey($key)) { $S.Log.Enqueue(('[{0:HH:mm:ss}] ' -f (Get-Date)) + ($S.Text[$S.Lang].peer -f $p[3], $key)) }
                    $S.Peers[$key] = @{ ip = $ip; port = [int]$p[2]; id = $p[1]; name = $p[3]; seen = [DateTime]::UtcNow.Ticks }
                }
            }
            catch [Net.Sockets.SocketException] {}
        }
    }
    finally { $rx.Close() }
}

# ---------------------------------------------------------------- Arayuz
$Html = @'
<!doctype html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LanXfer</title>
<meta name="theme-color" content="#0f1115">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Cdefs%3E%3ClinearGradient id='g' x1='0' y1='0' x2='1' y2='1'%3E%3Cstop offset='0' stop-color='%234f8cff'/%3E%3Cstop offset='1' stop-color='%238a5cff'/%3E%3C/linearGradient%3E%3C/defs%3E%3Crect width='64' height='64' rx='16' fill='url(%23g)'/%3E%3Cpath d='M16 24h28l-7-7M48 40H20l7 7' stroke='white' stroke-width='5' fill='none' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E">
<style>
:root{
  --bg:#0f1115;--panel:#171a21;--panel2:#1d212a;--line:#2a2f3a;--text:#e7e9ee;--muted:#8b93a3;
  --accent:#4f8cff;--accent2:#2f6fe8;--ok:#2fbf71;--warn:#e8a33d;--err:#ef5350;--chip:#232836;
}
@media (prefers-color-scheme: light){
  :root{--bg:#f4f6fa;--panel:#fff;--panel2:#f7f8fb;--line:#e1e5ec;--text:#161a22;--muted:#677084;--chip:#eef1f6}
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 "Segoe UI",system-ui,sans-serif}
.wrap{max-width:1180px;margin:0 auto;padding:20px 16px 40px}
header{display:flex;align-items:center;gap:12px;margin-bottom:18px;flex-wrap:wrap}
.logo{width:38px;height:38px;border-radius:10px;background:linear-gradient(135deg,var(--accent),#8a5cff);display:grid;place-items:center;color:#fff;font-size:20px;font-weight:700}
h1{font-size:20px;margin:0}
.sub{color:var(--muted);font-size:13px}
.pill{margin-left:auto;padding:6px 12px;border-radius:999px;background:var(--chip);font-size:13px;display:flex;align-items:center;gap:8px}
.dot{width:8px;height:8px;border-radius:50%;background:var(--muted)}
.dot.on{background:var(--ok);box-shadow:0 0 0 3px color-mix(in srgb,var(--ok) 25%,transparent)}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-bottom:14px}
@media (max-width:820px){.grid{grid-template-columns:1fr}}
.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:16px}
.card h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:0 0 12px;display:flex;align-items:center;gap:8px}
.card h2 .sp{flex:1}
.big{font-size:18px;font-weight:600;margin-bottom:8px}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chip{background:var(--chip);border-radius:8px;padding:4px 9px;font-size:12.5px;font-family:Consolas,monospace}
.chip b{font-family:"Segoe UI",sans-serif;font-weight:600;color:var(--ok);margin-left:4px}
.muted{color:var(--muted)}
.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
input{background:var(--panel2);border:1px solid var(--line);color:var(--text);border-radius:9px;padding:9px 11px;font:inherit;min-width:0}
input:focus{outline:2px solid var(--accent);border-color:transparent}
button{background:var(--accent);color:#fff;border:0;border-radius:9px;padding:9px 14px;font:inherit;font-weight:600;cursor:pointer}
button:hover{background:var(--accent2)}
button.ghost{background:var(--chip);color:var(--text)}
button.ghost:hover{background:var(--line)}
button.small{padding:5px 10px;font-size:12.5px}
button:disabled{opacity:.45;cursor:not-allowed}
.peers{display:flex;flex-direction:column;gap:6px;margin-bottom:12px}
.peer{display:flex;align-items:center;gap:10px;padding:9px 11px;border:1px solid var(--line);border-radius:10px;background:var(--panel2);cursor:pointer;text-align:left;color:var(--text);font-weight:400}
.peer:hover{border-color:var(--accent);background:var(--panel2)}
.peer.sel{border-color:var(--ok)}
.peer .n{font-weight:600}
.peer .ip{margin-left:auto;font-family:Consolas,monospace;font-size:12.5px;color:var(--muted)}
.msg{font-size:13px;margin-top:8px;min-height:18px}
.msg.err{color:var(--err)} .msg.ok{color:var(--ok)}
.drop{border:2px dashed var(--line);border-radius:14px;padding:30px 16px;text-align:center;transition:.15s;background:var(--panel2)}
.drop.over{border-color:var(--accent);background:color-mix(in srgb,var(--accent) 10%,var(--panel2))}
.drop.off{opacity:.5}
.drop .t{font-size:16px;font-weight:600;margin-bottom:4px}
.drop .row{justify-content:center;margin-top:14px}
.queue{margin-top:12px;display:flex;flex-direction:column;gap:8px}
.job{border:1px solid var(--line);border-radius:10px;padding:9px 11px}
.job .top{display:flex;gap:10px;align-items:center;font-size:13px}
.job .nm{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.job .st{color:var(--muted);font-size:12.5px;white-space:nowrap}
.bar{height:6px;border-radius:9px;background:var(--chip);margin-top:7px;overflow:hidden}
.bar i{display:block;height:100%;width:0;background:var(--accent);transition:width .2s}
.job.done .bar i{background:var(--ok)} .job.fail .bar i{background:var(--err)}
.x{background:none;color:var(--muted);padding:0 4px;font-size:16px;line-height:1}
.x:hover{background:none;color:var(--err)}
.list{max-height:360px;overflow:auto;margin:0 -6px}
table{width:100%;border-collapse:collapse;font-size:13px}
td{padding:7px 6px;border-top:1px solid var(--line);vertical-align:middle}
td.nm{word-break:break-all}
td.sz,td.tm{white-space:nowrap;color:var(--muted);text-align:right}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
.empty{color:var(--muted);text-align:center;padding:22px 0}
code{font-family:Consolas,monospace;background:var(--chip);padding:7px 10px;border-radius:8px;display:inline-block;word-break:break-all}
.cmds{display:flex;flex-direction:column;gap:6px}
.sum{font-size:13px;color:var(--muted);margin-top:8px}
.lang{display:flex;background:var(--chip);border-radius:999px;padding:3px}
.lang button{background:none;color:var(--muted);padding:4px 10px;border-radius:999px;font-size:12px}
.lang button:hover{background:none;color:var(--text)}
.lang button.on{background:var(--accent);color:#fff}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="logo">⇄</div>
    <div><h1>LanXfer</h1><div class="sub" data-i="sub"></div></div>
    <div class="pill"><span class="dot" id="statDot"></span><span id="statTxt"></span></div>
    <div class="lang" id="lang"><button data-l="tr">TR</button><button data-l="en">EN</button></div>
  </header>

  <div class="grid">
    <div class="card">
      <h2 data-i="thisPc"></h2>
      <div class="big" id="meName">…</div>
      <div class="chips" id="meAddrs"></div>
      <div class="sum"><span data-i="incoming"></span> <span id="meShare" class="muted">…</span></div>
    </div>
    <div class="card">
      <h2 data-i="otherPc"></h2>
      <div class="peers" id="peers"></div>
      <div class="row">
        <input id="ipIn" data-ph="ipPh" style="flex:1">
        <input id="portIn" value="8765" style="width:80px">
        <button id="connBtn" data-i="connect"></button>
      </div>
      <div class="msg" id="connMsg"></div>
    </div>
  </div>

  <div class="card" style="margin-bottom:14px">
    <h2><span data-i="send"></span> <span class="sp"></span><span id="sendTo" class="muted" style="text-transform:none;letter-spacing:0"></span></h2>
    <div class="drop off" id="drop">
      <div class="t" data-i="dropTitle"></div>
      <div class="muted" id="dropHint"></div>
      <div class="row">
        <button id="pickFiles" data-i="pickFiles" disabled></button>
        <button id="pickDir" class="ghost" data-i="pickDir" disabled></button>
      </div>
      <input type="file" id="fileIn" multiple hidden>
      <input type="file" id="dirIn" webkitdirectory hidden>
    </div>
    <div class="queue" id="queue"></div>
  </div>

  <div class="grid">
    <div class="card">
      <h2><span data-i="inboxTitle"></span> <span class="sp"></span><button class="ghost small" id="openBtn" data-i="openFolder"></button></h2>
      <div class="list" id="myFiles"></div>
    </div>
    <div class="card">
      <h2><span data-i="peerFilesTitle"></span> <span class="sp"></span></h2>
      <div class="list" id="peerFiles"></div>
    </div>
  </div>

  <div class="card">
    <h2 data-i="offlineTitle"></h2>
    <div class="muted" style="margin-bottom:10px" data-i="offlineText"></div>
    <div class="cmds" id="cmds"></div>
  </div>
</div>

<script>
const I18N = {
  tr: {
    sub: 'Kablo ile iki bilgisayar arasında dosya aktarımı', notConnected: 'Bağlı değil', connectedTo: 'Bağlı: {0} ({1})',
    thisPc: 'Bu bilgisayar', incoming: 'Gelen dosyalar:', otherPc: 'Karşı bilgisayar',
    searching: "Aranıyor… (karşı PC'de de LanXfer açık olmalı)", ipPh: 'IP adresi (ör. 169.254.12.34)', connect: 'Bağlan',
    send: 'Gönder', dropTitle: 'Dosya veya klasörleri buraya sürükleyip bırakın', dropOff: 'Önce karşı bilgisayara bağlanın',
    dropOn: 'Dosyalar {0} bilgisayarının gelen kutusuna gider', pickFiles: 'Dosya seç', pickDir: 'Klasör seç',
    inboxTitle: 'Gelen kutusu (bu PC)', openFolder: 'Klasörü aç', peerFilesTitle: "Karşı PC'deki dosyalar", noConn: 'Bağlantı yok',
    offlineTitle: "Karşı PC'de internet yok mu?",
    offlineText: "Kabloyu taktıktan sonra karşı PC'de PowerShell açıp aşağıdakilerden birini çalıştırın — LanXfer bu bilgisayardan indirilip RAM'de çalışır:",
    copy: 'Kopyala', copied: 'Kopyalandı', cable: 'kablo', noNetwork: 'Ağ bağlantısı yok', connecting: 'Bağlanılıyor…',
    connectedMsg: '{0} bilgisayarına bağlanıldı.', selfAddr: 'Bu adres bu bilgisayarın kendisi.',
    unreachable: "{0} adresine ulaşılamadı. Karşı PC'de LanXfer açık mı? Güvenlik duvarı izin verdi mi?",
    peerEmpty: "Karşı PC'nin gelen kutusu boş", inboxEmpty: 'Henüz dosya gelmedi', connLost: 'Bağlantı koptu',
    queued: 'Sırada · {0}', cancel: 'İptal', cancelled: 'İptal edildi', remove: 'Kaldır', sent: 'Gönderildi · {0} · {1}/s',
    httpErr: 'Hata: HTTP {0}', netErr: 'Bağlantı hatası', sec: 'sn', min: 'dk', locale: 'tr-TR'
  },
  en: {
    sub: 'File transfer between two computers over a cable', notConnected: 'Not connected', connectedTo: 'Connected: {0} ({1})',
    thisPc: 'This computer', incoming: 'Incoming files:', otherPc: 'Other computer',
    searching: 'Searching… (LanXfer must be running on the other PC too)', ipPh: 'IP address (e.g. 169.254.12.34)', connect: 'Connect',
    send: 'Send', dropTitle: 'Drag and drop files or folders here', dropOff: 'Connect to the other computer first',
    dropOn: "Files go to {0}'s inbox", pickFiles: 'Choose files', pickDir: 'Choose folder',
    inboxTitle: 'Inbox (this PC)', openFolder: 'Open folder', peerFilesTitle: 'Files on the other PC', noConn: 'Not connected',
    offlineTitle: 'No internet on the other PC?',
    offlineText: 'After plugging in the cable, open PowerShell on the other PC and run one of these — LanXfer is downloaded from this computer and runs in memory:',
    copy: 'Copy', copied: 'Copied', cable: 'cable', noNetwork: 'No network connection', connecting: 'Connecting…',
    connectedMsg: 'Connected to {0}.', selfAddr: 'That address is this computer.',
    unreachable: "Couldn't reach {0}. Is LanXfer running on the other PC? Did the firewall allow it?",
    peerEmpty: "The other PC's inbox is empty", inboxEmpty: 'No files received yet', connLost: 'Connection lost',
    queued: 'Queued · {0}', cancel: 'Cancel', cancelled: 'Cancelled', remove: 'Remove', sent: 'Sent · {0} · {1}/s',
    httpErr: 'Error: HTTP {0}', netErr: 'Connection error', sec: 's', min: 'min', locale: 'en-GB'
  }
};
let lang = 'en';
const t = (k, ...a) => (I18N[lang][k] ?? k).replace(/\{(\d)\}/g, (_, i) => a[i]);

const $ = s => document.querySelector(s);
const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmtSize = b => { const u=['B','KB','MB','GB','TB']; let i=0; while (b>=1024 && i<u.length-1){b/=1024;i++} return (i?b.toFixed(b<10?2:1):b)+' '+u[i]; };
const fmtTime = ms => { const d=new Date(ms); return d.toLocaleDateString(t('locale'))+' '+d.toLocaleTimeString(t('locale'),{hour:'2-digit',minute:'2-digit'}); };
const fmtEta = s => !isFinite(s) ? '' : s<60 ? Math.ceil(s)+' '+t('sec') : Math.floor(s/60)+' '+t('min')+' '+Math.ceil(s%60)+' '+t('sec');

function setLang(l, tellServer) {
  lang = I18N[l] ? l : 'en';
  document.documentElement.lang = lang;
  document.querySelectorAll('[data-i]').forEach(el => el.textContent = t(el.dataset.i));
  document.querySelectorAll('[data-ph]').forEach(el => el.placeholder = t(el.dataset.ph));
  document.querySelectorAll('#lang button').forEach(b => b.classList.toggle('on', b.dataset.l === lang));
  try { localStorage.setItem('lanxfer.lang', lang); } catch {}
  if (tellServer) fetch('/api/lang?l=' + lang, {method: 'POST'}).catch(() => {});
  setStatus(); renderPeers(lastPeers); if (me) renderMe();
  if (!peer) $('#peerFiles').innerHTML = `<div class="empty">${t('noConn')}</div>`;
  if (myFiles) renderFiles($('#myFiles'), myFiles, false);
  refreshMine(); refreshPeerFiles();
}

let me = null, peer = null, peerFails = 0;
const base = () => `http://${peer.ip}:${peer.port}`;

async function getJson(url, ms = 4000) {
  const ac = new AbortController(); const t = setTimeout(() => ac.abort(), ms);
  try { const r = await fetch(url, {signal: ac.signal, cache: 'no-store'}); if (!r.ok) throw new Error('HTTP ' + r.status); return await r.json(); }
  finally { clearTimeout(t); }
}

function setStatus() {
  $('#statDot').classList.toggle('on', !!peer);
  $('#statTxt').textContent = peer ? t('connectedTo', peer.name, peer.ip) : t('notConnected');
  $('#sendTo').textContent = peer ? `→ ${peer.name}` : '';
  $('#drop').classList.toggle('off', !peer);
  $('#dropHint').textContent = peer ? t('dropOn', peer.name) : t('dropOff');
  $('#pickFiles').disabled = $('#pickDir').disabled = !peer;
}

async function loadMe() {
  me = await getJson('/api/info');
  renderMe();
}
function renderMe() {
  $('#meName').textContent = me.name;
  $('#meShare').textContent = me.share;
  $('#meAddrs').innerHTML = me.addrs.map(a =>
    `<span class="chip" title="${esc(a.adapter)}">${esc(a.ip)}${a.linkLocal ? `<b>${t('cable')}</b>` : ''}</span>`).join('') || `<span class="muted">${t('noNetwork')}</span>`;
  const ips = me.addrs.slice().sort((a, b) => b.linkLocal - a.linkLocal);
  $('#cmds').innerHTML = ips.map(a => {
    const c = `irm http://${a.ip}:${me.port}/s | iex`;
    return `<div class="row"><code>${esc(c)}</code><button class="ghost small" data-c="${esc(c)}">${t('copy')}</button></div>`;
  }).join('');
}

async function connect(ip, port, quiet) {
  const msg = $('#connMsg');
  if (!quiet) { msg.className = 'msg'; msg.textContent = t('connecting'); }
  try {
    const info = await getJson(`http://${ip}:${port}/api/info`, 3500);
    if (me && info.id === me.id) throw new Error('self');
    peer = {ip, port, name: info.name, id: info.id}; peerFails = 0;
    try { localStorage.setItem('lanxfer.peer', JSON.stringify({ip, port})); } catch {}
    msg.className = 'msg ok'; msg.textContent = t('connectedMsg', info.name);
    setStatus(); refreshPeerFiles(); renderPeers(lastPeers);
    return true;
  } catch (e) {
    if (!quiet) {
      msg.className = 'msg err';
      msg.textContent = e.message === 'self' ? t('selfAddr') : t('unreachable', `${ip}:${port}`);
    }
    return false;
  }
}

let lastPeers = [];
function renderPeers(list) {
  lastPeers = list;
  const box = $('#peers');
  if (!list.length) { box.innerHTML = `<div class="muted">${t('searching')}</div>`; return; }
  list.sort((a, b) => b.ip.startsWith('169.254.') - a.ip.startsWith('169.254.'));
  box.innerHTML = list.map(p => {
    const sel = peer && peer.ip === p.ip && +peer.port === +p.port;
    return `<button class="peer${sel ? ' sel' : ''}" data-ip="${esc(p.ip)}" data-port="${p.port}">
      <span>🖥️</span><span class="n">${esc(p.name)}</span>${p.ip.startsWith('169.254.') ? `<span class="chip"><b style="margin:0">${t('cable')}</b></span>` : ''}
      <span class="ip">${esc(p.ip)}:${p.port}</span></button>`;
  }).join('');
}

function renderFiles(el, files, remote) {
  if (!files.length) { el.innerHTML = `<div class="empty">${t(remote ? 'peerEmpty' : 'inboxEmpty')}</div>`; return; }
  el.innerHTML = '<table>' + files.map(f => {
    const nm = remote ? `<a href="${base()}/dl?n=${encodeURIComponent(f.name)}" download>${esc(f.name)}</a>`
                      : `<a href="/dl?n=${encodeURIComponent(f.name)}" download>${esc(f.name)}</a>`;
    return `<tr><td class="nm">${nm}</td><td class="sz">${fmtSize(f.size)}</td><td class="tm">${fmtTime(f.mtime)}</td></tr>`;
  }).join('') + '</table>';
}

let myFiles = null;
async function refreshMine() { try { myFiles = (await getJson('/api/files')).files; renderFiles($('#myFiles'), myFiles, false); } catch {} }
async function refreshPeers() {
  try {
    const list = (await getJson('/api/peers')).peers;
    renderPeers(list);
    if (!peer && list.length && !$('#ipIn').value) {
      const p = list.slice().sort((a, b) => b.ip.startsWith('169.254.') - a.ip.startsWith('169.254.'))[0];
      connect(p.ip, p.port, true);
    }
  } catch {}
}
async function refreshPeerFiles() {
  if (!peer) return;
  try { renderFiles($('#peerFiles'), (await getJson(base() + '/api/files')).files, true); peerFails = 0; }
  catch {
    if (++peerFails >= 3) { peer = null; setStatus(); $('#peerFiles').innerHTML = `<div class="empty">${t('connLost')}</div>`; renderPeers(lastPeers); }
  }
}

// ---------- gönderim kuyruğu
const queue = []; let busy = false;
function enqueue(items) {
  if (!peer) return;
  for (const it of items) {
    it.state = 'wait'; it.peer = {...peer};
    it.el = document.createElement('div'); it.el.className = 'job';
    it.el.innerHTML = `<div class="top"><span class="nm"></span><span class="st">${t('queued', fmtSize(it.file.size))}</span><button class="x" title="${t('cancel')}">✕</button></div><div class="bar"><i></i></div>`;
    it.el.querySelector('.nm').textContent = it.rel;
    it.el.querySelector('.x').onclick = () => { if (it.xhr) it.xhr.abort(); else if (it.state === 'wait') { it.state = 'cancel'; setJob(it, t('cancelled'), 0, true); } };
    $('#queue').prepend(it.el); queue.push(it);
  }
  pump();
}
function setJob(it, text, pct, fail, done) {
  it.el.querySelector('.st').textContent = text;
  it.el.querySelector('.bar i').style.width = pct + '%';
  it.el.classList.toggle('fail', !!fail); it.el.classList.toggle('done', !!done);
  if (fail || done) { const x = it.el.querySelector('.x'); x.onclick = () => it.el.remove(); x.title = t('remove'); }
}
function pump() {
  if (busy) return;
  const it = queue.find(i => i.state === 'wait'); if (!it) return;
  busy = true; send(it).finally(() => { busy = false; pump(); });
}
function send(it) {
  return new Promise(res => {
    it.state = 'run';
    const x = new XMLHttpRequest(); it.xhr = x;
    const t0 = performance.now(); let lastT = t0, lastL = 0, speed = 0;
    x.open('PUT', `http://${it.peer.ip}:${it.peer.port}/up?name=${encodeURIComponent(it.rel)}`);
    x.upload.onprogress = e => {
      const now = performance.now(), dt = (now - lastT) / 1000;
      if (dt > 0.25) { const s = (e.loaded - lastL) / dt; speed = speed ? speed * 0.7 + s * 0.3 : s; lastT = now; lastL = e.loaded; }
      const pct = e.total ? e.loaded / e.total * 100 : 0;
      setJob(it, `${pct.toFixed(0)}% · ${fmtSize(speed)}/s · ${fmtEta((e.total - e.loaded) / speed)}`, pct);
    };
    x.onload = () => {
      const secs = (performance.now() - t0) / 1000;
      if (x.status === 200) { it.state = 'done'; setJob(it, t('sent', fmtSize(it.file.size), fmtSize(it.file.size / Math.max(secs, .001))), 100, false, true); refreshPeerFiles(); }
      else { it.state = 'fail'; setJob(it, t('httpErr', x.status), 100, true); }
      res();
    };
    x.onerror = () => { it.state = 'fail'; setJob(it, t('netErr'), 100, true); res(); };
    x.onabort = () => { it.state = 'fail'; setJob(it, t('cancelled'), 0, true); res(); };
    x.send(it.file);
  });
}

async function filesFromDrop(dt) {
  const entries = [...dt.items].map(i => i.webkitGetAsEntry && i.webkitGetAsEntry()).filter(Boolean);
  if (!entries.length) return [...dt.files].map(f => ({file: f, rel: f.name}));
  const out = [];
  async function walk(entry, prefix) {
    if (entry.isFile) { const f = await new Promise((ok, no) => entry.file(ok, no)); out.push({file: f, rel: prefix + f.name}); }
    else if (entry.isDirectory) {
      const rd = entry.createReader(); let batch;
      do { batch = await new Promise((ok, no) => rd.readEntries(ok, no)); for (const e of batch) await walk(e, prefix + entry.name + '/'); } while (batch.length);
    }
  }
  for (const e of entries) await walk(e, '');
  return out;
}

// ---------- olaylar
const drop = $('#drop');
['dragenter', 'dragover'].forEach(ev => drop.addEventListener(ev, e => { e.preventDefault(); if (peer) drop.classList.add('over'); }));
['dragleave', 'drop'].forEach(ev => drop.addEventListener(ev, () => drop.classList.remove('over')));
drop.addEventListener('drop', async e => { e.preventDefault(); if (peer) enqueue(await filesFromDrop(e.dataTransfer)); });
window.addEventListener('dragover', e => e.preventDefault());
window.addEventListener('drop', e => e.preventDefault());
$('#pickFiles').onclick = () => $('#fileIn').click();
$('#pickDir').onclick = () => $('#dirIn').click();
$('#fileIn').onchange = e => { enqueue([...e.target.files].map(f => ({file: f, rel: f.name}))); e.target.value = ''; };
$('#dirIn').onchange = e => { enqueue([...e.target.files].map(f => ({file: f, rel: f.webkitRelativePath || f.name}))); e.target.value = ''; };
$('#connBtn').onclick = () => { const ip = $('#ipIn').value.trim(); if (ip) connect(ip, +$('#portIn').value || 8765); };
$('#ipIn').onkeydown = e => { if (e.key === 'Enter') $('#connBtn').click(); };
$('#peers').onclick = e => { const b = e.target.closest('.peer'); if (b) connect(b.dataset.ip, +b.dataset.port); };
$('#openBtn').onclick = () => fetch('/api/open', {method: 'POST'});
$('#cmds').onclick = e => { const b = e.target.closest('button[data-c]'); if (b) { navigator.clipboard.writeText(b.dataset.c); b.textContent = t('copied'); setTimeout(() => b.textContent = t('copy'), 1500); } };
$('#lang').onclick = e => { const b = e.target.closest('button[data-l]'); if (b) setLang(b.dataset.l, true); };

(async () => {
  try { await loadMe(); } catch {}
  let saved = null; try { saved = localStorage.getItem('lanxfer.lang'); } catch {}
  setLang(saved || (me && me.lang) || (navigator.language || '').slice(0, 2), !!saved);
  try { const s = JSON.parse(localStorage.getItem('lanxfer.peer') || 'null'); if (s) connect(s.ip, s.port, true); } catch {}
  refreshMine(); refreshPeers();
  setInterval(() => { refreshMine(); refreshPeers(); refreshPeerFiles(); }, 2000);
  setInterval(() => loadMe().catch(() => {}), 10000);
})();
</script>
</body>
</html>
'@

# ---------------------------------------------------------------- Baslat
$S = [hashtable]::Synchronized(@{
    Port    = $Port
    UdpPort = $UdpPort
    Share   = $Share
    Name    = $env:COMPUTERNAME
    Id      = [guid]::NewGuid().ToString('N').Substring(0, 8)
    Version = $Version
    Html    = $Html
    Self    = $Self
    AddrSrc = $AddrSrc
    Lang    = $Lang
    Text    = $Text
    Peers   = [hashtable]::Synchronized(@{})
    Stop    = $false
    Log     = [Collections.Concurrent.ConcurrentQueue[string]]::new()
})

function T([string]$Key) { $S.Text[$S.Lang][$Key] }

[void][IO.Directory]::CreateDirectory($Share)
try { $Host.UI.RawUI.WindowTitle = "LanXfer :$Port" } catch {}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $Port)
try { $listener.Start() }
catch {
    Write-Host ((T 'portBusy') -f $Port) -ForegroundColor Red
    return
}

# Yonetici olarak calisiyorsa gecici guvenlik duvari kurali ekle (cikista silinir).
$fwRule = $null
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    try {
        $fwRule = "LanXfer-$($S.Id)"
        New-NetFirewallRule -Name "$fwRule-tcp" -DisplayName 'LanXfer (gecici)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Any | Out-Null
        New-NetFirewallRule -Name "$fwRule-udp" -DisplayName 'LanXfer (gecici)' -Direction Inbound -Action Allow -Protocol UDP -LocalPort $UdpPort -Profile Any | Out-Null
    }
    catch { $fwRule = $null }
}

$pool = [runspacefactory]::CreateRunspacePool(1, 32)
$pool.Open()
$discoRs = [runspacefactory]::CreateRunspace()
$discoRs.Open()
$disco = [powershell]::Create()
$disco.Runspace = $discoRs
[void]$disco.AddScript($Discovery.ToString()).AddArgument($S)
$discoH = $disco.BeginInvoke()

$addrs = @(& ([scriptblock]::Create($AddrSrc)))
Write-Host ''
Write-Host '  LanXfer ' -ForegroundColor Cyan -NoNewline; Write-Host "v$Version  -  $($S.Name)"
Write-Host ("  {0,-14}: http://127.0.0.1:{1}/" -f (T 'ui'), $Port)
Write-Host ("  {0,-14}: {1}" -f (T 'inbox'), $Share)
foreach ($a in $addrs) {
    $tag = if ($a.linkLocal) { "  <- $(T 'cable')" } else { '' }
    Write-Host ("  {0,-15} ({1}){2}" -f $a.ip, $a.adapter, $tag) -ForegroundColor DarkGray
}
if ($addrs) {
    $best = ($addrs | Sort-Object { -[int]$_.linkLocal } | Select-Object -First 1).ip
    Write-Host "  $(T 'offline')" -NoNewline; Write-Host "irm http://${best}:$Port/s | iex" -ForegroundColor Yellow
}
if ($fwRule) { Write-Host "  $(T 'fwOk')" -ForegroundColor Green }
else { Write-Host "  $(T 'fwWarn')" -ForegroundColor DarkYellow }
Write-Host "  $(T 'quit')" -ForegroundColor DarkGray
Write-Host ''

# Arayuzu adres cubugu olmayan, ayri bir uygulama penceresinde ac (Edge/Chrome --app modu).
# Ayri profil klasoru sayesinde pencere kendi surecinde calisir; kapaninca sunucu da kapanir.
$uiProc = $null
$uiProfile = Join-Path $env:TEMP "lanxfer-ui-$Port"
if (-not $env:LANXFER_NOBROWSER) {
    $url = "http://127.0.0.1:$Port/"
    $app = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if ($app) {
        $w = 1120; $h = 840
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $w = [Math]::Min($w, $wa.Width - 40); $h = [Math]::Min($h, $wa.Height - 40)
            $pos = "--window-position=$([int]($wa.X + ($wa.Width - $w) / 2)),$([int]($wa.Y + ($wa.Height - $h) / 2))"
        }
        catch { $pos = '--window-position=100,60' }
        $uiProc = Start-Process -FilePath $app -PassThru -ArgumentList @(
            "--app=$url", "--user-data-dir=`"$uiProfile`"", "--window-size=$w,$h", $pos,
            '--no-first-run', '--no-default-browser-check', '--disable-sync', '--disable-features=Translate,msEdgeSidebarV2'
        )
    }
    else { Start-Process $url }
}

$jobs = [Collections.Generic.List[object]]::new()
$handlerText = $Handler.ToString()
try {
    while ($true) {
        while ($listener.Pending()) {
            $c = $listener.AcceptTcpClient()
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($handlerText).AddArgument($c).AddArgument($S)
            $jobs.Add([pscustomobject]@{ ps = $ps; h = $ps.BeginInvoke() })
        }
        $m = $null
        while ($S.Log.TryDequeue([ref]$m)) { Write-Host "  $m" }
        for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
            if ($jobs[$i].h.IsCompleted) {
                try { [void]$jobs[$i].ps.EndInvoke($jobs[$i].h) } catch { Write-Host ("  " + ((T 'err') -f $_.Exception.Message)) -ForegroundColor Red }
                $jobs[$i].ps.Dispose()
                $jobs.RemoveAt($i)
            }
        }
        if ($uiProc -and $uiProc.HasExited) { Write-Host "  $(T 'winClosed')" -ForegroundColor DarkGray; break }
        Start-Sleep -Milliseconds 30
    }
}
finally {
    $S.Stop = $true
    $listener.Stop()
    foreach ($j in $jobs) { try { [void]$j.ps.BeginStop($null, $null) } catch {} }
    try { [void]$disco.EndInvoke($discoH) } catch {}
    $disco.Dispose(); $discoRs.Dispose()
    $pool.Dispose()
    if ($fwRule) { Remove-NetFirewallRule -Name "$fwRule-tcp", "$fwRule-udp" -ErrorAction SilentlyContinue }
    if ($uiProc) {
        if (-not $uiProc.HasExited) { try { $uiProc.CloseMainWindow() | Out-Null; $uiProc.WaitForExit(3000) | Out-Null } catch {} }
        Start-Sleep -Milliseconds 500
        Remove-Item -LiteralPath $uiProfile -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  $(T 'stopped')" -ForegroundColor Cyan
}
}
