# Wiggle

[English](README.md) · **Español**

Una app diminuta de barra de menú (macOS) y bandeja del sistema (Windows) que mueve el cursor un par de píxeles cuando llevas un rato inactivo, para que tu computadora y apps como Teams o Slack no te marquen como ausente.

## Compílala tú mismo, sin instalar nada

Wiggle está pensada para **compilarse desde este repositorio en tu propia máquina**. No hay instalador, ni página de descargas, ni paquete que bajar:

- **Solo necesitas el repo.** Clónalo (o descárgalo como ZIP) y ejecuta un script de compilación.
- **En Windows no hay que instalar nada.** Se compila con el compilador de C# que ya viene en Windows 10 y 11.
- **En macOS solo hacen falta las Command Line Tools de Apple**, que muchas laptops ya tienen.
- **Sin permisos de administrador.** El resultado es una app portable que corre desde cualquier carpeta donde puedas escribir.
- **Sin avisos de "descargado de internet".** Una app compilada localmente no queda en cuarentena, así que Gatekeeper y SmartScreen no tienen nada que marcar.

El código son dos archivos pequeños, así que puedes leer todo lo que hace antes de compilarlo.

## Windows

1. Abre la carpeta `Windows`.
2. Haz doble clic en `build.cmd`.
3. Ejecuta `Windows\dist\Wiggle.exe`.

Aparece un icono con una **W** junto al reloj (puede quedar oculto bajo la flecha `^`). Haz clic para abrir el menú. El icono es verde mientras Wiggle está activo y gris cuando está en pausa.

- **Portable:** `Wiggle.exe` es un solo archivo de unos 64 KB. Cópialo a donde quieras.
- **Los ajustes** se guardan en `wiggle.ini` junto al `.exe`. Si esa carpeta es de solo lectura, simplemente no se conservan.
- **No toca el registro, no instala servicios y no se autoinicia.** Para abrirlo al iniciar sesión, pon un acceso directo en la carpeta que se abre con `Win+R` → `shell:startup`.

## macOS

1. Verifica que tienes las Command Line Tools: `xcode-select -p` imprime una ruta si están instaladas. Si no, ejecuta `xcode-select --install`.
2. Compila:

   ```bash
   cd macOS
   ./build.sh
   ```

3. Ejecútala donde quedó con `open dist/Wiggle.app`.

Aparece un icono con una **W** en la barra de menú. Se ve atenuado mientras Wiggle está en pausa y cambia a una señal de advertencia mientras falte el permiso de Accesibilidad.

`./install.sh` es opcional: compila y luego copia la app a `/Applications`, o a `~/Applications` si no puedes escribir en `/Applications`. Úsalo si quieres "Abrir al iniciar sesión", que necesita que la app se quede en una ubicación fija.

`build.sh` también genera `dist/Wiggle-<versión>.dmg`. Un DMG enviado a otra Mac se trata como una descarga y Gatekeeper lo bloquea, así que la forma confiable de compartir Wiggle es compartir el repo y que cada persona la compile.

### Permiso de Accesibilidad

macOS solo permite que una app mueva el cursor si tiene el permiso de Accesibilidad.

1. La primera vez que inicias Wiggle, macOS muestra un aviso.
2. Abre Ajustes del Sistema → Privacidad y seguridad → Accesibilidad.
3. Activa **Wiggle**.

Mientras no lo hagas, el menú muestra "⚠ Falta el permiso de Accesibilidad" y el cursor no se mueve. Wiggle detecta el permiso en cuanto lo concedes.

La app se firma de forma ad-hoc, así que macOS puede volver a pedir el permiso después de recompilar. Si el interruptor ya está activado y aun así no funciona, quita Wiggle de la lista con "−" y vuelve a agregarla.

## Cómo se comporta

Las dos plataformas siguen las mismas reglas:

| Ajuste | Opciones | Por defecto |
|---|---|---|
| Intervalo | 10 s, 30 s, 1 min, 2 min, 5 min | 30 s |
| Distancia del movimiento | 1, 2, 5, 10, 25 px | 2 px |
| Mover solo si estoy inactivo | sí / no | sí |
| Pausar mientras se reproduce video | sí / no | no |
| Mantener pantalla encendida | sí / no | sí |
| Abrir al iniciar sesión (solo macOS 13+) | sí / no | no |

