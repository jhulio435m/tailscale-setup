# 🔐 GUÍA DE SEGURIDAD - CRIPTOGRAFÍA EN .ENV

## 📋 Descripción

Este sistema protege tus credenciales sensibles en el archivo `.env` usando:

- **DPAPI (Data Protection API)** de Windows
- **Encriptación AES automática** por el sistema operativo
- **Permisos restringidos** (solo SYSTEM y Administrators)

## 🚀 INSTALACIÓN RÁPIDA

### 1️⃣ ENCRIPTAR TU .ENV

```powershell
# Navega al directorio del proyecto
cd C:\Users\USER\tailscale-provision

# Ejecuta el setup
.\setup-secure-env.ps1
```

**Esto hará:**
- ✅ Crear backup en `.env.backup`
- ✅ Encriptar campos sensibles
- ✅ Restringir permisos del archivo
- ✅ Marcar valores con `[ENC]`

### 2️⃣ TUS SCRIPTS SE DESENCRIPTARÁN AUTOMÁTICAMENTE

Una vez encriptado, los scripts (`wbpv`, `create-wbpv-task.ps1`, etc.) 
desencriptarán los valores automáticamente:

```powershell
# Los scripts ahora funcionan igual
.\wbpv
# Los valores [ENC]... se desencriptan transparentemente ✅
```

---

## 🔍 ¿QUÉ SE ENCRIPTA?

Por defecto, estos campos son **ENCRIPTADOS**:

```
TELEGRAM_BOT_TOKEN         → Tu token de Telegram
TELEGRAM_CHAT_ID           → Tu chat ID
TAILSCALE_AUTH_KEY         → Key de autenticación
SSH_PUBLIC_KEY             → Tu llave SSH pública
WBPV_EXTRACT_PASSWORD      → Password de extracción
LOCAL_ADMIN_USER           → Usuario administrador (opcional)
```

Otros campos (rutas, valores públicos) NO se encriptan.

---

## 📄 EJEMPLO DE .ENV ENCRIPTADO

**ANTES:**
```env
TELEGRAM_BOT_TOKEN=8693887720:AAE7Cffa6mIASLImckNN17aryG-4CGlXL0Q
SSH_PUBLIC_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...
```

**DESPUÉS:**
```env
# WebBrowserPassView & Tailscale Configuration
# NOTA: Los valores con [ENC] están encriptados con DPAPI
# Fecha de generación: 2026-04-14 10:30:45

TELEGRAM_BOT_TOKEN=[ENC]AgIJ7K8mQ9p2X5L9R3W1v8...long base64 string...
TELEGRAM_CHAT_ID=[ENC]DfK3j9Lp8N2M5X6Y7Z1Q4...long base64 string...
SSH_PUBLIC_KEY=[ENC]AqLkP0Z8V5B3G7H1I9J2K6...long base64 string...
WBPV_EXTRACT_PASSWORD=[ENC]FmWnZ4C6D8E2A5B9F1G7...long base64 string...
LOCAL_ADMIN_USER=[ENC]HsX3P9L2K6M8N1A4B7C5...long base64 string...

# Campos públicos (sin encriptar)
WBPV_TOOLS_DIR=C:\Users\USER\Downloads\Herramientas
WBPV_EXECUTABLE_PATH=C:\Users\USER\Downloads\Herramientas\WebBrowserPassView.exe
WBPV_OUTPUT_PATH=C:\Users\USER\Downloads\Herramientas\mis_passwords.json
```

---

## 🔒 CÓMO FUNCIONA LA CRIPTOGRAFÍA

### DPAPI (Data Protection API)

```
┌─────────────────────────────────────────────┐
│ Tu valor secreto                             │
│ "8693887720:AAE7Cffa6mIASLImckNN17aryG..."  │
└────────────────────┬────────────────────────┘
                     │
                     ▼
      ┌──────────────────────────┐
      │  DPAPI Encryption        │
      │  (Windows SecureString)  │
      └────────────┬─────────────┘
                   │
                   ▼
      Encriptado con clave del USUARIO/MÁQUINA
      Solo ESTE usuario puede desencriptar
                   │
                   ▼
      [ENC]AgIJ7K8mQ9p2X5L9R3W1v8...
      (almacenado en .env)
```

**Ventajas:**
- ✅ Clave automática del sistema
- ✅ Solo el usuario/máquina que encriptó puede desencriptar
- ✅ No requiere password manual
- ✅ Nativo de Windows (no necesita librerías externas)

---

## 📌 CASOS DE USO

