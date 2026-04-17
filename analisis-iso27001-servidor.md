# Análisis ISO 27001 del servidor

Baseado en la inspección local del host realizada el 10 de abril de 2026, este servidor no opera como un servicio único: funciona como una plataforma multiaplicación autohospedada sobre Ubuntu 24.04.4 LTS, Docker y varias redes bridge. Desde perspectiva ISO 27001, el riesgo no está solo en "el servidor", sino en el conjunto de servicios, datos, accesos, integraciones y dependencias que el host concentra.

## Qué orquesta actualmente el servidor

El servidor orquesta, al menos, estos dominios operativos:

### Publicación e ingreso

- `cloudflared`: expone dominios por Cloudflare Tunnel.
- Hay configuración de `Caddy`, pero no hay evidencia de que esté activo; parece una capa prevista o residual.
- Dominios publicados por túnel: sitio principal, Plane, ERPNext, Nextcloud, Uptime Kuma y Autotext.

### Gestión de proyectos

- Plane completo:
  - `web`, `admin`, `space`
  - `api`
  - `bgworker`, `beatworker`
  - `plane-live`
  - `proxy`
  - `plane-db` (PostgreSQL)
  - `plane-redis`
  - `plane-mq` (RabbitMQ)
  - `plane-minio`
- Función: gestión de proyectos, issues, ciclos, módulos, páginas, archivos, analítica y colaboración.

### Gestión documental / expedientes

- Autoexp / Expedientes:
  - `expedientes-ui`
  - `expedientes-api`
  - `expedientes-db`
- Función: aplicación propia de expedientes/documentos con backend y frontend separados.

### Puente de integración

- Autotext:
  - aplicación Node/React expuesta en `4010`
  - integra lectura de Plane, base propia y Frappe/ERPNext
- Función: puente de datos, automatización y capa de integración entre sistemas.

### ERP

- ERPNext/Frappe:
  - `frontend`, `backend`, `websocket`
  - `scheduler`
  - `queue-short`, `queue-long`
  - `redis-cache`, `redis-queue`
  - `db` (MariaDB)
- Función: ERP empresarial con backend, colas, websocket y persistencia.

### Colaboración y archivos

- Nextcloud AIO:
  - `nextcloud-aio-mastercontainer`
  - `nextcloud-aio-apache`
  - `nextcloud-aio-nextcloud`
  - `nextcloud-aio-database`
  - `nextcloud-aio-redis`
  - `nextcloud-aio-notify-push`
  - `nextcloud-aio-imaginary`
  - `nextcloud-aio-collabora`
- Función: archivos, colaboración, edición online, notificaciones y almacenamiento.

### Bases de datos dedicadas

- `delphin-sqlserver` en SQL Server 2022
- `delphin-express-postgres` en PostgreSQL 13
- Función: compatibilidad con sistemas Delphin y clientes legacy.

### Supervisión

- `uptime-kuma`
- Función: monitoreo básico de disponibilidad.

### Sitio web

- `ul-web` con Nginx
- Función: publicación del portal principal.

### Servicios preparados pero no activos

- `Caddy`, `Odoo`, `Dolibarr`
- Relevancia ISO: forman parte del alcance potencial, aunque no necesariamente del alcance actual.

## Análisis funcional detallado

Este servidor cumple simultáneamente varias funciones críticas de negocio:

### Front de negocio y presencia pública

- Portal web, ERP, Plane, Nextcloud y herramientas internas/publicadas.
- Riesgo: un incidente en el host afecta varias capacidades empresariales al mismo tiempo.

### Plataforma de colaboración

- Plane y Nextcloud cubren gestión de trabajo, documentos, archivos y colaboración.
- Riesgo: concentración de datos operativos y documentales en un mismo host.

### Backends de aplicación

- Autoexp y Autotext agregan lógica propia e integraciones.
- Riesgo: son superficies de ataque personalizadas; requieren control de cambios, revisión segura y trazabilidad.

### Persistencia de datos

- PostgreSQL, MariaDB, SQL Server, Redis, RabbitMQ y MinIO.
- Riesgo: coexistencia de múltiples motores con distintos modelos de acceso, backup y endurecimiento.

### Integración entre entornos

- Autotext conecta Plane, base propia y Frappe.
- `cloudflared` está conectado a varias redes Docker, por lo que funciona como punto transversal entre dominios.
- Riesgo: un fallo de segmentación puede pivotar entre sistemas.

### Operación continua

- Hay políticas de reinicio y healthchecks en varios servicios.
- Uptime Kuma da visibilidad de disponibilidad.
- Esto es positivo, pero no reemplaza controles de seguridad formales.

## Hallazgos relevantes para ISO 27001

Los puntos más importantes son estos:

- El servidor es técnicamente apto para entrar en un SGSI, pero no está listo para certificación en su estado actual.
- Hay múltiples servicios críticos en un solo host. Esto eleva riesgo de disponibilidad, impacto y alcance.
- Se observan secretos en archivos `.env` locales. Eso es normal operativamente, pero para ISO requiere control formal de acceso, rotación, custodia y evidencia.
- Hay credenciales expuestas en documentación local de Delphin Express. Eso es un hallazgo serio.
- Se publican bases de datos en `0.0.0.0`:
  - PostgreSQL Delphin Express en `5433`
  - SQL Server en `14330`
  - Eso incrementa superficie de ataque y requiere justificación formal, filtrado por firewall, listas blancas y registro.
