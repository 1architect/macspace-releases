[English](SECURITY.md) · [Português](SECURITY.pt-BR.md) · **Español** · [Français](SECURITY.fr.md) · [Deutsch](SECURITY.de.md) · [简体中文](SECURITY.zh-Hans.md) · [日本語](SECURITY.ja.md) · [한국어](SECURITY.ko.md)

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
| Descargas sin terminar de fondos de pantalla y salvapantallas | Archivos `CFNetworkDownload_*.tmp` directamente en `/private/var/folders/*/*/T/com.apple.idleassetsd` que no han cambiado en 3 días. Solo archivos normales: los enlaces y las subcarpetas se rechazan. | El asistente |
| Copias que macOS hizo de una app al comprobarla | `/var/folders/…/X/<app>.code_sign_clone`, solo cuando ocupa espacio propio (el de una versión anterior), con la app cerrada y nada ejecutándose desde ella. | La app, como tú |
| El registro del sistema | `/private/var/db/diagnostics` y `/private/var/db/uuidtext`, con `log erase --all` y `log erase --uuidtext` de Apple. | El asistente |
| Los símbolos para informes de fallos | Todo lo que hay en `/System/Library/Caches/com.apple.coresymbolicationd`, la carpeta se queda; después se detiene `coresymbolicationd` para que vuelva el espacio. macOS vuelve a crear la caché. | El asistente |
| La Papelera | Todo lo que hay en `~/.Trash`. Un ítem bloqueado o de otra cuenta se queda. | La app, como tú |
| Instantáneas locales de Time Machine | `tmutil deletelocalsnapshots <fecha>`, una fecha cada vez: todas menos la más reciente y la más reciente de una copia. Nunca durante una copia. | La app, como tú |
| Copias en un disco de copia de Time Machine | `tmutil delete`, las que elijas, nunca la más reciente, en un disco conectado que usa Time Machine. Nunca durante una copia. | El asistente |

Nada va a la Papelera. Las cachés, los recursos del sistema y los archivos purgables se vuelven a
crear o a descargar cuando hacen falta, y las copias de la nube se vuelven a descargar cuando
abres el archivo. Los informes, el historial de versiones, los restos de actualizaciones, el registro del
sistema, los ítems de la Papelera, las instantáneas y las copias no se recuperan. Todos estos piden confirmación antes, salvo el botón **Liberar** de las cachés de una
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
| Siri AI, Inteligencia visual | Anulaciones de feature flags en `/Library/Preferences/FeatureFlags/Domain/` | El asistente |
| Rastreo de bloqueos (tailspin) | `tailspin disable`, y `tailspin enable` para deshacerlo | El asistente |
| Las políticas (cinco; seis en una beta de macOS) | Un perfil de configuración, `com.macspace.policies` (ver abajo) | Tú lo apruebas en Ajustes del Sistema |

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

### Transcripción de llamadas

El control de Transcripción de llamadas en Siri y Apple Intelligence usa cinco anulaciones fijas de TelephonyUtilities en
`/Library/Preferences/FeatureFlags/Domain/TelephonyUtilities.plist`: grabación, filtrado de llamadas, entrega de subtítulos de
FaceTime y traducción de audio y vídeo del Mac. El asistente autenticado guarda las entradas originales en
`/Library/Application Support/MacSpace/phone-features.json` antes de cambiarlas. Los cambios requieren reiniciar; el estado efectivo
se comprueba por separado. Al reactivar se restauran las entradas originales, conservando las demás anulaciones. El asistente
rechaza entradas modificadas fuera de MacSpace. Este control no instala perfiles ni cambia el idioma de Siri. La operación del
asistente solo acepta activar o desactivar, sin rutas, dominios ni claves arbitrarios.

### Modelos de las funciones

Los interruptores separados de Siri y Fotos espaciales guardan los ajustes originales antes de desactivar una función. La voz
guardada de Siri se elimina mientras Siri está desactivado; su idioma se conserva. Transcripción de llamadas también desactiva los ajustes locales
de grabación, filtrado y subtítulos. Los originales se guardan en `~/Library/Application Support/MacSpace/feature-settings/`.

Las solicitudes de modelos se liberan mediante los servicios de Apple que las gestionan, con los datos de restauración en
`~/Library/Application Support/MacSpace/asset-owners/`. Estas limpiezas de funciones y modelos lingüísticos no editan la base activa de suscripciones ni eliminan directamente
los modelos. La limpieza usa el servicio protegido de macOS. Espera si no se puede leer el estado de Apple Intelligence y, con Apple
Intelligence activado, mientras macOS descarga recursos del sistema; conserva las solicitudes de otras cuentas y los modelos de voz
compartidos mientras Dictado está activo. Los recursos lingüísticos sin uso solo se liberan con Apple Intelligence desactivado.

Mientras MacSpace está abierto, comprueba cada cinco minutos las funciones desactivadas explícitamente y vuelve a limpiar los
modelos sin uso que macOS solicite de nuevo. Reactivar una función o usar el desinstalador de MacSpace restaura los ajustes y
solicitudes guardados; macOS puede volver a descargar los modelos. Las operaciones interrumpidas o en conflicto se comprueban
antes de repetirlas. Estos controles funcionan en todas las versiones de macOS 27; antes de cada solicitud, el proceso separado comprueba los métodos de Apple que usa. Los recursos lingüísticos sin
uso en Datos del sistema tienen una limpieza puntual que no desactiva la ortografía ni los diccionarios.

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
| `systemdata.wallpaper-downloads.delete` | Elimina las descargas sin terminar de fondos de pantalla y salvapantallas | No recibe ninguna ruta: encuentra `/private/var/folders/*/*/T/com.apple.idleassetsd` por sí mismo, sin seguir enlaces. Elimina solo archivos normales llamados `CFNetworkDownload_*.tmp` directamente en la carpeta, sin cambios en 3 días. |
| `systemdata.unified-log.erase` | Borra el registro del sistema | No recibe argumentos. Solo ejecuta `/usr/bin/log erase --all` de Apple y después `log erase --uuidtext`. |
| `systemdata.symbolication-cache.delete` | Elimina los símbolos para informes de fallos | No recibe argumentos. Solo `/System/Library/Caches/com.apple.coresymbolicationd`, abierta sin seguir enlaces; elimina lo que contiene, nunca la carpeta, y después detiene `coresymbolicationd` (`kill -TERM`, `-KILL` a los 5 segundos). |
| `timemachine.backups.delete` | Elimina copias de un disco de copia de Time Machine | Solo en un disco que Time Machine indica como conectado, solo fechas que encuentra allí por sí mismo, nunca la copia más reciente, nunca durante una copia ni cuando no se sabe. Ejecuta `/usr/bin/tmutil delete`. |
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

MacSpace tiene un desinstalador: en la barra de menús, elige **MacSpace** > **Acerca de MacSpace** y luego **Desinstalar…**.
Restablece los ajustes de cada módulo, elimina el asistente y mueve MacSpace a la Papelera. Para hacerlo a mano, los pasos
completos están en el [README](README.es.md#desinstalar). En resumen:

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
