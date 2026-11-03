# CardonOptimizer

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform: Windows 10 | 11](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D6.svg)](#)
[![PowerShell 5.1 | 7](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE.svg)](#)
[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](CHANGELOG.md)

**[Español](#español) · [English](#english)**

---

## Español

**CardonOptimizer** es un programa de terminal, escrito en PowerShell, que optimiza y aliviana Windows 10 y 11 de forma **simple y segura**. Libera espacio, quita publicidad y procesos innecesarios y ajusta el sistema para que se sienta más fluido, sin poner en riesgo el equipo ni quitar funciones que necesitas.

> Lo más importante es la seguridad: antes de cada cambio se crea un punto de restauración y un respaldo, todo se puede previsualizar, casi todo se puede deshacer y nada se aplica sin tu confirmación.

### Vista del menú

<!-- Reemplazar por una captura real: docs/screenshot-menu.png -->

```text
  ___                _              ___         _    _         _
 / __| __ _  _ _  __| | ___  _ _   / _ \  _ __ | |_ (_) _ __  (_) ___ ___  _ _
| (__ / _` || '_|/ _` |/ _ \| ' \ | (_) || '_ \|  _|| || '  \ | ||_ // -_)| '_|
 \___|\__,_||_|  \__,_|\___/|_||_| \___/ | .__/ \__||_||_|_|_||_|/__|\___||_|
                                         |_|
  v1.0.0   https://desarrollocardon.com

=== Menú principal ===
  1) Optimización Estándar
  2) Optimización Avanzada
  3) Optimización Extrema (segura)
  4) Vista previa (muestra qué haría un nivel, sin aplicar nada)
  5) Deshacer cambios / restaurar
  6) Ver registro (log)
  7) Cambiar idioma
  0) Salir

