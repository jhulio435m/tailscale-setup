[CmdletBinding()]
param(
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Resolve-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    try {
        return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath.TrimEnd('\')
    } catch {
        try {
            return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        } catch {
            return $Path.TrimEnd('\')
        }
    }
}

function Test-PathsEqual {
    param(
        [string]$Left,
        [string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }

    return [string]::Equals(
        (Resolve-NormalizedPath -Path $Left),
        (Resolve-NormalizedPath -Path $Right),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Import-DotEnv {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return @{} }

    $values = @{}
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }

        $separator = $line.IndexOf('=')
        if ($separator -le 0) { return }

        $name = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim().Trim("'").Trim('"')
        
        # Si comienza con [ENC], desencriptar usando DPAPI
        if ($value.StartsWith('[ENC]')) {
            $encryptedValue = $value.Substring(5)  # Remover [ENC] prefix
            try {
                $encryptedBytes = [Convert]::FromBase64String($encryptedValue)
                $decryptedBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                    $encryptedBytes,
                    $null,
                    [System.Security.Cryptography.DataProtectionScope]::CurrentUser
                )
                $value = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
            } catch {
                Write-Host "⚠️  No se pudo desencriptar $name, ignorando" -ForegroundColor Yellow
            }
        }
        
        if ($name) { $values[$name] = $value }
    }

    return $values
}

function Send-TelegramMessage {
    param(
        [string]$Token,
        [string]$ChatId,
        [string]$Text
    )

    if (-not $Token -or -not $ChatId -or -not $Text) { return }

    try {
        $body = @{
            chat_id = $ChatId
            text = $Text
            parse_mode = 'HTML'
            disable_web_page_preview = $true
        } | ConvertTo-Json

        Invoke-RestMethod `
            -Uri "https://api.telegram.org/bot$Token/sendMessage" `
            -Method Post `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
            -TimeoutSec 5 | Out-Null
    } catch {}
}

function Get-SharedSystemDataRoot {
    $candidates = @(
        $env:ProgramData,
        [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData),
        'C:\ProgramData'
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return 'C:\ProgramData'
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-PowerShellArgument {
    param([string]$Value)

    if ($null -eq $Value) { return '""' }

    return '"' + ($Value -replace '"', '""') + '"'
}

function Add-ArgumentPair {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return }

    $Arguments.Add("-$Name")
    $Arguments.Add((Quote-PowerShellArgument -Value $Value))
}

function Test-HasEnvValue {
    param(
        [hashtable]$Values,
        [string]$Name
    )

    return $Values.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace($Values[$Name])
}

function Set-RestrictedSecretAcl {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' /Q | Out-Null
}

function Start-DetachedDirectoryRemoval {
    param(
        [string]$TargetPath,
        [string]$LogFilePath,
        [string]$TelegramToken,
        [string]$TelegramChatId,
        [string]$Label = 'directorio de origen',
        [int]$RetryCount = 30,
        [int]$DelaySeconds = 2
    )

    $resolvedTargetPath = Resolve-NormalizedPath -Path $TargetPath
    if ([string]::IsNullOrWhiteSpace($resolvedTargetPath) -or -not (Test-Path -LiteralPath $resolvedTargetPath)) { return }

    $tempRoot = Join-Path $env:TEMP 'tailscale-provision-cleanup'
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    }

    $cleanupScript = Join-Path $tempRoot ("cleanup-source-" + [Guid]::NewGuid().ToString('N') + '.ps1')
    $scriptContent = @"
param(
    [string]`$TargetPath,
    [string]`$LogFilePath,
    [string]`$TelegramToken,
    [string]`$TelegramChatId,
    [string]`$Label,
    [int]`$RetryCount = $RetryCount,
    [int]`$DelaySeconds = $DelaySeconds
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Send-TelegramMessage {
    param(
        [string]`$Token,
        [string]`$ChatId,
        [string]`$Text
    )

    if (-not `$Token -or -not `$ChatId -or -not `$Text) { return }

    try {
        `$body = @{
            chat_id = `$ChatId
            text = `$Text
            parse_mode = 'HTML'
            disable_web_page_preview = `$true
        } | ConvertTo-Json

        Invoke-RestMethod -Uri "https://api.telegram.org/bot`$Token/sendMessage" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes(`$body)) -TimeoutSec 5 | Out-Null
    } catch {}
}

function Write-CleanupLog {
    param([string]`$Message)

    if (-not `$LogFilePath) { return }

    try {
        `$logDir = Split-Path -Path `$LogFilePath -Parent
        if (`$logDir -and -not (Test-Path -LiteralPath `$logDir)) {
            New-Item -ItemType Directory -Path `$logDir -Force | Out-Null
        }

        Add-Content -Path `$LogFilePath -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `$Message) -Encoding ascii
    } catch {}
}

Write-CleanupLog -Message ("Inicio de limpieza para {0}: {1}" -f `$Label, `$TargetPath)
Start-Sleep -Seconds 3

for (`$i = 1; `$i -le `$RetryCount; `$i++) {
    `$lastError = `$null

    try {
        if (Test-Path -LiteralPath `$TargetPath) {
            Remove-Item -LiteralPath `$TargetPath -Recurse -Force -ErrorAction Stop
        }
    } catch {
        `$lastError = `$_.Exception.Message
    }

    if (-not (Test-Path -LiteralPath `$TargetPath)) {
        Write-CleanupLog -Message ("Limpieza completada para {0}: {1}" -f `$Label, `$TargetPath)
        Send-TelegramMessage -Token `$TelegramToken -ChatId `$TelegramChatId -Text "[OK] Se elimino `$Label: <code>`$TargetPath</code>"
        exit 0
    }

    if (`$lastError -and (`$i -eq 1 -or `$i -eq `$RetryCount)) {
        Write-CleanupLog -Message ("Intento {0} fallido para {1}. Motivo: {2}" -f `$i, `$Label, `$lastError)
    }

    Start-Sleep -Seconds `$DelaySeconds
}

Write-CleanupLog -Message ("No se pudo eliminar {0}: {1}" -f `$Label, `$TargetPath)
Send-TelegramMessage -Token `$TelegramToken -ChatId `$TelegramChatId -Text "[WARN] No se pudo eliminar `$Label. Revisa <code>`$LogFilePath</code>."
exit 1
"@

    [System.IO.File]::WriteAllText($cleanupScript, $scriptContent, [System.Text.Encoding]::ASCII)

    $argumentList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$cleanupScript`" -TargetPath `"$resolvedTargetPath`" -Label `"$Label`" -RetryCount $RetryCount -DelaySeconds $DelaySeconds"
    if ($LogFilePath) { $argumentList += " -LogFilePath `"$LogFilePath`"" }
    if ($TelegramToken) { $argumentList += " -TelegramToken `"$TelegramToken`"" }
    if ($TelegramChatId) { $argumentList += " -TelegramChatId `"$TelegramChatId`"" }

    Start-Process -FilePath powershell.exe -ArgumentList $argumentList -WorkingDirectory $env:SystemRoot -WindowStyle Hidden
}

$TaskName = 'Provision-Tailscale-SSH'
$SourceDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }
$SourceEnvFile = Join-Path $SourceDir '.env'
$PermanentDir = Join-Path (Get-SharedSystemDataRoot) 'tailscale-provision'
$LogsDir = Join-Path $PermanentDir 'logs'
$CleanupLogFile = Join-Path $LogsDir 'cleanup.log'
$ProvisionLogFile = Join-Path $LogsDir 'provision.log'
$ScriptPath = Join-Path $PermanentDir 'install-tailscale-openssh.ps1'
$PermanentEnvFile = Join-Path $PermanentDir '.env'
$SourceInstallScript = Join-Path $SourceDir 'install-tailscale-openssh.ps1'

$envValues = Import-DotEnv -Path $SourceEnvFile
$tgToken = $envValues['TELEGRAM_BOT_TOKEN']
$tgChatId = $envValues['TELEGRAM_CHAT_ID']

if (-not (Test-IsAdministrator)) {
    Send-TelegramMessage -Token $tgToken -ChatId $tgChatId -Text '[ERROR] El instalador requiere permisos de Administrador.'
    throw 'Debes ejecutar create-task.ps1 como Administrador.'
}

$sourceIsPermanent = Test-PathsEqual -Left $SourceDir -Right $PermanentDir

if ($tgToken -and $tgChatId) {
    Send-TelegramMessage -Token $tgToken -ChatId $tgChatId -Text "<b>[SETUP]</b> Preparando copia de trabajo en <code>$PermanentDir</code>..."
}

if (-not (Test-Path -LiteralPath $SourceInstallScript)) {
    throw "No se encontro el instalador esperado en el origen: $SourceInstallScript"
}

if (-not (Test-Path -LiteralPath $SourceEnvFile)) {
    throw "No se encontro el archivo .env esperado en el origen: $SourceEnvFile"
}

$missingRequired = [System.Collections.Generic.List[string]]::new()
if (-not (Test-HasEnvValue -Values $envValues -Name 'TAILSCALE_AUTH_KEY')) { $missingRequired.Add('TAILSCALE_AUTH_KEY') }
if (-not (Test-HasEnvValue -Values $envValues -Name 'SSH_PUBLIC_KEY')) { $missingRequired.Add('SSH_PUBLIC_KEY') }

if ($missingRequired.Count -gt 0) {
    throw "Faltan variables requeridas en .env: $($missingRequired -join ', ')"
}

if (-not $sourceIsPermanent) {
    if (Test-Path -LiteralPath $PermanentDir) {
        Remove-Item -LiteralPath $PermanentDir -Recurse -Force
    }

    New-Item -ItemType Directory -Path $PermanentDir -Force | Out-Null
    Write-Host "Copiando instalador y .env a $PermanentDir ..."
    Copy-Item -LiteralPath $SourceInstallScript -Destination $ScriptPath -Force
    Copy-Item -LiteralPath $SourceEnvFile -Destination $PermanentEnvFile -Force
} else {
    Write-Host 'La carpeta de trabajo ya es la carpeta permanente.'
}

if (-not (Test-Path -LiteralPath $LogsDir)) {
    New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "No se encontro el script principal esperado: $ScriptPath"
}

if (-not (Test-Path -LiteralPath $PermanentEnvFile)) {
    throw "No se pudo preparar el archivo .env persistente: $PermanentEnvFile"
}

Set-RestrictedSecretAcl -Path $PermanentEnvFile

$actionArgsList = [System.Collections.Generic.List[string]]::new()
$actionArgsList.Add('-ExecutionPolicy')
$actionArgsList.Add('Bypass')
$actionArgsList.Add('-WindowStyle')
$actionArgsList.Add('Hidden')
$actionArgsList.Add('-File')
$actionArgsList.Add((Quote-PowerShellArgument -Value $ScriptPath))
$actionArgsList.Add('-LogFile')
$actionArgsList.Add((Quote-PowerShellArgument -Value $ProvisionLogFile))
$actionArgsList.Add('-EnvFile')
$actionArgsList.Add((Quote-PowerShellArgument -Value $PermanentEnvFile))

if ($Clean) {
    $actionArgsList.Add('-Cleanup')
}

$actionArgs = $actionArgsList -join ' '
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $actionArgs
$trigger = New-ScheduledTaskTrigger -AtStartup -RandomDelay (New-TimeSpan -Seconds 30)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -Hidden `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Provision de Tailscale' `
    -Force | Out-Null

if ($Clean -and -not $sourceIsPermanent) {
    Add-Content -Path $CleanupLogFile -Value ("[{0}] Solicitud de limpieza para directorio de origen: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $SourceDir) -Encoding ascii
    Start-DetachedDirectoryRemoval `
        -TargetPath $SourceDir `
        -LogFilePath $CleanupLogFile `
        -TelegramToken $tgToken `
        -TelegramChatId $tgChatId `
        -Label 'directorio de origen'
}

if ($tgToken -and $tgChatId) {
    $message = if ($sourceIsPermanent) {
        "[OK] Tarea registrada correctamente en <code>$PermanentDir</code>."
    } elseif ($Clean) {
        "[OK] Tarea registrada correctamente. Se copiaron <code>install-tailscale-openssh.ps1</code> y <code>.env</code> a <code>$PermanentDir</code>, y se inicio la limpieza del origen en segundo plano."
    } else {
        "[OK] Tarea registrada correctamente. Se copiaron <code>install-tailscale-openssh.ps1</code> y <code>.env</code> a <code>$PermanentDir</code>."
    }

    Send-TelegramMessage -Token $tgToken -ChatId $tgChatId -Text $message
}

Write-Host 'Proceso completado con exito.'