- Wiggle revisa cada 2 segundos. Con **Mover solo si estoy inactivo** activado, mueve el cursor cuando llevas inactivo el intervalo elegido, y nunca mientras trabajas. Desactivado, lo mueve cada intervalo sin importar lo que hagas.
- Cada movimiento desplaza el cursor hacia un lado la distancia elegida y lo regresa exactamente a donde estaba.
- **Pausar mientras se reproduce video** deja el cursor quieto mientras otra app mantiene la pantalla encendida, que es lo que hacen los reproductores de video, los navegadores con video, las llamadas y las presentaciones. Así no aparecen los controles del reproductor. La contrapartida: las apps de chat miden la actividad de teclado y mouse, así que igual te marcarán como ausente durante un video largo. Una herramienta que mantenga la pantalla encendida todo el tiempo (como `caffeinate -d`) también cuenta, y Wiggle seguirá en pausa mientras esté corriendo.
- **Mantener pantalla encendida** evita que la pantalla se apague mientras Wiggle está activo.
- Wiggle recuerda si estaba activo y restaura ese estado la próxima vez que se abre.
- El menú aparece en español cuando el idioma del sistema es español, y en inglés en cualquier otro caso.

Las apps de chat te marcan como ausente tras un tiempo fijo de inactividad (normalmente 5 minutos), así que elige un intervalo bastante menor.

## Actualizar

- **Si compilaste desde el repo:** baja los últimos cambios y ejecuta de nuevo el script de compilación.
- **Si descargaste una versión publicada:** elige **Buscar actualizaciones…** en el menú. Si existe una versión más nueva, Wiggle ofrece abrir la página de descarga; nunca descarga ni instala nada por su cuenta.

Wiggle nunca se conecta a internet por sí sola. La búsqueda de actualizaciones es su única conexión, va a `api.github.com` y ocurre solo cuando haces clic en esa opción del menú.

Para publicar una versión, súbela en `macOS/Resources/Info.plist` y en las líneas `AssemblyVersion` de `Windows/Program.cs`, compila ambas apps y crea un release en GitHub con el tag `vX.Y.Z` y el DMG y el `.exe` adjuntos. La búsqueda de actualizaciones compara contra el tag del último release.

## Cosas que debes saber

- **La pantalla no se bloqueará sola** mientras Wiggle esté activo. Bloquéala a mano cuando te alejes (`Win+L`, o `Ctrl+Cmd+Q` en Mac).
- **No es invisible.** Los movimientos son entradas sintéticas que un software de monitoreo puede distinguir de un mouse real, y la app no está firmada. Algunas máquinas administradas además impiden ejecutar programas sin firma.
- **Tú eres responsable de cómo la usas.** Revisa qué permiten las políticas de tu organización.

## Estructura del repositorio

```
assets/                    # fuentes del logo y el script que regenera los iconos
macOS/
├── Sources/main.swift     # toda la lógica y la UI
├── Resources/             # Info.plist y el icono de la app
├── build.sh               # compila, firma y crea el DMG
└── install.sh             # opcional: compila y copia a Aplicaciones
Windows/
├── Program.cs             # toda la lógica y la UI
├── Resources/Wiggle.ico   # icono incrustado en el .exe
├── build.cmd              # compila en Windows con el compilador integrado
├── build.sh               # compila desde macOS/Linux (requiere el SDK de .NET)
└── Wiggle.csproj          # archivo de proyecto que solo usa build.sh
```

Los iconos de la app están incluidos en el repo, así que compilar nunca requiere herramientas de imágenes. Si cambias el logo en `assets/`, ejecuta `python3 assets/make_icons.py` en una Mac para regenerarlos. El icono de la barra de menú y de la bandeja se dibuja en código a partir del contorno de `assets/wiggle-menu.svg`.

El código de Windows se limita a C# 5 para que el compilador incluido en Windows pueda compilarlo. `Wiggle.csproj` lo hace cumplir: si se cuela sintaxis más nueva, la compilación con `build.sh` falla.