- `Autotext` está publicado en `0.0.0.0:4010`.
- Nextcloud AIO mastercontainer está `unhealthy`. Aunque servicios hijos estén operativos, ISO 27001 evalúa estabilidad y gestión de incidentes, no solo si "todavía funciona".
- Nextcloud AIO usa:
  - `network_mode: host`
  - acceso a `/var/run/docker.sock`
  - Eso aumenta privilegio y sensibilidad del componente.
- `cloudflared` está unido a varias redes Docker. Es práctico, pero también rompe separación estricta entre dominios.
- En `autoexp` y frontend hay montajes RW del código fuente dentro de contenedores. Eso facilita operación/desarrollo, pero en producción reduce inmutabilidad y complica control de cambios.
- Hay evidencia de backup local (`host-20260410-030001.tar.zst`), pero no evidencia suficiente de:
  - política de retención
  - pruebas de restauración
  - cifrado de copias
  - offsite backup
  - RPO/RTO definidos
- Hay monitoreo de disponibilidad, pero no se ve evidencia directa de:
  - centralización de logs
  - correlación de eventos
  - gestión formal de incidentes
  - gestión de vulnerabilidades
  - inventario aprobado de activos
  - clasificación de información
  - control de accesos basado en roles a nivel empresa
  - revisión periódica de privilegios
  - hardening documentado del host
  - procedimiento formal de cambios

## Viabilidad de aplicar ISO 27001 en la empresa

Sí, es viable aplicar ISO 27001, pero con una condición: la empresa debe tratar esto como un proyecto de gestión, no solo como un ajuste técnico del servidor.

Evaluación:

- Viabilidad técnica: alta
- Viabilidad organizacional: media
- Nivel actual de preparación para auditoría: medio-bajo
- Probabilidad de certificación inmediata sin remediación: baja

La razón es simple: ya existe una base técnica útil:

- virtualización por contenedores
- separación parcial por redes
- monitoreo básico
- persistencia definida
- reinicio automático
- servicios documentables

Pero ISO 27001 exige además:

- alcance definido
- matriz de riesgos
- políticas
- roles y responsabilidades
- controles operativos
- evidencias
- mejora continua
- auditoría interna
- tratamiento de riesgos aprobado por dirección

## Principales brechas frente a ISO 27001

Las brechas que hoy se observan son:

### Gobierno

- no hay evidencia de SGSI formal, comité, responsable, apetito de riesgo, alcance ni objetivos de seguridad.

### Gestión de activos

- el inventario técnico existe de hecho, pero no de forma controlada y aprobada.

### Control de accesos

- faltaría demostrar segregación de funciones, revisiones periódicas, MFA, privilegio mínimo y ciclo de vida de cuentas.

### Gestión de secretos

- `.env` locales sí, pero sin evidencia visible de vault, rotación formal ni custodia robusta.

### Seguridad de red

- exposición directa de BD y aplicaciones; segmentación mejorable.

### Gestión de cambios

- hay entornos y contenedores, pero no se ve proceso formal de aprobación, rollback, ventana y evidencia.

### Continuidad

- un backup local aislado no alcanza para continuidad de negocio ni recuperación ante desastre.

### Operación segura

- falta evidenciar parcheo, escaneo de vulnerabilidades, endurecimiento y revisión de configuraciones.

### Registro y monitoreo

- Uptime Kuma cubre disponibilidad, pero no cubre seguridad ni trazabilidad integral.

## Recomendación de alcance para certificar

No conviene certificar toda la empresa de golpe si la organización es pequeña o mediana. Conviene empezar con un alcance como:

> Prestación y operación de servicios empresariales autohospedados de colaboración, gestión documental, ERP e integraciones sobre infraestructura Docker administrada por la empresa.

Eso permite incluir:

- host Ubuntu
- Docker
- Cloudflare Tunnel
- Plane
- Nextcloud
- ERPNext
- Autoexp
- Autotext
- bases de datos asociadas
- backup y monitoreo

Y dejar fuera, si hace falta en primera fase:

- laboratorios
- stacks no activos
- desarrollos experimentales
- Odoo/Dolibarr si no están productivos

## Plan mínimo para volverlo viable en serio

Prioridad alta, antes de pensar en auditoría:

1. Cerrar exposición directa de `5433`, `14330` y revisar `4010`.
2. Eliminar credenciales en documentación y rotar las afectadas.
3. Normalizar gestión de secretos.
4. Resolver el estado `unhealthy` de Nextcloud AIO mastercontainer.
5. Definir inventario oficial de activos, dueños, criticidad y datos tratados.
6. Documentar backups, cifrado, retención y prueba de restauración.
7. Implementar logs centralizados y proceso de incidentes.
8. Formalizar control de cambios y acceso administrativo.
9. Revisar segmentación entre redes Docker y acceso transversal de `cloudflared`.
10. Definir alcance ISO, matriz de riesgos y Statement of Applicability.

## Conclusión

La empresa sí puede aplicar ISO 27001, y este servidor puede entrar dentro del alcance, pero hoy el entorno parece más cercano a una operación funcional y pragmática que a una operación preparada para auditoría. La principal fortaleza es que ya existe una arquitectura real, en producción y relativamente ordenada. La principal debilidad es la concentración de servicios críticos, exposición de puertos sensibles, gestión de secretos mejorable y falta de evidencia formal de gobierno y operación de seguridad.
