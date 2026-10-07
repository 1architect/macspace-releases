[English](PRIVACY.md) · [Português](PRIVACY.pt-BR.md) · **Español** · [Français](PRIVACY.fr.md) · [Deutsch](PRIVACY.de.md)

# Política de Privacidad — MacSpace

**Última actualización: 6 de octubre de 2026 · Se aplica a MacSpace 1.0.0 y posteriores**

MacSpace no recoge, almacena ni transmite ningún dato de uso. No hay análisis de uso, ni
telemetría, ni informes de fallos, ni publicidad. MacSpace no tiene sistema de cuentas, así que
nunca creas un perfil ni inicias sesión.

Este documento describe exactamente qué lee MacSpace, dónde lo guarda y el único momento en que
usa la red.

---

## Qué se queda en tu Mac

MacSpace mide tu disco, lee algunos ajustes del sistema y escribe unos pocos archivos pequeños en
tu propio equipo. Nada de eso sale de tu Mac.

| Dato | Dónde se guarda |
|---|---|
| Tus ajustes: tema, opciones de la ventana, qué módulos están activados, opciones de los módulos, limpieza automática, opciones de notificaciones, el último mosaico que mostró cada módulo, el paso del primer arranque | Preferencias de macOS (`UserDefaults`) de MacSpace, `~/Library/Preferences/com.macspace.app.plist` |
| Ajustes propios de Sparkle: si busca actualizaciones automáticamente y cuándo buscó por última vez | El mismo archivo de preferencias |
| Historial de limpiezas: cuándo, qué módulo, cuánto liberó, cómo se inició, un resumen de una línea | `~/Library/Application Support/MacSpace/cleanup-history.json` |
| Espacio que macOS conservó aunque MacSpace le pidió que lo liberara | `~/Library/Application Support/MacSpace/purge-holdouts.json` |
| Diario de Debloat: cada ajuste que MacSpace cambió, su valor antes y después, la compilación de macOS y cuándo | `~/Library/Application Support/MacSpace/debloat-journal.json` y, para los cambios que hace el asistente, `/Library/Application Support/MacSpace/debloat-journal.json` |
| Vigilancia de Debloat: qué funciones volvió a activar macOS y cuándo (los últimos 20 eventos) | `~/Library/Application Support/MacSpace/debloat-watch.json` |
| El perfil de Debloat, tal como se prepara para tu aprobación | `~/Library/Application Support/MacSpace/Profiles/MacSpace.mobileconfig` |
| Tu idioma y tu voz de Siri, guardados mientras Apple Intelligence está desactivado para que MacSpace pueda restaurarlos | `~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json` |
| Vigilancia de Apple Intelligence (solo si la activas): el último estado que vio y un registro de cambios | `~/Library/Application Support/MacSpace/ai-watch-state.json` y `~/Library/Logs/MacSpace/ai-watch.jsonl` |
| Una copia de seguridad de la base de datos de suscripciones de macOS, solo si eliminas suscripciones sobrantes de Apple Intelligence de cuentas eliminadas | `/Library/Application Support/MacSpace/backups/` |
| Descargas de actualizaciones | La carpeta de caché de Sparkle, `~/Library/Caches/com.macspace.app/` |

