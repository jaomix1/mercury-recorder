# mercury-recorder

App de barra de menú para macOS 26+ que graba tus reuniones (micrófono + audio del sistema) y las transcribe en español **en el Mac**, sin enviar audio a internet.

## Compilar

```bash
./scripts/build-app.sh
open build/mercury-recorder.app
```

Solo necesita las Command Line Tools (no Xcode).

El ícono está en `Resources/AppIcon.icns`. Si cambias el diseño en `scripts/make-icon.swift`, regenéralo con `./scripts/make-icon.sh`.

## Uso

1. Clic en el ícono de la barra de menú › **Iniciar grabación** (o **⌃⌥R** desde cualquier app).
2. La primera vez macOS pide permiso de **Micrófono** y de **Grabación de pantalla y audio del sistema**. Tras activar el segundo, cierra y vuelve a abrir la app.
3. Mientras grabas:
   - Las barras de **nivel de audio** muestran si se oyen el micrófono y el sistema. Si una pista lleva 20 s sin sonido, sale un aviso.
   - La app transcribe en vivo y reescribe `transcripcion.md` **cada 30 segundos**.
   - **Capturar pantalla** (o **⌃⌥S**) guarda un PNG y lo marca en la transcripción.
4. Al **Detener grabación** se cierran los audios, la transcripción queda final y, si Apple Intelligence está disponible, se genera el **resumen** (`resumen.md`: resumen, decisiones, tareas, pendientes).
5. **Ver reuniones** abre la ventana con:
   - Botones para grabar y capturar, con el contador y los niveles.
   - **Buscador** en todas las transcripciones; clic en una coincidencia para saltar a ese momento.
   - **Cambiar nombre**, **Resumir**, **Exportar PDF** (acta con resumen, transcripción y capturas), **Eliminar** (a la Papelera).
6. Si Zoom, Teams, Meet, Discord, WhatsApp, FaceTime, Webex o Slack empiezan a usar el micrófono, la app avisa con una notificación **¿Grabar esta reunión?**.
7. **Salir** con una grabación en curso pide confirmación y guarda todo antes de cerrar.

Interruptores del menú: avisar cuando empiece una reunión, abrir al iniciar sesión, resumen automático.

## Recuperación

Si la app se cierra de golpe (fallo, apagón), el `.m4a` queda ilegible. Por eso, mientras graba, la app guarda además un respaldo `*-respaldo.caf` (PCM 16 kHz, ~115 MB por hora y pista) y actualiza `info.json` cada 30 s. Al abrir la app otra vez, rearma los `.m4a` desde los respaldos y transcribe la reunión. Al detener normalmente, los respaldos se borran.

## Archivos de cada reunión

En `~/Documents/Reuniones/<fecha>/`:

| Archivo | Contenido |
|---|---|
| `microfono.m4a` | Tu voz |
| `sistema.m4a` | Lo que suena en el Mac (los demás participantes) |
| `info.json` | Hora de inicio/fin, desfase de cada pista, capturas, nombre |
| `transcripcion.md` | Transcripción con marcas de tiempo, `Yo` / `Participantes` |
| `resumen.md` | Acta generada con Apple Intelligence |
| `captura_<fecha>_<hora>.png` | Capturas de pantalla |
| `*-respaldo.caf` | Solo durante la grabación (respaldo recuperable) |

## Notas

- **Eco sin audífonos:** las frases de `Yo` que repiten lo que sonó por el sistema en ese momento se quitan de la transcripción (el audio no cambia). Con audífonos el resultado sigue siendo mejor.
- **Resumen:** necesita Apple Intelligence activado y su modelo descargado. Si no está listo, el botón **Resumir** explica por qué.
- **Firma:** el script firma con el certificado autofirmado `mercury-recorder` (Acceso a Llaveros) si existe, así los permisos se conservan al recompilar. Sin ese certificado firma ad-hoc y macOS puede volver a pedir los permisos. Otro certificado: `GRABADORA_FIRMA="Nombre" ./scripts/build-app.sh`. Solo sirve en este Mac; para compartir la app hace falta un certificado Developer ID de Apple y notarizarla.
- **Atajos:** ⌃⌥R grabar/detener, ⌃⌥S capturar. Si otra app ya los usa, no se registran.
- **Pruebas sin interfaz** (`build/mercury-recorder.app/Contents/MacOS/mercury-recorder …`):
  - `--autoprueba`: lógica de eco, búsqueda y resumen.
  - `--transcribir <archivo>` · `--transcribir-reunion <carpeta>` · `--probar-vivo <archivo>`
  - `--recuperar <carpeta>` · `--pdf <carpeta> <salida.pdf>` · `--resumir <carpeta>` · `--microfono` · `--links <carpeta>`
- `@State` se usa como `State<T>(initialValue:)` porque el plugin de macros de SwiftUI solo viene con Xcode completo.
