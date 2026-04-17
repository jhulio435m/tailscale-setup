[CmdletBinding()]
param(
    [string]$AuthKey,
    [string]$Hostname,
    [string[]]$AdvertiseTags,
    [string]$LoginServer,
    [Nullable[bool]]$AcceptRoutes,
    [string]$LocalAdminUser,
    [string]$SshPublicKey,
    [string]$EnvFile,
    [string]$LogFile,
    [ValidateSet('stable', 'unstable')]
    [string]$TailscaleTrack = 'stable',
    [string]$InstallerPath = "$env:TEMP\tailscale-setup-latest.msi",
    [string]$TelegramToken,
    [string]$TelegramChatId,
    [int]$InternetWaitTimeoutSeconds = 600,
    [switch]$SkipTailscaleInstall,
    [switch]$SkipOpenSSHInstall,
    [switch]$Cleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- CIRCUIT BREAKER & TELEGRAM ---
$Global:TgFailCount = 0
$Global:TgNextTry = [DateTime]::MinValue

function Send-Telegram {
    param($Token, $ChatId, $Text)
    if (-not $Token -or -not $ChatId -or (Get-Date) -lt $Global:TgNextTry) { return }
    $body = @{ chat_id = $ChatId; text = $Text; parse_mode = 'HTML'; disable_web_page_preview = $true } | ConvertTo-Json
    try { 
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$Token/sendMessage" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 5 | Out-Null 
        $Global:TgFailCount = 0
    } catch {
        $Global:TgFailCount++
        if ($Global:TgFailCount -ge 2) { $Global:TgNextTry = (Get-Date).AddMinutes(2) }
    }
}

# --- DETECCION DE ENTORNO ---
function Get-OSInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        return @{
            Name = $os.Caption
            Version = $os.Version
            Build = $os.BuildNumber
            IsSupported = [int]$os.Version.Split('.')[0] -ge 10
        }
    } catch {
        return @{ Name = "Windows (Desconocido)"; Version = "0.0"; IsSupported = $false }
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Prepare-Environment {
    param($TgToken, $TgChatId)
    $services = @(
        @{ Name = 'wuauserv'; Desc = 'Windows Update' },
        @{ Name = 'mpssvc';   Desc = 'Firewall de Windows' },
        @{ Name = 'BFE';      Desc = 'Base Filtering Engine' },
        @{ Name = 'iphlpsvc'; Desc = 'IP Helper' },
        @{ Name = 'dnscache'; Desc = 'DNS Client' },
        @{ Name = 'WinHttpAutoProxySvc'; Desc = 'WinHTTP Proxy' },
        @{ Name = 'TrustedInstaller'; Desc = 'Windows Modules Installer' }
    )
    $repaired = @()
    foreach ($s in $services) {
        $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
        if ($null -eq $svc) { continue }
        if ($svc.StartType -eq 'Disabled') {
            Set-Service -Name $s.Name -StartupType Manual
            $repaired += $s.Desc
        }
        if ($svc.Status -ne 'Running') { try { Start-Service -Name $s.Name -ErrorAction Stop } catch {} }
    }
    if ($repaired.Count -gt 0) {
        Send-Telegram -Token $TgToken -ChatId $TgChatId -Text "[INFO] <b>Entorno reparado:</b> Se habilitaron: " + ($repaired -join ", ")
    }
}

function Invoke-WithRetry {
    param([scriptblock]$Script, [int]$MaxRetries = 3, [int]$WaitSecs = 15, $TgToken, $TgChatId, $Msg)
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try { return &$Script }
        catch {
            if ($i -eq $MaxRetries) { throw $_ }
            if ($Msg) { Send-Telegram -Token $TgToken -ChatId $TgChatId -Text "[WARN] <b>Reintentando ($i/$MaxRetries):</b> $Msg" }
            Start-Sleep -Seconds $WaitSecs
        }
    }
}

function Parse-BoolLikeValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    switch -Regex ($Value.Trim()) {
        '^(1|true|yes|on)$' { return $true }
        '^(0|false|no|off)$' { return $false }
        default { throw "Valor booleano no valido: $Value" }
    }
}

function Convert-ToSingleString {
    param(
        $Value,
        [string]$Name
    )

    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Array]) {
        $items = @($Value | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($items.Count -eq 0) { return $null }
        if ($items.Count -gt 1) {
            throw "$Name contiene multiples valores y no se puede resolver de forma segura."
        }
        return [string]$items[0]
    }

    return [string]$Value
}

function Convert-ToStringArray {
    param($Value)

    if ($null -eq $Value) { return @() }

    $result = @()
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $result += $text
    }

    return @($result)
}

