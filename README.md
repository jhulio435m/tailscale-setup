# Tailscale Provisioning Tool

Herramientas para el aprovisionamiento de nodos via Tailscale y establecimiento de acceso remoto seguro.

## Requisitos

- Windows con PowerShell 5.1 o superior.
- Privilegios de administrador.
- Conexion a internet.
- Tailscale Auth Key.

## Flujo de Trabajo

1. Configurar las credenciales y variables en el archivo .env.
2. Ejecutar install-tailscale-openssh.ps1 para instalar Tailscale y configurar el servidor SSH.
3. Utilizar create-task.ps1 para crear la tarea programada que asegura que el servicio este siempre activo.
4. Las llaves SSH se gestionan en la carpeta keys/ para el acceso remoto.
