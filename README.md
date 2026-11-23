# Es perfecto porque es imperfecto

Galería espacial 3D interactiva construida en **Three.js** e inspirada en *No soy un robot* (Juan Villoro, 2024), con soporte para **PlayStation VR en Windows (PSVR Directo 360° sin SteamVR)**, **WebXR** y **navegación en escritorio 2D/3D**.

---

## Los 5 actos de la obra

1. **Acto I · El trazo** — Umbral CAPTCHA interactivo y medición del pulso y microtemblor humano.
2. **Acto II · Zona Bradbury** — *Fahrenheit 451*: quema en el presente continuo y rescate de la memoria.
3. **Acto III · El textil** — Telar de cintura ligado al árbol madre, invasión de código y nudo resistente.
4. **Acto IV · La imperfección** — Panteón de supercopias digitales, pausa y grieta *kintsugi*.
5. **Acto V · Autenticidad** — Esfera interior blanca, monitores de señal continua y decisión final (*¿Desea vivir de manera auténtica?*).

---

## Estructura del proyecto

- `index.html` — Escena 3D completa (Three.js r169), shaders GLSL, audio procedural, subtítulos 3D, WebXR y motor **PSVR Directo 360°** (WebHID 1000 Hz + estereoscopía con pre-corrección óptica y cromática).
- `server.js` — Servidor HTTP local en Node.js (`127.0.0.1:8080`) con perfil aislado de Chrome/Edge (`?vr=1`) y puente `/psvr/*` hacia el controlador WinUSB nativo.
- `psvr-usb.ps1` — Script nativo de Windows (`WinUSB` sobre `VID_054C&PID_09AF&MI_05`) para activar o desactivar el modo VR 360° en la caja procesadora del PSVR sin depender de SteamVR ni OpenXR.
- `iniciar-vr.bat` — Lanzador rápido en Windows con doble clic para abrir la simulación en local durante la exposición.

---

## Cómo ejecutar en local (exposición)

### Requisitos
- Windows 10/11 con **Node.js** instalado y **Google Chrome** (o **Microsoft Edge**).
- Para usar gafas **Sony PlayStation VR (PSVR v1/v2)**:
  - Conectar HDMI y USB de la caja procesadora al PC.
  - Configurar pantallas en modo **Ampliar** (`Win + P → Ampliar`) para que el visor sea la Pantalla 2.
  - Cerrar SteamVR e iVRy antes de abrir el lanzador local (para liberar el acceso USB y HDMI del PSVR).

### Arranque rápido
1. Haz doble clic en `iniciar-vr.bat` *(o ejecuta `node server.js --open` en esta carpeta)*.
2. En la ventana que se abre en Chrome:
   - **Para escritorio:** pulsa **Seguir en escritorio 2D**.
   - **Para gafas PSVR 360°:** pulsa en orden:
     1. **1. Activar modo VR del PSVR (USB)**
     2. **2. Conectar giroscopio PSVR (HID)** *(elige `PS VR Sensor` en el diálogo de Chrome)*
     3. **3. PROYECTAR EN PSVR 360° (PANTALLA COMPLETA)** *(si abre en la pantalla principal, usa `Win + Shift + →` o `F`)*

---

## Controles durante la exposición

- **Interactuar / mantener pulsado:** `Clic izquierdo`, `Espacio` / `Enter` o `X` / `R2` (DualShock 4).
- **Recentrar vista al frente:** `Clic derecho`, `C` u `Options` / `Cuadrado`.
- **Cambiar entre actos:** Rueda del ratón, flechas `←` / `→`, teclas `1`–`5`, portales 3D o `L1` / `R1`.
- **Ajustes rápidos en PSVR:**
  - `Q` — Alternar nitidez (`100% nativo` → `125%` → `85%`)
  - `,` / `.` — Afinar fusión óptica (si se percibe doble imagen)
  - `[` / `]` — Curvatura de distorsión de lentes
  - `-` / `+` — Distancia pupilar (IPD)
  - `K` — Recalibrar giroscopio manteniendo el visor quieto
  - `R` / `Clic derecho` / `△` — Reiniciar tras el apagado del Acto V
  - `Esc` — Salir del modo pantalla completa VR