function Wait-ForInternetAccess {
    param(
        [string[]]$ProbeUris,
        [int]$TimeoutSeconds = 600,
        $TgToken,
        $TgChatId
    )

    $targets = Convert-ToStringArray -Value $ProbeUris
    if ($targets.Count -eq 0 -or $TimeoutSeconds -le 0) { return }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null
    $waitingNotified = $false
    $nextNotification = Get-Date

    while ((Get-Date) -lt $deadline) {
        foreach ($target in $targets) {
            try {
                Invoke-WebRequest -Uri $target -Method Head -UseBasicParsing -TimeoutSec 10 | Out-Null
                if ($waitingNotified) {
                    Send-Telegram -Token $TgToken -ChatId $TgChatId -Text "[INFO] Conectividad detectada. Continuando provision."
                }
                return
            } catch {
                $lastError = $_.Exception.Message
                try {
                    Invoke-WebRequest -Uri $target -UseBasicParsing -TimeoutSec 10 | Out-Null
                    if ($waitingNotified) {
                        Send-Telegram -Token $TgToken -ChatId $TgChatId -Text "[INFO] Conectividad detectada. Continuando provision."
                    }
                    return
                } catch {
                    $lastError = $_.Exception.Message
                }
            }
        }

        if (-not $waitingNotified) {
            Send-Telegram -Token $TgToken -ChatId $TgChatId -Text "[INFO] Esperando conectividad de red antes de continuar con Tailscale."
            $waitingNotified = $true
            $nextNotification = (Get-Date).AddMinutes(1)
        } elseif ((Get-Date) -ge $nextNotification) {
            Send-Telegram -Token $TgToken -ChatId $TgChatId -Text "[WARN] Aun sin conectividad utilizable. Se mantiene espera de red."
            $nextNotification = (Get-Date).AddMinutes(1)
        }

        Start-Sleep -Seconds 5
    }

    $details = if ($lastError) { " Ultimo error: $lastError" } else { '' }
    throw "No hubo conectividad utilizable dentro de ${TimeoutSeconds}s.$details"
}

function Join-PathSafe {
    param(
        $BasePath,
        [string]$ChildPath,
        [string]$Label = 'ruta'
    )

    $resolvedBasePath = Convert-ToSingleString -Value $BasePath -Name $Label
    if ([string]::IsNullOrWhiteSpace($resolvedBasePath)) { return $null }
    return Join-Path -Path $resolvedBasePath -ChildPath $ChildPath
}