[1/21] Limpiando archivos temporales... OK (546,1 MB) - 9733 archivo(s)
[2/21] Limpiando caché de miniaturas... OK (26,1 MB) - 15 archivo(s)
```

### Qué hace cada nivel

Cada nivel incluye al anterior. Todas las acciones se pueden ejecutar varias veces sin problema.

| Nivel | Acción | ¿Se puede deshacer? |
|---|---|---|
| **1 · Estándar** | Borra archivos temporales del usuario y de Windows con más de 24 h (se saltean los que están en uso) | No (limpieza) |
| | Borra la caché de miniaturas | No (limpieza) |
| | Borra la caché de Windows Update ya descargada (detiene y reinicia `wuauserv`) | No (limpieza) |
| | Borra volcados de errores con más de 7 días | No (limpieza) |
| | Vacía la papelera de reciclaje | No (limpieza) |
| | Limpia la caché DNS (`ipconfig /flushdns`) | No hace falta |
| | Plan de energía "Alto rendimiento" (o "Equilibrado"). Avisa si detecta batería | Sí |
| | Desactiva Game DVR (grabación en segundo plano) | Sí |
| | Desactiva sugerencias, publicidad y apps promocionadas (Inicio y Configuración) | Sí |
| **2 · Avanzada** | Efectos visuales para rendimiento, **conservando** el suavizado de fuentes y las miniaturas | Sí |
| | Programas de inicio: lista numerada y **tú eliges** (antivirus y drivers ocultos y protegidos) | Sí |
| | Limita las apps en segundo plano (solo tu usuario) | Sí |
| | Desactiva Widgets / Noticias e intereses | Sí |
| | Telemetría al mínimo que permite tu edición (sin desactivar servicios) | Sí |
| | Limpieza de componentes con DISM, **sin** `/ResetBase` | No (limpieza) |
| | TRIM en SSD, desfragmentación en HDD (nunca desfragmenta un SSD) | No hace falta |
| **3 · Extrema (segura)** | Quita apps preinstaladas de una **lista blanca**, solo las que **tú eliges** | No: se reinstalan desde la Store |
| | Pasa a **Manual** (nunca a Deshabilitado): `Fax`, `MapsBroker`, `RetailDemo`, `WMPNetworkSvc`, `XblAuthManager`, `XblGameSave`, `XboxNetApiSvc` | Sí |
| | Desactiva animaciones de ventanas y transparencias | Sí |
| | Delivery Optimization sin P2P (solo descargas desde Microsoft) | Sí |
| | Plan "Máximo rendimiento" (opcional; se pregunta antes y se recomienda solo en PC de escritorio) | Sí |

Apps que se pueden quitar en el nivel Extremo (si están instaladas): Solitaire Collection, Clipchamp, Noticias, El Tiempo, Obtener ayuda, Sugerencias/Introducción, Centro de opiniones, Portal de realidad mixta, Xbox Console Companion, Xbox (Game Pass), Teams personal, Skype, Office Hub, Contactos, Mapas y Vínculo móvil.

**Nunca se quitan:** Microsoft Store, Edge, Calculadora, Fotos, Cámara, Bloc de notas, Paint, Terminal, Instalador de aplicaciones, Seguridad de Windows ni los componentes de runtime (VCLibs, .NET, UI.Xaml).

### Seguridad

- **Punto de restauración** antes de aplicar cualquier nivel. Si la protección del sistema está desactivada, ofrece activarla. Windows permite crear un solo punto cada 24 h: si ya hay uno reciente, te avisa y decides si continuar.
- **Respaldo en JSON** de todo lo que se modifica (valores de registro previos, tipo de inicio de servicios, plan de energía, programas de inicio y tareas programadas) en `%LOCALAPPDATA%\CardonOptimizer\backups\<fecha-hora>\backup.json`. El respaldo se guarda **antes** de cada cambio. Si no se puede guardar, el cambio no se aplica.
- **Registro (log)** de cada sesión en `%LOCALAPPDATA%\CardonOptimizer\logs\`.
- **Vista previa** (opción 4): muestra exactamente qué valores cambiaría, sin tocar nada.
- **Confirmación** `S/N` antes de cada nivel. Programas de inicio, apps y "Máximo rendimiento" se eligen uno por uno.
- Un error en un paso no detiene el proceso: se registra y se continúa con el siguiente.
- Sin descargas, sin telemetría propia y sin dependencias. Funciona offline.

### Líneas rojas: lo que CardonOptimizer NUNCA hace

- Desactivar o modificar Windows Defender, el Firewall, SmartScreen, UAC o Windows Update.
- Usar "limpiadores de registro" ni borrar claves que no haya creado y respaldado él mismo.
- Borrar archivos de `C:\Windows` (salvo `Temp` y las cachés indicadas), tocar `WinSxS` a mano o el archivo de paginación.
- Deshabilitar servicios. Solo los pasa a Manual, y solo los 7 de la lista.
- Desactivar mitigaciones de seguridad de la CPU ni modificar el arranque (BCD).
- Desinstalar drivers.
- Descargar archivos, enviar datos o usar `Invoke-Expression` u ofuscación.
- Aplicar cambios sin tu confirmación explícita.

Las pruebas automáticas de [`tests/`](tests/CardonOptimizer.Tests.ps1) verifican varias de estas reglas en cada cambio del código.

### Instalación y uso

**Requisitos:** Windows 10 u 11 y permisos de administrador. Usa Windows PowerShell 5.1, que ya viene con Windows; también funciona con PowerShell 7.

1. Descarga el proyecto:
   - **ZIP:** botón verde **Code → Download ZIP** y descomprímelo, o
   - **Git:**
     ```powershell
     git clone https://github.com/AlvaroAramayoChain/CardonOptimizer.git
     ```
2. Ejecútalo:
   - **Doble clic en `Ejecutar.bat`** y acepta el aviso de permisos de Windows, o
   - desde PowerShell, en la carpeta del proyecto:
     ```powershell
     powershell -ExecutionPolicy Bypass -File .\CardonOptimizer.ps1
     ```
   `-ExecutionPolicy Bypass` solo afecta a ese proceso: no cambia la política de tu sistema.
3. Elige el idioma, revisa la **Vista previa** (opción 4) y después aplica el nivel que prefieras.

> Recomendación: empieza por el nivel **Estándar**. Si todo va bien, prueba el **Avanzado**.

### Cómo deshacer cambios

1. Abre CardonOptimizer y elige **5) Deshacer cambios / restaurar**.
2. Elige el respaldo por fecha. Se restauran los valores originales del registro, el tipo de inicio de los servicios, el plan de energía, los programas de inicio y las tareas programadas. Si el script creó una clave o un plan de energía, también los elimina.
3. Reinicia el equipo.

Como alternativa, puedes volver al **punto de restauración** creado antes de aplicar: `Inicio → "Crear un punto de restauración" → Restaurar sistema`.

**Las apps quitadas no se restauran desde el respaldo.** Para reinstalarlas, abre **Microsoft Store**, búscalas por su nombre y pulsa **Obtener** (o usa `winget install "<nombre>"`). Los archivos borrados en la limpieza tampoco se recuperan, pero eran temporales y cachés.

### Cómo agregar un idioma

1. Copia `lang/en.psd1` como `lang/<código>.psd1`, por ejemplo `lang/pt.psd1`.
2. Traduce los valores, sin cambiar las claves ni los marcadores `{0}`, `{1}`.
3. Ajusta `LanguageName`, `LanguagePrompt`, `SortOrder` (posición en el selector), `YesKey` y `NoKey`.
4. Guarda el archivo en **UTF-8 con BOM**.
5. Corre las pruebas: verifican que tenga exactamente las mismas claves y marcadores que `es.psd1`.

El selector de idioma muestra automáticamente todos los archivos de `lang/`.

### Preguntas frecuentes

**¿Es seguro?**
Está diseñado para serlo: solo hace cambios conservadores y reversibles, crea un punto de restauración y un respaldo, pide confirmación y nunca toca la seguridad del sistema. Aun así, ningún software está libre de errores. Lee el código antes de ejecutarlo: es un único archivo comentado.

**¿Mejora los FPS en juegos?**
Seamos honestos: el impacto en FPS suele ser **pequeño o nulo**. Lo que sí notarás es menos procesos en segundo plano, un inicio más rápido si deshabilitas programas de inicio, más espacio libre y un sistema más fluido. Ninguna herramienta de este tipo reemplaza actualizar el hardware (más RAM, un SSD) ni tener los drivers al día.

**¿Funciona en notebooks?**
Sí. Si detecta una batería, avisa que el plan "Alto rendimiento" puede consumir más, y recomienda no activar "Máximo rendimiento". Puedes volver a "Equilibrado" desde *Deshacer* o desde la configuración de energía de Windows.

**¿Por qué no desactiva más servicios o "tweaks" populares?**
Porque muchos de esos ajustes rompen funciones como la impresión, el Bluetooth, la búsqueda o las actualizaciones, o reducen la seguridad, y su beneficio real es mínimo. Ante la duda, un ajuste no se incluye.

**¿Funciona si mi usuario no es administrador?**
Necesita permisos de administrador. Si eleva con **otra** cuenta, los ajustes "de usuario" se aplican a esa cuenta y no a la tuya. Úsalo desde la cuenta que vas a optimizar.

**¿Dónde quedan los respaldos y logs?**
En `%LOCALAPPDATA%\CardonOptimizer\`. Puedes borrar esa carpeta cuando quieras, pero perderás la opción de deshacer.

### Desarrollo y pruebas

```powershell
# Pruebas (Pester 5). No necesitan administrador y no modifican el sistema.
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester -Path .\tests -Output Detailed