Puedes eliminar todo esto en cualquier momento. [README.es.md](README.es.md#desinstalar) enumera
los comandos. Al eliminar estos archivos, MacSpace olvida su historial y sus ajustes. Si
eliminas los diarios de Debloat mientras haya funciones desactivadas con Debloat, MacSpace ya no
puede restaurar los valores originales que guardó y usa los de macOS por defecto. Pulsa antes
**Activar todo**.

### Qué lee MacSpace

MacSpace lee estas cosas en tu Mac para hacer su trabajo. No envía ninguna a ningún sitio.

- **Nombres y tamaños de archivos y carpetas**, en todo el disco una vez que le das acceso total
  al disco. No lee lo que hay en tus documentos, fotos, correos o mensajes. Mide cuánto espacio
  ocupan.
- **Algunos archivos del sistema:** el archivo de aptitud de Apple Intelligence, la base de datos
  de suscripciones a recursos de macOS, la lista de perfiles de configuración instalados y la base
  de datos de la cuenta de Apple (solo lectura, para saber si la sincronización de Siri con iCloud
  está activada).
- **Los nombres de las cuentas de usuario de este Mac**, para decir qué cuenta mantiene activado
  Apple Intelligence.
- **El estado de macOS:** su versión y compilación, si la Protección de integridad del sistema
  está activada, si el Mac está inscrito en la gestión de dispositivos, los nombres de los
  procesos en ejecución (para comprobar que un interruptor de Debloat surtió efecto) y unas
  líneas del registro del sistema que anotan las propias decisiones de macOS sobre los análisis
  (para comprobar que el interruptor de análisis funcionó).

---

## Cuándo usa MacSpace la red

MacSpace usa la red con un único fin: **las actualizaciones**. No tiene análisis de uso, ni
inicio de sesión, ni ninguna otra conexión.

### Cuándo busca actualizaciones

MacSpace usa [Sparkle](https://sparkle-project.org) para encontrar e instalar actualizaciones. Se
conecta a la red en estos casos:

- cuando eliges **Buscar actualizaciones…** en el menú MacSpace, o **Comprobar ahora** en Ajustes;
- aproximadamente una vez al día mientras MacSpace está abierto, si las búsquedas automáticas
  están activadas.

Las búsquedas automáticas están desactivadas hasta que activas **Buscar actualizaciones
automáticamente** en Ajustes, o respondes que sí a la pregunta que Sparkle hace una vez, a partir
del segundo arranque. Hasta entonces, MacSpace no busca por su cuenta. Una compilación que haces
tú desde el código fuente no tiene clave de actualización y nunca busca.

Una búsqueda solicita un archivo a GitHub:

```
https://github.com/1architect/macspace-releases/releases/latest/download/appcast.xml
```

Como en cualquier petición web, GitHub puede ver tu dirección IP. La petición también lleva el
nombre y la versión de MacSpace y la versión de Sparkle, en la cabecera `User-Agent` habitual.
MacSpace no envía ningún perfil del sistema, ni información del hardware, ni identificador de
ningún tipo. El perfil de sistema opcional de Sparkle no está activado. El tratamiento que GitHub
da a esa petición se rige por la
[Declaración de Privacidad de GitHub](https://docs.github.com/site-policy/privacy-policies/github-privacy-statement)
(en inglés).

Si aceptas una actualización, Sparkle la descarga de GitHub Releases. Cada actualización está
firmada. Sparkle comprueba la firma con la clave pública que lleva MacSpace antes de instalar
nada.

### Lo que no es MacSpace

Si vuelves a activar Apple Intelligence, macOS (no MacSpace) puede descargar sus modelos. Cuando
abres una app descargada, macOS puede comprobarla con Apple. Esas son conexiones propias de
macOS.

---

## Lo que MacSpace nunca hace

- Nunca envía a ningún sitio tu lista de archivos, las cifras de tu disco, tus ajustes, tu
  historial de limpiezas ni los nombres de tus cuentas.
- Nunca lee el contenido de tus documentos, fotos, correos o mensajes.
- Nunca te pide crear una cuenta ni iniciar sesión.
- Nunca informa de fallos ni de uso, ni al desarrollador ni a nadie más.

### Sobre los permisos y el asistente

MacSpace pide algunas aprobaciones, cada una en el propio diálogo de macOS o en Ajustes del
Sistema, así que nunca ve tu contraseña:

- **Acceso total al disco**, para medir todo lo que hay en el disco y para leer el estado de
  Apple Intelligence.
- **Un asistente con privilegios**, un launch daemon (`com.macspace.helper`) que realiza las
  pocas tareas que requieren un administrador. Solo acepta clientes firmados por el mismo equipo
  de desarrollo que MacSpace y ejecuta únicamente las operaciones que lleva integradas.
- **Un perfil de configuración**, solo si desactivas una política de Debloat.
- **Notificaciones**, para avisarte cuando algo ha terminado.

Lo que pueden hacer el asistente y el perfil está en [SECURITY.es.md](SECURITY.es.md).

---

## Menores

MacSpace es una utilidad para macOS y no está dirigida a menores. No recoge información personal
de nadie, sea cual sea su edad.

## Cambios en esta política

Si cambia el comportamiento de MacSpace, este documento cambia con él, y también cambia la fecha
de arriba. El historial de este archivo es público en este repositorio, así que puedes ver
exactamente qué cambió y cuándo.

## Contacto

Preguntas sobre la privacidad o sobre cualquier cosa de este documento:

**dev@giomantovani.com.br**