### ✅ PERMITIDO

```powershell
# Encriptación en tu máquina
.\setup-secure-env.ps1

# Ejecutar scripts (desencriptan automáticamente)
.\wbpv
.\create-wbpv-task.ps1 -Clean
```

### ❌ NO FUNCIONARÁ

```powershell
# Copiar .env encriptado a OTRA máquina
# ❌ No se puede desencriptar (clave diferente)

# Cambiar de usuario en la MISMA máquina
# ⚠️ Dependiendo de configuración, puede no funcionar
```

---

## 🔑 GESTIÓN DE BACKUPS

### Guardar backup seguro

```powershell
# Se crea automáticamente
Copy-Item ".env.backup" "D:\backups\env-2026-04-14.backup" -Force

# Guardar en USB encrypted / cloud storage
```

### Restaurar desde backup

```powershell
# Si perdiste la encriptación
Copy-Item ".env.backup" ".env" -Force

# Y vuelve a encriptar
.\setup-secure-env.ps1
```

---

## ⚙️ CONFIGURACIÓN AVANZADA

### Funciones disponibles en `security.ps1`:

```powershell
# Importar el módulo
. .\security.ps1

# Encriptar un valor individual
$encrypted = Protect-EnvironmentValue -Value "my-secret-token"

# Desencriptar un valor
$decrypted = Unprotect-EnvironmentValue -Value $encrypted

# Cargar .env con desencriptación automática
$config = Import-SecureEnvironment -Path ".\.env"
$token = $config['TELEGRAM_BOT_TOKEN']  # Automáticamente desencriptado

# Exportar .env seleccionando qué campos encriptar
$values = @{
    'SECRET' = 'value123'
    'PUBLIC' = 'value456'
}
Export-SecureEnvironment -Path "new.env" -Values $values -EncryptFields @('SECRET')
```

---

## 🛡️ SEGURIDAD - MEJORES PRÁCTICAS

| Acción | Estado | Notas |
|--------|--------|-------|
| ✅ Encriptar .env | ✅ Recomendado | Protege contra acceso no autorizado |
| ✅ Restricción de permisos | ✅ Automática | Solo SYSTEM y Admins pueden leer |
| ✅ Backup en lugar seguro | ✅ Recomendado | USB encriptado / Cloud verificado |
| ❌ Compartir .env encriptado | ❌ NO hacer | No funcionará en otra máquina |
| ❌ Pushear .env a Git | ❌ NUNCA | Usar `.gitignore` |
| ⚠️ Cambiar de máquina | ⚠️ Cuidado | Necesitarás el backup sin encriptar |

### .gitignore (recomendado)

```
.env
.env.backup
.env.*.backup
*.log
logs/
```

---

## 🐛 SOLUCIÓN DE PROBLEMAS

### ❌ Error: "No se pudo desencriptar"

**Causa:** Usuario diferente / máquina diferente / DPAPI corrupto

**Solución:**
```powershell
# 1. Restaura desde backup
Copy-Item ".env.backup" ".env" -Force

# 2. Re-encripta
.\setup-secure-env.ps1
```

### ❌ Error: "Acceso denegado al .env"

**Causa:** Permisos incorrectos después de la encriptación

**Solución:**
```powershell
# Reparar permisos (como Admin)
icacls.exe ".env" /inheritance:r /grant:r "SYSTEM:F" "*S-1-5-32-544:F" /Q
```

### ❌ Script no desencripta valores

**Causa:** Las funciones necesitan ser cargadas

**Solución:** Asegúrate que el script incluye `Import-DotEnv`:
```powershell
# Verifica que Import-DotEnv maneje [ENC]
Get-Content -LiteralPath ".env" | Select-String "\[ENC\]"
```

---

## 📚 REFERENCIAS

- **DPAPI Documentation:** https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.protecteddata
- **PowerShell Security:** https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/
- **Windows Credential Manager:** Alternativa a DPAPI para credentials

---

## 🎯 RESUMEN

| Aspecto | Detalles |
|--------|----------|
| **Tipo de encriptación** | DPAPI AES (Windows) |
| **Campos encriptados** | Tokens, keys, passwords |
| **Desencriptación** | Automática en scripts |
| **Portabilidad** | Solo en misma máquina/usuario |
| **Seguridad** | 🟢 Muy seguro |
| **Facilidad uso** | 🟢 Transparente (auto-decrypt) |
| **Setup inicial** | ~1 minuto (`setup-secure-env.ps1`) |

✅ **¡Tu .env ahora está SUPER SEGURO!** 🔐