# Análisis estático
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path .\CardonOptimizer.ps1
```

Cada optimización es una entrada declarativa en `Get-CardonActionCatalog` con `Id`, `Level`, `Category`, `Reversible`, `Apply` y `Revert`. Sus textos están en `lang/*.psd1` (`Action_<Id>_Name` y `Action_<Id>_Desc`). Todo cambio pasa por helpers (`Set-CardonRegistryValue`, `Set-CardonServiceManual`, etc.) que respetan `$script:DryRun` y guardan el respaldo antes de escribir.

### Aviso legal

CardonOptimizer se distribuye "tal cual", sin garantías, bajo la [licencia MIT](LICENSE). **Lo usas bajo tu propia responsabilidad.** Te recomendamos leer el código antes de ejecutarlo y tener un respaldo de tus archivos importantes.

### Contribuir y contacto

Las contribuciones son bienvenidas. Abre un *issue* para proponer cambios y envía un *pull request* con las pruebas pasando. Los ajustes nuevos deben cumplir las líneas rojas y ser reversibles.

- Correo: **contacto@desarrollocardon.com**
- Web: **https://desarrollocardon.com** · Autor: **Alvaro Aramayo Chain** — https://alvaroaramayochain.github.io/

---

## English

**CardonOptimizer** is a PowerShell console program that optimizes and lightens Windows 10 and 11 in a **simple and safe** way. It frees disk space, removes ads and unneeded background activity, and tunes the system so it feels smoother, without putting the computer at risk or removing features you need.

> Safety comes first: a restore point and a backup are created before every change, everything can be previewed, almost everything can be undone and nothing is applied without your confirmation.

### Menu preview

<!-- Replace with a real screenshot: docs/screenshot-menu.png -->

```text
=== Main menu ===
  1) Standard optimization
  2) Advanced optimization
  3) Extreme optimization (safe)
  4) Preview (shows what a level would do, without applying anything)
  5) Undo changes / restore
  6) View log
  7) Change language
  0) Exit

[1/21] Cleaning temporary files... OK (546.1 MB) - 9733 file(s)
```

### What each level does

Each level includes the previous one. Every action can be run several times safely.

| Level | Action | Can it be undone? |
|---|---|---|
| **1 · Standard** | Deletes user and Windows temp files older than 24 h (files in use are skipped) | No (cleanup) |
| | Deletes the thumbnail cache | No (cleanup) |
| | Deletes already downloaded Windows Update files (stops and restarts `wuauserv`) | No (cleanup) |
| | Deletes crash dumps older than 7 days | No (cleanup) |
| | Empties the Recycle Bin | No (cleanup) |
| | Flushes the DNS cache (`ipconfig /flushdns`) | Not needed |
| | "High performance" power plan (or "Balanced"). Warns if a battery is detected | Yes |
| | Disables Game DVR background recording | Yes |
| | Disables suggestions, ads and promoted apps (Start and Settings) | Yes |
| **2 · Advanced** | Visual effects for performance, **keeping** font smoothing and thumbnails | Yes |
| | Startup programs: numbered list, **you choose** (antivirus and drivers hidden and protected) | Yes |
| | Limits background apps (your user only) | Yes |
| | Disables Widgets / News and interests | Yes |
| | Telemetry at the minimum your edition allows (no services disabled) | Yes |
| | DISM component cleanup, **without** `/ResetBase` | No (cleanup) |
| | TRIM on SSD, defragmentation on HDD (never defragments an SSD) | Not needed |
| **3 · Extreme (safe)** | Removes preinstalled apps from an **allow-list**, only the ones **you choose** | No: reinstall from the Store |
| | Sets to **Manual** (never Disabled): `Fax`, `MapsBroker`, `RetailDemo`, `WMPNetworkSvc`, `XblAuthManager`, `XblGameSave`, `XboxNetApiSvc` | Yes |
| | Disables window animations and transparency | Yes |
| | Delivery Optimization without P2P (downloads only from Microsoft) | Yes |
| | "Ultimate Performance" power plan (optional; you are asked; desktops only) | Yes |

Apps that can be removed in the Extreme level (if installed): Solitaire Collection, Clipchamp, News, Weather, Get Help, Tips/Get Started, Feedback Hub, Mixed Reality Portal, Xbox Console Companion, Xbox (Game Pass), Teams (personal), Skype, Office Hub, People, Maps and Phone Link.

**Never removed:** Microsoft Store, Edge, Calculator, Photos, Camera, Notepad, Paint, Terminal, App Installer, Windows Security and runtime components (VCLibs, .NET, UI.Xaml).

### Safety

- **Restore point** before applying any level. If system protection is off, it offers to turn it on. Windows allows one restore point every 24 h: if a recent one exists, you are told and you decide whether to continue.
- **JSON backup** of everything that changes (previous registry values, service start types, power plan, startup entries and scheduled tasks) in `%LOCALAPPDATA%\CardonOptimizer\backups\<date-time>\backup.json`. The backup is saved **before** each change. If it cannot be saved, the change is not applied.
- **Session log** in `%LOCALAPPDATA%\CardonOptimizer\logs\`.
- **Preview** (option 4): shows exactly which values would change, without touching anything.
- **Y/N confirmation** before each level. Startup programs, apps and "Ultimate Performance" are chosen one by one.
- An error in one step does not stop the process: it is logged and the next step runs.
- No downloads, no telemetry of its own, no dependencies. Works offline.

### Red lines: what CardonOptimizer NEVER does

- Disable or modify Windows Defender, the Firewall, SmartScreen, UAC or Windows Update.
- Use "registry cleaners" or delete keys it did not create and back up itself.
- Delete files from `C:\Windows` (except `Temp` and the listed caches), touch `WinSxS` manually or the page file.
- Disable services. It only sets them to Manual, and only the 7 listed.
- Disable CPU security mitigations or modify the boot configuration (BCD).
- Uninstall drivers.
- Download files, send data, or use `Invoke-Expression` or obfuscation.
- Apply changes without your explicit confirmation.

The automated tests in [`tests/`](tests/CardonOptimizer.Tests.ps1) check several of these rules on every code change.

### Installation and usage

**Requirements:** Windows 10 or 11 and administrator rights. It uses Windows PowerShell 5.1, which comes with Windows; PowerShell 7 also works.

1. Get the project:
   - **ZIP:** green **Code → Download ZIP** button, then extract it, or
   - **Git:**
     ```powershell
     git clone https://github.com/AlvaroAramayoChain/CardonOptimizer.git
     ```
2. Run it:
   - **Double-click `Ejecutar.bat`** and accept the Windows permission prompt, or
   - from PowerShell, in the project folder:
     ```powershell
     powershell -ExecutionPolicy Bypass -File .\CardonOptimizer.ps1
     ```
   `-ExecutionPolicy Bypass` only applies to that process: your system policy is not changed.
3. Choose your language, check the **Preview** (option 4) and then apply the level you want.

> Tip: start with **Standard**. If everything is fine, try **Advanced**.

### How to undo changes

1. Open CardonOptimizer and choose **5) Undo changes / restore**.
2. Pick the backup by date. Original registry values, service start types, power plan, startup programs and scheduled tasks are restored. Keys and power plans created by the script are removed.
3. Restart the computer.

Alternatively, go back to the **restore point** created before applying: `Start → "Create a restore point" → System Restore`.

**Removed apps are not restored from the backup.** To reinstall one, open **Microsoft Store**, search for it by name and click **Get** (or use `winget install "<name>"`). Files deleted by the cleanup cannot be recovered either, but they were temporary files and caches.

### How to add a language

1. Copy `lang/en.psd1` to `lang/<code>.psd1`, for example `lang/pt.psd1`.
2. Translate the values, without changing the keys or the `{0}`, `{1}` placeholders.
3. Set `LanguageName`, `LanguagePrompt`, `SortOrder` (position in the selector), `YesKey` and `NoKey`.
4. Save the file as **UTF-8 with BOM**.
5. Run the tests: they check that it has exactly the same keys and placeholders as `es.psd1`.

The language selector automatically lists every file in `lang/`.

### FAQ

**Is it safe?**
It is designed to be: it only makes conservative, reversible changes, creates a restore point and a backup, asks for confirmation and never touches system security. Still, no software is bug-free. Read the code before running it: it is a single commented file.

**Does it increase FPS in games?**
Honestly, the FPS impact is usually **small or none**. What you will notice is fewer background processes, faster startup if you disable startup programs, more free space and a smoother system. No tool of this kind replaces a hardware upgrade (more RAM, an SSD) or up-to-date drivers.

**Does it work on laptops?**
Yes. If a battery is detected, it warns that "High performance" may use more power and recommends not enabling "Ultimate Performance". You can go back to "Balanced" with *Undo* or in Windows power settings.

**Why doesn't it disable more services or popular "tweaks"?**
Because many of them break features like printing, Bluetooth, search or updates, or reduce security, and their real benefit is minimal. When in doubt, a tweak is left out.

**Does it work if my user is not an administrator?**
It needs administrator rights. If you elevate with a **different** account, the per-user settings are applied to that account, not to yours. Run it from the account you want to optimize.

**Where are backups and logs stored?**
In `%LOCALAPPDATA%\CardonOptimizer\`. You can delete that folder at any time, but you will lose the undo option.

### Development and tests

```powershell
# Tests (Pester 5). They need no admin rights and do not modify the system.
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester -Path .\tests -Output Detailed

# Static analysis
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path .\CardonOptimizer.ps1
```

Each optimization is a declarative entry in `Get-CardonActionCatalog` with `Id`, `Level`, `Category`, `Reversible`, `Apply` and `Revert`. Its texts are in `lang/*.psd1` (`Action_<Id>_Name` and `Action_<Id>_Desc`). Every change goes through helpers (`Set-CardonRegistryValue`, `Set-CardonServiceManual`, etc.) that honor `$script:DryRun` and save the backup before writing.

### Disclaimer

CardonOptimizer is provided "as is", without warranty, under the [MIT License](LICENSE). **Use it at your own risk.** We recommend reading the code before running it and keeping a backup of your important files.

### Contributing and contact

Contributions are welcome. Open an issue to propose changes and send a pull request with the tests passing. New tweaks must respect the red lines and be reversible.

- Email: **contacto@desarrollocardon.com**
- Web: **https://desarrollocardon.com** · Author: **Alvaro Aramayo Chain** — https://alvaroaramayochain.github.io/
