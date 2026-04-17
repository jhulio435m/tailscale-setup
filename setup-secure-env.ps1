[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Importar módulo de seguridad
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand }
$securityModule = Join-Path $scriptDir 'security.ps1'

if (-not (Test-Path -LiteralPath $securityModule)) {
    throw "Módulo de seguridad no encontrado: $securityModule"
}

. $securityModule

# ============================================================================
# SETUP INTERACTIVO
# ============================================================================

Write-Host "╔════════════════════════════════════════════════════════════════╗"
Write-Host "║     CONFIGURACIÓN DE SEGURIDAD - CRIPTOGRAFÍA EN .ENV         ║"
Write-Host "╚════════════════════════════════════════════════════════════════╝"
Write-Host ""

$envPath = Join-Path $scriptDir '.env'

if (-not (Test-Path -LiteralPath $envPath)) {
    Write-Host "❌ No se encontro el archivo .env" -ForegroundColor Red
    exit 1
}

Write-Host "📄 Archivo .env encontrado: $envPath"
Write-Host ""

# Verificar si ya está encriptado
$firstLine = Get-Content -LiteralPath $envPath -TotalCount 1
if ($firstLine -like '*[ENC]*') {
    Write-Host "⚠️  El archivo ya parece estar encriptado" -ForegroundColor Yellow
    $response = Read-Host "¿Deseas reconvertirlo? (s/n)"
    if ($response -ne 's' -and $response -ne 'S') {
        exit 0
    }
}

Write-Host ""
Write-Host "🔐 CAMPOS QUE SERÁN ENCRIPTADOS:" -ForegroundColor Cyan
$sensitiveFields = @(
    'TELEGRAM_BOT_TOKEN',
    'TELEGRAM_CHAT_ID',
    'TAILSCALE_AUTH_KEY',
    'SSH_PUBLIC_KEY',
    'WBPV_EXTRACT_PASSWORD',
    'LOCAL_ADMIN_USER'
)

$sensitiveFields | ForEach-Object { Write-Host "   • $_" }
Write-Host ""

Write-Host "ℹ️  INFORMACIÓN IMPORTANTE:" -ForegroundColor Yellow
Write-Host "   • La encriptación usa DPAPI de Windows"
Write-Host "   • Solo este usuario/máquina puede desencriptar"
Write-Host "   • Se creará un backup con extensión .backup"
Write-Host "   • Los permisos del archivo se restringirán (solo SYSTEM y Admins)"
Write-Host ""

$confirm = Read-Host "¿Proceder con la encriptación? (s/n)"
if ($confirm -ne 's' -and $confirm -ne 'S') {
    Write-Host "Operación cancelada."
    exit 0
}

Write-Host ""
Write-Host "🔄 Procesando..." -ForegroundColor Cyan

try {
    Convert-EnvToSecure -Path $envPath -SensitiveFields $sensitiveFields
    
    Write-Host ""
    Write-Host "✅ ÉXITO - Archivo encriptado" -ForegroundColor Green
    Write-Host ""
    Write-Host "📋 PRÓXIMOS PASOS:" -ForegroundColor Green
    Write-Host "   1. Los scripts (.ps1) ahora desencriptarán automáticamente"
    Write-Host "   2. El archivo .env es legible pero valores están cifrados"
    Write-Host "   3. Si cambias de usuario/máquina, necesitarás usar el backup"
    Write-Host ""
    Write-Host "🔒 SEGURIDAD:" -ForegroundColor Cyan
    Write-Host "   • El backup está en: $(Join-Path $scriptDir '.env.backup')"
    Write-Host "   • Guárdalo en lugar seguro si cambias de máquina"
    Write-Host "   • Nunca compartas el .env encriptado entre máquinas"
    Write-Host ""
    
} catch {
    Write-Host "❌ ERROR: $_" -ForegroundColor Red
    exit 1
}
