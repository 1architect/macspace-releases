[English](SECURITY.md) · [Português](SECURITY.pt-BR.md) · **Español** · [Français](SECURITY.fr.md) · [Deutsch](SECURITY.de.md)

# Política de Seguridad

MacSpace es una app gratuita y de código abierto (MIT) para macOS. Se ejecuta con tu cuenta de
usuario normal. Para las pocas tareas que requieren un administrador, usa un asistente con
privilegios que apruebas una sola vez. No recoge ningún dato sobre ti. Este documento explica
exactamente qué toca MacSpace en tu Mac y cómo informar de un problema.

## Informar de una vulnerabilidad

Usa el informe privado de vulnerabilidades de GitHub:
[informar de una vulnerabilidad](https://github.com/1architect/macspace-releases/security/advisories/new).
O escribe a **dev@giomantovani.com.br** con los detalles y los pasos para reproducirla. Por
favor, no abras una incidencia pública para un informe de seguridad. Recibirás un acuse de recibo
en unos días.

Qué cuenta como vulnerabilidad: cualquier fallo que permita a otro programa hacer que el
asistente haga lo que tú no pediste, que permita a MacSpace eliminar o cambiar algo que no
debería, o que permita instalar una actualización sin la firma de la versión.

## Versiones compatibles

Las correcciones de seguridad solo entran en la última versión. Actualiza siempre a la versión
más reciente desde [Releases](https://github.com/1architect/macspace-releases/releases/latest),
con **Buscar actualizaciones…** o con `brew upgrade --cask macspace` (añade `--greedy` si
Homebrew la omite, porque MacSpace se actualiza solo).

## Qué hace MacSpace en tu Mac

### Red

MacSpace hace conexiones de red con un único fin: las actualizaciones. Cuando eliges **Buscar
actualizaciones…** (o **Comprobar ahora** en Ajustes) y, si activaste **Buscar actualizaciones
automáticamente**, aproximadamente una vez al día mientras está abierto, lee el feed de
actualizaciones alojado junto con las versiones en GitHub (`appcast.xml`). Si aceptas una
actualización, descarga la nueva versión de GitHub Releases. No se envía nada sobre ti, y el
perfil de sistema opcional de Sparkle no está activado.

No hay análisis de uso, ni telemetría, ni informes de fallos. Los detalles están en la
[Política de Privacidad](PRIVACY.es.md).

### Dónde se guardan tus datos

Todo se queda en tu Mac. Los archivos de MacSpace están en
`~/Library/Application Support/MacSpace/`, `~/Library/Logs/MacSpace/`, el archivo de
preferencias `~/Library/Preferences/com.macspace.app.plist` y, para lo que escribe el asistente,
`/Library/Application Support/MacSpace/`. La [Política de Privacidad](PRIVACY.es.md) enumera cada
archivo. Nada de esto se sube a ningún sitio.

### Qué elimina MacSpace

| Qué | Dónde | Lo hace |
|---|---|---|
| Cachés de apps que están cerradas | La carpeta de caché del sistema de cada usuario (`/var/folders/…/C`), salvo las de Apple. Las carpetas `Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `DawnGraphiteCache`, `DawnWebGPUCache`, `GrShaderCache`, `ShaderCache` y `CachedData` dentro de un perfil de Chromium o Electron en `~/Library/Application Support`. | La app, como tú |
| Informes de diagnóstico y de fallos con más de 7 días | `/Library/Logs/DiagnosticReports` y `~/Library/Logs/DiagnosticReports`. Se omite un archivo que no puedes eliminar. | La app, como tú |
| Recursos del sistema sin usar, modelos de Apple Intelligence liberados, archivos que las apps marcaron como purgables | El propio servicio de purga de macOS (CacheDelete). MacSpace se lo pide en un proceso hijo de corta duración, así que un fallo ahí no puede tumbar la app. | macOS |
| Copias locales de archivos de la nube | Una carpeta de la nube cada vez (`~/Library/CloudStorage/…` o iCloud Drive). Solo archivos que están subidos y no tienen conflicto. Los archivos se quedan en la nube. | La app, como tú |
| Historial de versiones de documentos | `/System/Volumes/Data/.DocumentRevisions-V100` | El asistente |
| Archivos sobrantes de actualización de macOS | `/System/Volumes/Data/macOS Install Data`, solo si es anterior al sistema instalado. La carpeta `Locked Files` se queda. | El asistente |

Nada va a la Papelera. Las cachés, los recursos del sistema y los archivos purgables se vuelven a
crear o a descargar cuando hacen falta, y las copias de la nube se vuelven a descargar cuando
abres el archivo. Los informes, el historial de versiones y los restos de actualizaciones no se
recuperan. Todos estos piden confirmación antes, salvo el botón **Liberar** de las cachés de una
sola app.

### Qué cambia MacSpace (Debloat)

Cada cambio se anota primero en un diario, para poder deshacerlo con **Activar todo** o
volviendo a activar la función.

| Interruptor | Qué cambia | Lo hace |
|---|---|---|
| Anuncios personalizados | `com.apple.AdLib`, clave `allowApplePersonalizedAdvertising` | La app, como tú |
| Mejorar Siri y Dictado | `com.apple.assistant.support`, clave `Siri Data Sharing Opt-In Status` | La app, como tú |
| Aviso de informe de fallos | Una anulación de launchd para `com.apple.DiagnosticsReporter` y `com.apple.ReportGPURestart` | La app, como tú |
| Compartir análisis con Apple (versiones finales de macOS) | `/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist`, claves `AutoSubmit` y `ThirdPartyDataSubmit` | El asistente |
| Siri AI, Inteligencia visual, Indexación para búsqueda generativa | Anulaciones de feature flags en `/Library/Preferences/FeatureFlags/Domain/` | El asistente |
| Rastreo de bloqueos (tailspin) | `tailspin disable`, y `tailspin enable` para deshacerlo | El asistente |
| Las políticas (seis; siete en una beta de macOS) | Un perfil de configuración, `com.macspace.policies` (ver abajo) | Tú lo apruebas en Ajustes del Sistema |

Estos cambios se quedan donde están si eliminas la app sin volver a activar las funciones.

### Apple Intelligence

El interruptor **Apple Intelligence** cambia la clave `Session Language` de
`com.apple.assistant.backedup`, que es el idioma de Siri. Al desactivarlo, Siri recibe un idioma
distinto al del sistema, y tu voz de Siri (`Output Voice`) se deja como está. MacSpace guarda
ambos en `~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json` y los
restaura cuando vuelves a activar Apple Intelligence, o si el cambio no surte efecto. Si macOS
conserva los modelos después de desactivarlo, MacSpace puede poner el idioma de Siri igual que el
del sistema y luego volver a cambiarlo, lo que tarda alrededor de un minuto, para que macOS los
libere. Con la sincronización de Siri con iCloud activada, estos cambios también llegan a tus
otros dispositivos de la misma cuenta de Apple. MacSpace no puede desactivar esa sincronización.
Te dice dónde hacerlo.

### Permisos

macOS gestiona cada solicitud, así que MacSpace nunca ve tu contraseña.

| Permiso | Dónde | Para qué lo usa MacSpace |
|---|---|---|
| Acceso total al disco | Ajustes del Sistema > Privacidad y seguridad | Medir las carpetas que macOS protege y leer el estado de Apple Intelligence |
| Asistente con privilegios | Ajustes del Sistema > General > Ítems de inicio y extensiones | Las operaciones de más abajo |
| Perfil de configuración | Ajustes del Sistema > General > Gestión de dispositivos | Solo cuando desactivas una política de Debloat |
| Notificaciones | macOS lo pide | Avisarte de que algo ha terminado |

### El asistente con privilegios

El asistente es un launch daemon, `com.macspace.helper`, registrado en macOS desde dentro de la
app. launchd lo inicia cuando MacSpace le pide algo. Se ejecuta como root, y solo acepta una
conexión de un programa que cumpla este requisito de firma de código, que macOS comprueba:

```
anchor apple generic and (identifier "com.macspace.app" or identifier "com.macspace.cli")
and certificate leaf[subject.OU] = "<the developer's team ID>"
```

Se niega a arrancar sin un requisito. Ejecuta solo operaciones con nombre que lleva integradas.
Quien lo llame no puede enviarle comandos. Cuando la app se sustituye por una actualización, el
asistente lo nota y se retira para que arranque el nuevo.

| Operación | Qué hace | Límites |
|---|---|---|
| `systemdata.measure` | Tamaños de carpetas | Solo lectura. Solo dentro de `/private/var`, `/private/tmp`, `/Library`, `/System/Library`, la raíz del volumen Data y `/opt`, nunca una carpeta de inicio. Tamaños, nunca contenidos. |
| `systemdata.versions.delete` | Elimina el historial de versiones de documentos | Primero detiene `revisiond`, o lo pausa si macOS se niega. Elimina el contenido del almacén, no la carpeta, y luego vuelve a iniciar `revisiond`. Si no puede detenerlo, no elimina nada. |
| `systemdata.staged-update.delete` | Elimina los archivos de actualización sobrantes | Solo si la carpeta es anterior al sistema instalado. Conserva `Locked Files`. |
| `debloat.status`, `.apply`, `.revert` | Lee, desactiva y activa elementos de Debloat | Solo identificadores de control, del catálogo integrado. Nada más. |
| `debloat.removeProfile` | Elimina un perfil de MacSpace | Solo los identificadores `com.macspace.policies` y `com.macspace.policies.…`. Cualquier otro perfil se rechaza. |
| `siri.orphan-subscriptions.plan`, `.execute` | Encuentra y elimina las suscripciones de Apple Intelligence de cuentas que ya no existen | Antes hace una copia de seguridad de la base de datos en `/Library/Application Support/MacSpace/backups/`, la modifica en una sola transacción, toca solo las filas que no corresponden a ninguna cuenta local y se niega si la lista de cuentas parece incorrecta. La app aún no tiene ningún botón para esto. |
| `helper.ping` | Responde, para que la app sepa que el asistente está activo | Ninguno |

La herramienta de línea de comandos de la app, `MacSpaceCli`, dentro del paquete de la app,
también puede hablar con el asistente. Está firmada con el mismo equipo.

### El perfil de configuración

Las políticas de Debloat son ajustes que solo un perfil de configuración puede forzar. MacSpace
crea un único perfil, `com.macspace.policies` (se muestra como **MacSpace: policies**,
organización «MacSpace»), con todas las políticas que desactivaste. Abre el perfil y tú lo
apruebas en Ajustes del Sistema > General > Gestión de dispositivos. Al aprobarlo, sustituye al
anterior. No está marcado como imposible de eliminar. Al volver a activar la última política, se
elimina a través del asistente, sin nada que aprobar. También puedes eliminarlo tú mismo en
Ajustes del Sistema.

### Firma de código y actualizaciones

MacSpace está firmado con un Developer ID de Apple, con el hardened runtime, y notarizado por
Apple. El ticket de notarización está grapado a la app, así que también se abre sin conexión. Los
componentes propios de Sparkle se firman con la misma identidad.

Las actualizaciones también se firman con una clave EdDSA. Su mitad pública está dentro de
MacSpace (`SUPublicEDKey`), y Sparkle comprueba cada descarga con ella antes de instalar. La
mitad privada de esa clave y la identidad de firma no están en este repositorio. Una copia de
MacSpace compilada sin la clave pública nunca busca actualizaciones.

## Comprobar una descarga

Pon `MacSpace-x.y.z.dmg` y `MacSpace-x.y.z.dmg.sha256` en una misma carpeta:

```bash
shasum -a 256 -c MacSpace-x.y.z.dmg.sha256
```

Después, cuando hayas arrastrado MacSpace a Aplicaciones:

```bash
codesign -dv --verbose=4 /Applications/MacSpace.app
codesign --verify --deep --strict --verbose=2 /Applications/MacSpace.app
spctl -a -vv /Applications/MacSpace.app
xcrun stapler validate /Applications/MacSpace.app
```

Deberías ver `Authority=Developer ID Application`, `TeamIdentifier=J45ZXS2ZF6`, la marca
`runtime`, `Notarization Ticket=stapled`, y `spctl` debería decir `accepted` con
`source=Notarized Developer ID`.

## Desinstalar por completo

No hay un desinstalador dentro de la app. Los pasos completos están en el
[README](README.es.md#desinstalar). En resumen:

1. En **Debloat**, pulsa **Activar todo**. Esto elimina las anulaciones y el perfil que creó.
2. Si el perfil **MacSpace: policies** sigue en Ajustes del Sistema > General > Gestión de
   dispositivos, elimínalo.
3. Sal de MacSpace. Desactívalo en Ajustes del Sistema > General > Ítems de inicio y extensiones,
   o ejecuta `/Applications/MacSpace.app/Contents/MacOS/MacSpaceCli helper --unregister`.
4. Elimina la app: `brew uninstall --cask macspace`, o arrastra **MacSpace** a la Papelera.
5. Elimina sus datos y preferencias:
   ```bash
   rm -rf ~/Library/Application\ Support/MacSpace ~/Library/Logs/MacSpace ~/Library/Caches/com.macspace.app
   defaults delete com.macspace.app
   sudo rm -rf /Library/Application\ Support/MacSpace
   ```
6. Quita MacSpace de Ajustes del Sistema > Privacidad y seguridad > Acceso total al disco.