function Start-DeferredTaskCleanup {
    param(
        [string]$TargetDirectory,
        [string]$TelegramToken,
        [string]$TelegramChatId,
        [string]$LogFilePath,
        [string]$Label = 'directorio de trabajo',
        [int]$RetryCount = 180,
        [int]$DelaySeconds = 2
    )

    $resolvedTargetDirectory = Convert-ToSingleString -Value $TargetDirectory -Name 'Directorio de limpieza'
    if ([string]::IsNullOrWhiteSpace($resolvedTargetDirectory)) { return }

    $tempRoot = Join-PathSafe -BasePath $env:TEMP -ChildPath 'tailscale-provision-cleanup' -Label 'TEMP'
    if (-not (Test-Path $tempRoot)) { New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null }

    $cleanupGuid = [Guid]::NewGuid().ToString("N")
    $cleanupTaskName = "Cleanup-Tailscale-Workdir-$($cleanupGuid.Substring(0, 12))"
    $cleanupScript = Join-PathSafe -BasePath $tempRoot -ChildPath ("cleanup-task-" + $cleanupGuid + ".ps1") -Label 'Directorio temporal de limpieza'
    $scriptContent = @"
param(
    [string]`$TargetPath,
    [string]`$TelegramToken,
    [string]`$TelegramChatId,
    [string]`$LogFilePath,
    [string]`$Label,
    [string]`$CleanupTaskName,
    [int]`$RetryCount = $RetryCount,
    [int]`$DelaySeconds = $DelaySeconds,
    [switch]`$PersistedRun
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Send-TelegramMessage {
    param(`$Token, `$ChatId, `$Text)
    if (-not `$Token -or -not `$ChatId) { return }
    try {
        `$body = @{ chat_id = `$ChatId; text = `$Text; parse_mode = 'HTML' } | ConvertTo-Json
        Invoke-RestMethod -Uri "https://api.telegram.org/bot`$Token/sendMessage" -Method Post -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes(`$body)) -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

function Write-CleanupLog {
    param([string]`$Message)
    if (-not `$LogFilePath) { return }
    try {
        `$logDir = Split-Path -Path `$LogFilePath -Parent
        if (`$logDir -and -not (Test-Path `$logDir)) { New-Item -ItemType Directory -Path `$logDir -Force | Out-Null }
        Add-Content -Path `$LogFilePath -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `$Message) -Encoding ascii
    } catch {}
}

function Remove-TargetDirectory {
    `$script:LastRemoveError = `$null
    try {
        if (Test-Path -LiteralPath `$TargetPath) {
            Remove-Item -LiteralPath `$TargetPath -Recurse -Force -ErrorAction Stop
        }
    } catch {
        `$script:LastRemoveError = `$_.Exception.Message
    }
    return -not (Test-Path -LiteralPath `$TargetPath)
}

function Ensure-CleanupTask {
    if ([string]::IsNullOrWhiteSpace(`$CleanupTaskName)) { return }

    `$actionArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"`$PSCommandPath`" -TargetPath `"`$TargetPath`" -Label `"`$Label`" -RetryCount `$RetryCount -DelaySeconds `$DelaySeconds -CleanupTaskName `"`$CleanupTaskName`" -PersistedRun"
    if (`$TelegramToken) { `$actionArgs += " -TelegramToken `"`$TelegramToken`"" }
    if (`$TelegramChatId) { `$actionArgs += " -TelegramChatId `"`$TelegramChatId`"" }

    `$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument `$actionArgs
    `$triggers = @(
        (New-ScheduledTaskTrigger -AtStartup)
        (New-ScheduledTaskTrigger -AtLogOn)
    )
    `$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    `$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName `$CleanupTaskName -Action `$action -Trigger `$triggers -Principal `$principal -Settings `$settings -Description 'Limpieza diferida de tailscale-provision' -Force | Out-Null
    `$reason = if (`$script:LastRemoveError) { `$script:LastRemoveError } else { 'El directorio sigue en uso o bloqueado.' }
    Write-CleanupLog -Message ("Reprogramando limpieza de {0}. Motivo: {1}" -f `$Label, `$reason)
    Send-TelegramMessage -Token `$TelegramToken -ChatId `$TelegramChatId -Text "[WARN] No se pudo borrar $Label de inmediato. Se programo limpieza automatica al iniciar Windows. Revisa cleanup.log para el motivo."
}

Write-CleanupLog -Message ("Inicio de limpieza de {0}: {1}. PersistedRun={2}" -f `$Label, `$TargetPath, `$PersistedRun.IsPresent)

for (`$i = 1; `$i -le `$RetryCount; `$i++) {
    if (Remove-TargetDirectory) {
        if (`$PersistedRun -and `$CleanupTaskName) {
            Unregister-ScheduledTask -TaskName `$CleanupTaskName -Confirm:`$false -ErrorAction SilentlyContinue | Out-Null
        }
        Write-CleanupLog -Message ("Limpieza completada para {0}: {1}" -f `$Label, `$TargetPath)
        Send-TelegramMessage -Token `$TelegramToken -ChatId `$TelegramChatId -Text "[OK] Se elimino `${Label}: <code>`$TargetPath</code>"
        exit 0
    }
    if (`$script:LastRemoveError -and (`$i -eq 1 -or (`$i % 10) -eq 0)) {
        Write-CleanupLog -Message ("Intento {0} fallido para {1}. Motivo: {2}" -f `$i, `$Label, `$script:LastRemoveError)
    }
    Start-Sleep -Seconds `$DelaySeconds
}

if (-not `$PersistedRun) {
    Ensure-CleanupTask
} else {
    `$reason = if (`$script:LastRemoveError) { `$script:LastRemoveError } else { 'El directorio sigue en uso o bloqueado.' }
    Write-CleanupLog -Message ("PersistedRun agotado para {0}. Motivo: {1}" -f `$Label, `$reason)
    Send-TelegramMessage -Token `$TelegramToken -ChatId `$TelegramChatId -Text "[WARN] $Label sigue en uso. Se reintentara en el proximo inicio. Revisa cleanup.log para el motivo."
}
"@

    [System.IO.File]::WriteAllText($cleanupScript, $scriptContent, [System.Text.Encoding]::ASCII)

    $argumentList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$cleanupScript`" -TargetPath `"$resolvedTargetDirectory`" -Label `"$Label`" -RetryCount $RetryCount -DelaySeconds $DelaySeconds -CleanupTaskName `"$cleanupTaskName`""
    if ($TelegramToken) { $argumentList += " -TelegramToken `"$TelegramToken`"" }
    if ($TelegramChatId) { $argumentList += " -TelegramChatId `"$TelegramChatId`"" }
    if ($LogFilePath) { $argumentList += " -LogFilePath `"$LogFilePath`"" }

    Start-Process -FilePath powershell.exe -ArgumentList $argumentList -WorkingDirectory $env:SystemRoot -WindowStyle Hidden
}

function Get-TailscaleStatus {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    try {
        return (& $Path status --json | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-TailscaleService {
    foreach ($name in @('Tailscale', 'Tailscale IPN Service')) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($service) { return $service }
    }

    $matchedService = @(Get-Service | Where-Object {
        $_.Name -like 'Tailscale*' -or $_.DisplayName -like 'Tailscale*'
    } | Select-Object -First 1)

    if ($matchedService.Count -eq 0) { return $null }
    return $matchedService[0]
}

function Ensure-TailscaleServiceReady {
    param(
        [int]$TimeoutSeconds = 120,
        $TgToken,
        $TgChatId
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $service = $null

    while ((Get-Date) -lt $deadline) {
        $service = Get-TailscaleService
        if ($service) {
            if ($service.StartType -eq 'Disabled') {
                Set-Service -Name $service.Name -StartupType Automatic
            }

            if ($service.Status -ne 'Running') {
                try {
                    Start-Service -Name $service.Name -ErrorAction Stop
                } catch {}
            }

            $service.Refresh()
            if ($service.Status -eq 'Running') {
                return $service
            }
        }

        Start-Sleep -Seconds 3
    }

    $serviceSummary = if ($service) { "$($service.Name) / $($service.DisplayName)" } else { 'no detectado' }
    throw "El servicio de Tailscale no quedo operativo dentro de ${TimeoutSeconds}s. Servicio: $serviceSummary."
}

function Invoke-ExternalCommand {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    if (-not $FilePath -or -not (Test-Path $FilePath)) {
        throw "No se encontro el ejecutable: $FilePath"
    }

    $tempRoot = Join-PathSafe -BasePath $env:TEMP -ChildPath 'tailscale-provision-cmd' -Label 'TEMP'
    if (-not (Test-Path $tempRoot)) { New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null }

    $commandGuid = [Guid]::NewGuid().ToString('N')
    $stdoutFile = Join-PathSafe -BasePath $tempRoot -ChildPath ("stdout-" + $commandGuid + ".log") -Label 'TEMP'
    $stderrFile = Join-PathSafe -BasePath $tempRoot -ChildPath ("stderr-" + $commandGuid + ".log") -Label 'TEMP'

    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $stdout = if (Test-Path $stdoutFile) { [string](Get-Content $stdoutFile -Raw) } else { '' }
        $stderr = if (Test-Path $stderrFile) { [string](Get-Content $stderrFile -Raw) } else { '' }
        $combined = @(
            $stdout.Trim()
            $stderr.Trim()
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        return @{
            ExitCode = $process.ExitCode
            StdOut = $stdout
            StdErr = $stderr
            Combined = ($combined -join [Environment]::NewLine)
        }
    } finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Wait-ForTailscaleBackendState {
    param(
        [string]$Path,
        [string[]]$DesiredStates = @('Running'),
        [int]$TimeoutSeconds = 90
    )

    $expectedStates = Convert-ToStringArray -Value $DesiredStates
    if ($expectedStates.Count -eq 0) {
        throw "Debes indicar al menos un estado esperado de Tailscale."
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastState = 'desconocido'

    while ((Get-Date) -lt $deadline) {
        $status = Get-TailscaleStatus -Path $Path
        if ($status -and $status.BackendState) {
            $lastState = [string]$status.BackendState
            if ($expectedStates -contains $lastState) {
                return $status
            }
        }

        Start-Sleep -Seconds 3
    }

    throw "Tailscale no alcanzo el estado esperado ($($expectedStates -join ', ')). Estado final: $lastState."
}

function Get-OpenSshMsiAssetName {
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture

    switch ($architecture) {
        'Arm64' { return 'OpenSSH-ARM64' }
        'X64' { return 'OpenSSH-Win64' }
        'X86' { return 'OpenSSH-Win32' }
        'Arm' { return 'OpenSSH-ARM' }
        default { throw "Arquitectura no soportada para OpenSSH: $architecture" }
    }
}

function Get-LatestOpenSshRelease {
    $headers = @{
        'Accept' = 'application/vnd.github+json'
        'User-Agent' = 'tailscale-provision'
    }

    $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases' -Headers $headers -TimeoutSec 30
    $release = @($releases | Where-Object { -not $_.draft } | Select-Object -First 1)
    if ($release.Count -eq 0) {
        throw 'No se pudo determinar la ultima release publicada de PowerShell/Win32-OpenSSH.'
    }

    $release = $release[0]
    $assetPrefix = Get-OpenSshMsiAssetName
    $asset = @($release.assets | Where-Object { $_.name -like "$assetPrefix-*.msi" } | Select-Object -First 1)
    if ($asset.Count -eq 0) {
        throw "No se encontro un MSI oficial de OpenSSH para $assetPrefix en la release $($release.tag_name)."
    }

    return @{
        Tag = $release.tag_name
        Name = if ($release.name) { $release.name } else { $release.tag_name }
        IsPrerelease = [bool]$release.prerelease
        AssetName = $asset[0].name
        AssetUrl = $asset[0].browser_download_url
    }
}

function Get-OpenSshInstallDirectory {
    $programFiles = Convert-ToSingleString -Value $env:ProgramFiles -Name 'ProgramFiles'
    $programFilesX86 = Convert-ToSingleString -Value ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) -Name 'ProgramFiles(x86)'

    $candidates = @(
        (Join-PathSafe -BasePath $programFiles -ChildPath 'OpenSSH' -Label 'ProgramFiles')
        (Join-PathSafe -BasePath $programFiles -ChildPath 'OpenSSH-Win64' -Label 'ProgramFiles')
        (Join-PathSafe -BasePath $programFilesX86 -ChildPath 'OpenSSH-Win32' -Label 'ProgramFiles(x86)')
    ) | Where-Object { $_ }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Resolve-UserProfileInfo {
    param([string]$PreferredUser)

    $profiles = @(Get-CimInstance Win32_UserProfile |
        Where-Object { -not $_.Special -and $_.LocalPath -like 'C:\Users\*' } |
        Sort-Object LastUseTime -Descending)

    if ($profiles.Count -eq 0) {
        throw "No se encontro un perfil de usuario local utilizable."
    }

    $profile = $null
    if ($PreferredUser) {
        $profile = $profiles | Where-Object { (Split-Path $_.LocalPath -Leaf) -ieq $PreferredUser } | Select-Object -First 1
        if (-not $profile) {
            throw "No se encontro un perfil local para el usuario '$PreferredUser'."
        }
    } else {
        $profile = $profiles | Select-Object -First 1
    }

    return @{
        UserName = Split-Path $profile.LocalPath -Leaf
        ProfilePath = $profile.LocalPath
        Sid = $profile.SID
    }
}

function Add-AuthorizedKey {
    param(
        [string]$Path,
        [string]$PublicKey
    )

    $encoding = [System.Text.Encoding]::ASCII
    if (-not (Test-Path $Path)) {
        $parent = Split-Path $Path -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllText($Path, [string]::Empty, $encoding)
    }

    $existingKeys = @(Get-Content $Path -ErrorAction SilentlyContinue)
    if ($existingKeys -notcontains $PublicKey) {
        [System.IO.File]::AppendAllText($Path, $PublicKey + [Environment]::NewLine, $encoding)
        return $true
    }

    return $false
}

function Update-SshdConfig {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return }

    $output = [System.Collections.Generic.List[string]]::new()
    $hasPubkeyAuthentication = $false
    $hasPasswordAuthentication = $false

    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*#?\s*PubkeyAuthentication\b') {
            $output.Add('PubkeyAuthentication yes')
            $hasPubkeyAuthentication = $true
        } elseif ($line -match '^\s*#?\s*PasswordAuthentication\b') {
            $output.Add('PasswordAuthentication no')
            $hasPasswordAuthentication = $true
        } else {
            $output.Add($line)
        }
    }

    if (-not $hasPubkeyAuthentication) { $output.Add('PubkeyAuthentication yes') }
    if (-not $hasPasswordAuthentication) { $output.Add('PasswordAuthentication no') }

    Set-Content $Path -Value $output -Encoding ascii
}

# --- INICIO ---
$Dir = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
$EnvFile = if (-not $EnvFile) { Join-PathSafe -BasePath $Dir -ChildPath ".env" -Label "Directorio base del script" } else { $EnvFile }
$LogFile = if (-not $LogFile) { Join-PathSafe -BasePath $Dir -ChildPath "logs\provision.log" -Label "Directorio base del script" } else { $LogFile }
$CleanupLogFile = Join-PathSafe -BasePath (Split-Path $LogFile -Parent) -ChildPath "cleanup.log" -Label "Directorio de logs"

if (-not (Test-Path (Split-Path $LogFile))) { New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null }
Start-Transcript -Path $LogFile -Append -Force | Out-Null

$provisionSucceeded = $false

try {
    $ev = @{}
    if (Test-Path $EnvFile) {
        Get-Content $EnvFile | ForEach-Object {
            $l = $_.Trim(); if ($l -and -not $l.StartsWith('#')) {
                $s = $l.IndexOf('='); if ($s -gt 0) { $n = $l.Substring(0,$s).Trim(); $v = $l.Substring($s+1).Trim().Trim("'").Trim('"'); $ev[$n]=$v }
            }
        }
    }
    
    $TelegramToken = if ($TelegramToken) { $TelegramToken } else { $ev['TELEGRAM_BOT_TOKEN'] }
    $TelegramChatId = if ($TelegramChatId) { $TelegramChatId } else { $ev['TELEGRAM_CHAT_ID'] }
    $AuthKey = if ($AuthKey) { $AuthKey } else { $ev['TAILSCALE_AUTH_KEY'] }
    $SshKey = if ($SshPublicKey) { $SshPublicKey } else { $ev['SSH_PUBLIC_KEY'] }
    $User = if ($LocalAdminUser) { $LocalAdminUser } else { $ev['LOCAL_ADMIN_USER'] }
    $Hname = if ($Hostname) { $Hostname } else { $ev['TAILSCALE_HOSTNAME'] }
    $AdvertiseTags = if ($AdvertiseTags) { $AdvertiseTags } elseif ($ev['TAILSCALE_ADVERTISE_TAGS']) { @($ev['TAILSCALE_ADVERTISE_TAGS'] -split '\s*,\s*' | Where-Object { $_ }) } else { @() }
    $AdvertiseTags = Convert-ToStringArray -Value $AdvertiseTags
    $LoginServer = if ($LoginServer) { $LoginServer } else { $ev['TAILSCALE_LOGIN_SERVER'] }
    if (-not $PSBoundParameters.ContainsKey('AcceptRoutes')) {
        $AcceptRoutes = Parse-BoolLikeValue -Value $ev['TAILSCALE_ACCEPT_ROUTES']
    }

    if (-not (Test-IsAdministrator)) {
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[ERROR] El script requiere una consola elevada de Administrador."
        throw "Debes ejecutar install-tailscale-openssh.ps1 como Administrador."
    }

    Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Consola elevada confirmada."

    # 1. Validar version de Windows
    $os = Get-OSInfo
    if (-not $os.IsSupported) {
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[ERROR] <b>Version no soportada:</b> $($os.Name) ($($os.Version)). El script requiere Windows 10 o superior."
        throw "OS no soportado."
    }

    # 2. Reparar entorno
    Prepare-Environment -TgToken $TelegramToken -TgChatId $TelegramChatId

    $effectiveHostname = if ([string]::IsNullOrWhiteSpace($Hname)) { $env:COMPUTERNAME } else { $Hname }
    $tagSummary = if (@($AdvertiseTags).Count -gt 0) { $AdvertiseTags -join ',' } else { 'ninguno' }
    $routeSummary = if ($null -eq $AcceptRoutes) { 'sin cambio' } else { $AcceptRoutes.ToString().ToLowerInvariant() }
    $loginServerSummary = if ($LoginServer) { $LoginServer } else { 'default' }
    $networkProbeUris = @()
    if ($LoginServer) {
        $networkProbeUris += $LoginServer
    } else {
        $networkProbeUris += 'https://login.tailscale.com/'
        $networkProbeUris += 'https://controlplane.tailscale.com/'
    }
    $networkProbeUris += 'https://pkgs.tailscale.com/'
    Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "<b>[RUN]</b> Iniciando provision en <code>$env:COMPUTERNAME</code>`nS.O.: <code>$($os.Name)</code>"
    Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Parametros: hostname=<code>$effectiveHostname</code>, tags=<code>$tagSummary</code>, login-server=<code>$loginServerSummary</code>, accept-routes=<code>$routeSummary</code>"
    Wait-ForInternetAccess -ProbeUris $networkProbeUris -TimeoutSeconds $InternetWaitTimeoutSeconds -TgToken $TelegramToken -TgChatId $TelegramChatId

    # 3. Tailscale
    $tsPaths = @()
    $programFiles = Convert-ToSingleString -Value $env:ProgramFiles -Name 'ProgramFiles'
    $programFilesX86 = Convert-ToSingleString -Value ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) -Name 'ProgramFiles(x86)'
    $primaryTailscalePath = Join-PathSafe -BasePath $programFiles -ChildPath 'Tailscale\tailscale.exe' -Label 'ProgramFiles'
    $secondaryTailscalePath = Join-PathSafe -BasePath $programFilesX86 -ChildPath 'Tailscale\tailscale.exe' -Label 'ProgramFiles(x86)'
    if ($primaryTailscalePath) { $tsPaths += $primaryTailscalePath }
    if ($secondaryTailscalePath -and $secondaryTailscalePath -ne $primaryTailscalePath) { $tsPaths += $secondaryTailscalePath }
    $ts = $null; foreach ($p in $tsPaths) { if (Test-Path $p) { $ts = $p } }
    if ($ts) { Ensure-TailscaleServiceReady -TimeoutSeconds 120 -TgToken $TelegramToken -TgChatId $TelegramChatId | Out-Null }
    $tsStatus = Get-TailscaleStatus -Path $ts

    if ($ts) {
        $backendState = if ($tsStatus -and $tsStatus.BackendState) { $tsStatus.BackendState } else { 'desconocido' }
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Tailscale detectado en <code>$ts</code>. Estado actual: <code>$backendState</code>"
    } else {
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Tailscale no esta instalado. Se intentara descargar e instalar."
    }

    if (-not $ts -and -not $SkipTailscaleInstall) {
        if (-not $AuthKey) { throw "Falta TAILSCALE_AUTH_KEY para instalar y registrar Tailscale." }
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Descargando Tailscale..."
        $url = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { "https://pkgs.tailscale.com/$TailscaleTrack/tailscale-setup-latest-arm64.msi" } else { "https://pkgs.tailscale.com/$TailscaleTrack/tailscale-setup-latest-amd64.msi" }
        Invoke-WithRetry -TgToken $TelegramToken -TgChatId $TelegramChatId -Msg "Descarga de Tailscale" -Script {
            Invoke-WebRequest -Uri $url -OutFile $InstallerPath -UseBasicParsing -TimeoutSec 120
        }
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Instalando Tailscale..."
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$InstallerPath`" /qn TS_NOLAUNCH=1" -Wait -PassThru
        if ($p.ExitCode -notin @(0, 3010)) { throw "Error MSI Tailscale: $($p.ExitCode)" }
        foreach ($p in $tsPaths) { if (Test-Path $p) { $ts = $p } }
        if ($ts) { Ensure-TailscaleServiceReady -TimeoutSeconds 120 -TgToken $TelegramToken -TgChatId $TelegramChatId | Out-Null }
        $tsStatus = Get-TailscaleStatus -Path $ts
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[OK] Tailscale instalado correctamente."
    }

    if ($ts -and (($null -eq $tsStatus) -or $tsStatus.BackendState -ne 'Running')) {
        if (-not $AuthKey) { throw "Falta TAILSCALE_AUTH_KEY para levantar Tailscale." }
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Conectando a Tailscale..."
        $args = @('up', "--auth-key=$AuthKey", '--unattended=true')
        if ($Hname) { $args += "--hostname=$Hname" }
        if (@($AdvertiseTags).Count -gt 0) { $args += "--advertise-tags=$($AdvertiseTags -join ',')" }
        if ($LoginServer) { $args += "--login-server=$LoginServer" }
        if ($null -ne $AcceptRoutes) { $args += "--accept-routes=$($AcceptRoutes.ToString().ToLowerInvariant())" }
        $tailscaleUp = Invoke-ExternalCommand -FilePath $ts -ArgumentList $args
        if ($tailscaleUp.ExitCode -ne 0) {
            $tailscaleDetails = if ([string]::IsNullOrWhiteSpace($tailscaleUp.Combined)) { 'sin salida adicional.' } else { $tailscaleUp.Combined }
            throw "tailscale up devolvio codigo $($tailscaleUp.ExitCode). Detalle: $tailscaleDetails"
        }
        $tsStatus = Wait-ForTailscaleBackendState -Path $ts -DesiredStates @('Running') -TimeoutSeconds 90
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[OK] Tailscale conectado. Estado: <code>$($tsStatus.BackendState)</code>"
    } elseif ($ts) {
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Tailscale ya estaba operativo. No fue necesario reconectar."
    }

    # 4. OpenSSH
    if (-not $SkipOpenSSHInstall) {
        $openSshInstallerPath = Join-PathSafe -BasePath $env:TEMP -ChildPath 'openssh-latest.msi' -Label 'TEMP'
        $openSshRelease = Invoke-WithRetry -TgToken $TelegramToken -TgChatId $TelegramChatId -Msg "Consulta de release oficial de OpenSSH" -Script {
            Get-LatestOpenSshRelease
        }
        $releaseSummary = if ($openSshRelease.IsPrerelease) {
            "$($openSshRelease.Tag) (preview)"
        } else {
            $openSshRelease.Tag
        }

        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Descargando OpenSSH oficial desde GitHub: <code>$releaseSummary</code>."
        Invoke-WithRetry -TgToken $TelegramToken -TgChatId $TelegramChatId -Msg "Descarga de OpenSSH oficial" -Script {
            Invoke-WebRequest -Uri $openSshRelease.AssetUrl -OutFile $openSshInstallerPath -UseBasicParsing -TimeoutSec 120
        }

        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Instalando OpenSSH oficial: <code>$($openSshRelease.AssetName)</code>."
        $openSshInstall = Start-Process msiexec.exe -ArgumentList "/i `"$openSshInstallerPath`" /qn" -Wait -PassThru
        if ($openSshInstall.ExitCode -notin @(0, 3010)) {
            throw "Error MSI OpenSSH: $($openSshInstall.ExitCode)"
        }

        $sshdService = Get-Service -Name sshd -ErrorAction SilentlyContinue
        if ($null -eq $sshdService) {
            $openSshInstallDir = Get-OpenSshInstallDirectory
            $installSshdScript = if ($openSshInstallDir) { Join-PathSafe -BasePath $openSshInstallDir -ChildPath 'install-sshd.ps1' -Label 'Directorio OpenSSH' } else { $null }
            if ($installSshdScript -and (Test-Path -LiteralPath $installSshdScript)) {
                Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Ejecutando post-instalacion oficial de OpenSSH."
                $postInstall = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$installSshdScript`"" -Wait -PassThru -WindowStyle Hidden
                if ($postInstall.ExitCode -ne 0) {
                    throw "La post-instalacion de OpenSSH fallo con codigo $($postInstall.ExitCode)."
                }
            }
        }

        $sshdService = Get-Service -Name sshd -ErrorAction SilentlyContinue
        if ($null -eq $sshdService) {
            throw 'OpenSSH se instalo, pero el servicio sshd no quedo disponible.'
        }

        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[OK] OpenSSH oficial instalado o actualizado a <code>$releaseSummary</code>."
    } else {
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Se omite la instalacion de OpenSSH por parametro."
    }

    # 5. Configuracion
    Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Configurando acceso final..."
    if (-not $SshKey) {
        throw "Falta SSH_PUBLIC_KEY para habilitar el acceso por clave."
    }
    $profileInfo = Resolve-UserProfileInfo -PreferredUser $User
    $User = $profileInfo.UserName
    $sid = $profileInfo.Sid
    $prof = Convert-ToSingleString -Value ([System.Environment]::ExpandEnvironmentVariables($profileInfo.ProfilePath)) -Name 'Ruta del perfil de usuario'
    $sdir = Join-PathSafe -BasePath $prof -ChildPath '.ssh' -Label 'Ruta del perfil de usuario'
    $akey = Join-PathSafe -BasePath $sdir -ChildPath 'authorized_keys' -Label 'Directorio .ssh'
    if (-not (Test-Path $sdir)) { New-Item -ItemType Directory -Path $sdir -Force | Out-Null }
    Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Perfil objetivo: usuario=<code>$User</code>, ruta=<code>$prof</code>"

    $keyAdded = Add-AuthorizedKey -Path $akey -PublicKey $SshKey
    if ($keyAdded) {
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[OK] Clave SSH agregada a <code>$akey</code>"
    } else {
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] La clave SSH ya existia en <code>$akey</code>"
    }

    & icacls.exe $sdir /inheritance:r /grant:r "*${sid}:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "SYSTEM:(OI)(CI)F" /Q | Out-Null
    & icacls.exe $akey /inheritance:r /grant:r "*${sid}:F" "*S-1-5-32-544:F" "SYSTEM:F" /Q | Out-Null

    $conf = 'C:\ProgramData\ssh\sshd_config'
    Update-SshdConfig -Path $conf
    Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Configuracion SSH actualizada y permisos aplicados."
    
    Set-Service sshd -StartupType Automatic; Start-Service sshd -ErrorAction SilentlyContinue; Restart-Service sshd
    Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Servicio sshd iniciado y reiniciado correctamente."
    
    if (-not (Get-NetFirewallRule -Name "SSH-In" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "SSH-In" -DisplayName "SSH Port 22" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[OK] Regla de firewall SSH-In creada."
    } else {
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] La regla de firewall SSH-In ya existia."
    }

    $ip = if ($ts) { & $ts ip -4 } else { "N/A" }
    Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[OK] <b>PROVISION EXITOSA</b>`nIP: <code>$ip</code>"
    $provisionSucceeded = $true

} catch {
    $err = $_.Exception.Message
    $line = $_.InvocationInfo.ScriptLineNumber
    $command = if ($_.InvocationInfo.Line) { $_.InvocationInfo.Line.Trim() } else { 'N/D' }
    $errorSummary = "Linea $line. $err"
    Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[ERROR] <b>ERROR TERMINAL</b>`nDetalle: <code>$errorSummary</code>"
    if ($Global:TgFailCount -gt 0) {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $errorLogPath = Join-PathSafe -BasePath $desktop -ChildPath "PROVISION_ERROR_LOG.txt" -Label 'Escritorio'
        if ($errorLogPath) {
            Copy-Item $LogFile $errorLogPath -Force -ErrorAction SilentlyContinue
        }
    }
    throw "$errorSummary Comando: $command"
} finally {
    Stop-Transcript | Out-Null
    if ($Cleanup -and $provisionSucceeded) {
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[INFO] Provision completada. Se inicia limpieza final del directorio de trabajo."
        Add-Content -Path $CleanupLogFile -Value ("[{0}] Solicitud de limpieza para directorio de trabajo: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Dir) -Encoding ascii
        Unregister-ScheduledTask -TaskName "Provision-Tailscale-SSH" -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Start-DeferredTaskCleanup -TargetDirectory $Dir -TelegramToken $TelegramToken -TelegramChatId $TelegramChatId -LogFilePath $CleanupLogFile -Label 'directorio de trabajo'
    } elseif ($Cleanup) {
        Send-Telegram -Token $TelegramToken -ChatId $TelegramChatId -Text "[WARN] La provision no finalizo correctamente. Se conserva la carpeta copiada para diagnostico o reintento."
    }
}
