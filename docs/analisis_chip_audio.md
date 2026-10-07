# Análisis del chip de audio: memoria y rendimiento

Revisión del camino de audio del motor (el YMP706 modelado en `src/fs1r/chips/ymp706.cpp`, el filtro
VOP3-1 en `vop3_filter.h`, los efectos en `vop3_effects.h` y el núcleo VOP3 en `vop3_core.h`) en busca
de mejoras de memoria y de CPU. Complementa a `docs/performance.md`, que ya registra lo medido el
2026-09-28; aquí no se repite lo que allí consta salvo para decir en qué estado está.

Fecha: 2026-10-06, rama `feature/revision` (commit `315bb8c`), Apple M1 Pro, clang `-O3`, backend
`FSVR_MATH=LUT`.

**La regla que manda sobre todo lo que sigue** (AGENTS.md, `tuning.h`): una optimización debe dejar la
salida idéntica bit a bit, o bien declarar que no lo hace y pasar `tools/regress.py`, el banco de
capturas y el registro de demos como cualquier cambio en `ymp706.cpp`. Ninguna propuesta toca `cal.h`.
Cada propuesta de abajo indica en cuál de los dos grupos cae.

---

## 1. Cómo se midió

Un arnés de unas treinta líneas (apéndice A, no se ha añadido al repositorio, igual que el `perfbench`
de `performance.md`) carga una performance de la EPROM a través de `Synth`, toca ocho notas, las suelta
a los 3 s, renderiza 6 s en bloques de 256 y calcula un hash FNV-1a de cada muestra de salida. El hash
es lo que demuestra si un cambio es idéntico bit a bit. El perfil se tomó con `sample` de macOS sobre un
binario `-O2 -fno-inline`, 40 s de A020 Vox Morph (`-P 19`) con ocho notas.

### Carga por performance (ocho notas mantenidas, un núcleo)

| performance | canales | carga M1 Pro | carga en `performance.md` (Ryzen 3900X) |
|---|---|---|---|
| A001 Zap ! (0) | 1 | 2,2 % | 4 % |
| A014 Homy (13) | 16 | 16,3 % | 25 % |
| A020 Vox Morph (19) | 16 | 27,0 % | 53 % |
| (23) | 16 | 17,2 % | |
| (24, perf-everybody de `regress.py`) | 32 | 40,0 % | |

Con FTZ activado en el FPCR de ARM los números no se mueven (26,9 % en Vox Morph). En x86 la misma
medida pasaba de 120 % a 53 % (`performance.md`); en los núcleos de Apple los denormales no cuestan, así
que **en macOS ARM no hay nada que ganar por ese lado**, y en Windows/Linux x86 sigue siendo obligatorio.

### Dónde va el tiempo (Vox Morph, 6665 muestras del perfilador)

| función | propio | inclusivo aprox. |
|---|---|---|
| `render_chan` (enrutado, ruido, nivel) | 27 % | ~90 % |
| `EG::tick` (dos por operador y muestra) | 14 % | 14 % |
| `op_sample` + `fm::sin_turns` + `fwin` | 21 % | 18–21 % |
| `fm::db2lin` + `db2lin_fast` | 10 % | 10 % |
| `refresh_ctl` (cada 16 muestras) | 3 % | ~16 % |
| efectos (`FxLine`, `FxTail`, `run_*`) | | ~5 % |
| filtro por voz (`Ladder::run`) | 1 % | 1 % |

Coincide con lo que dice `performance.md`: no hay un punto caliente, el coste es el número de caminos
de operador. Lo nuevo es que `refresh_ctl` sigue siendo un sexto del total, y que dentro de él
`noise_band`, `ures` y su `pow(10, …)` (`__exp10`) suman unos 2,6 puntos.

### Memoria

| estructura | tamaño | comentario |
|---|---|---|
| `Synth` (sin montículo) | 241 KB | de los cuales `Chan[32]` son 195 KB |
| `Chan` | 6104 B | ocho `OpState` de 536 B más los arrays de la CPU |
| `Fseq` | 25,6 KB | `frame[512][50]` fijo |
| líneas de retardo de efectos (montículo) | **6,63 MB** | tres `FxBlock` × cuatro `dl` de 131072 floats, más `er` y la cola |
| `Vop3` (sólo herramientas) | 6,9 KB + 2 MB | `mem` es `vector<double>` de 2^18 |

---

## 2. Propuestas de memoria

### M1. `FxBlock::dl[3]` no se usa nunca: 1,5 MB · idéntico bit a bit · **aplicada 2026-10-06**

`grep -rn "dl\[3\]" src/` no devuelve nada. Cada `FxBlock` reserva cuatro líneas de 512 KB y sólo lee
`dl[0..2]`; la cuarta se reserva en `init` y se borra en `clearState` sin que nadie la lea. Bajar el
array a tres libera 1,5 MB de los 6,63 MB y un cuarto del `memset` que `clearState` hace en el hilo de
audio cada vez que cambia un tipo de efecto. Es un cambio de una línea.

### M2. Las líneas de retardo se redondean a 2,7 s · requiere comprobar rangos

`FxBlock::init` pide `1.5 * sr` = 72000 muestras y `FxLine::init` redondea a la potencia de dos
siguiente, 131072 (2,73 s). El comentario dice que 1365 ms es el tiempo documentado más largo, y
1365 ms a 48 kHz son 65520 muestras, que caben en 65536. Pedir `1.365 * sr` reduciría cada línea a la
mitad (de 4,5 MB a 2,25 MB con M1 aplicada). Antes de hacerlo hay que confirmar en la Effect Parameter
List que ningún tipo admite más de 1365 ms: `fx_ms` deja pasar hasta 1638,3 ms y hoy esos valores fuera
de rango suenan; con la línea más corta `tap` los recortaría a la longitud de la línea. Si algún tipo
documenta más, se puede dimensionar por tipo en `configure` en lugar de usar un máximo global.

También el bloque de reverberación sólo usa `dl` en los tipos 13 a 16 (los retardos); una asignación
perezosa por tipo ahorraría otros 1,5 MB en el caso habitual. Esto implica asignar memoria fuera de
`init`, así que debe hacerse en el hilo del trabajador, nunca en `render`.

### M3. `OpState::lp[8]` usa dos posiciones · idéntico bit a bit

El ruido no vocal sólo usa `lp[0]` y `lp[1]`. Son 48 B por operador, 12 KB en total: poco en bytes,
pero son 12 KB dentro del bloque que el bucle de muestra recorre (véase M4).

### M4. Separar estado caliente y frío de `Chan` · idéntico bit a bit, ganancia por medir

Por muestra, cada canal toca sobre todo sus ocho `OpState` (fase, ventanas, EG, nivel, ruido). Pero
`Chan` intercala con ellos los arrays que sólo usa la CPU a 192,3 Hz o en `note_on` (`egL`, `egR`,
`uegL`, `levelOff`, `pegLvl`, `vcFreq`, …), y `EG` lleva dentro `L[4]` y `R[4]`, que sólo se leen al
cambiar de segmento. Los 32 canales suman 195 KB, por encima de la L1 de datos de cualquier x86 de
escritorio (32 a 48 KB) y por encima de la del M1 (128 KB). Reordenar los campos para que lo que se lee
por muestra quede contiguo, y sacar de `EG` lo que sólo se usa en `next()`, no cambia ni un bit de la
salida. La ganancia no se ha medido: con 16 canales activos el conjunto de trabajo real es menor que
195 KB, y el prefetcher puede estar ocultando ya el coste. Es la clase de cambio que hay que medir en
x86, donde la caché es más pequeña, antes de dar por buena.

### M5. El núcleo VOP3, antes de que llegue al bucle de audio · idéntico bit a bit

`Vop3` (`vop3_core.h`) hoy sólo lo usan las herramientas (`vop3_core_check.py`); `vop3_modules.h`
dice que la intención es conectarlo. Tal como está, cada paso hace `push_back` en `rq`/`dq`/`hist` y
`drain` borra el principio del vector con `erase`, y una pasada son 512 pasos: a 48 kHz son 24,6
millones de pasos por segundo por bloque de efectos, con asignaciones dentro del hilo de audio. Como
`LAT` y `DLAT` son constantes (3), las colas caben en un anillo fijo de ocho entradas y `hist` en un
array de 512 que se reinicia por pasada; los valores escritos no cambian, así que la comprobación
bit a bit contra `tools/vop3_interp.py` seguiría pasando. `mem` como `double` es correcto mientras el
Python sea la referencia; no debe pasarse a `float`.

---

## 3. Propuestas de rendimiento

Ordenadas por la relación entre lo que cuestan y lo que dan.

### P1. El umbral de −90 dB sigue pendiente

`performance.md` (punto 1) lo midió: Vox Morph pasa de 53 % a 46 % en x86, porque un operador a nivel 0
se queda en −96 dB y nunca cae por debajo del umbral actual de −100. En el código sigue a −100
(`ymp706.cpp:214` y `:234`). No es idéntico bit a bit y necesita el banco de capturas y el registro de
demos antes de aplicarse, como allí se dice. De todo lo de esta lista es lo más rentable, porque es una
constante.

Los puntos 2 (saltar el no vocal terminado) y la parte de `refresh_ctl` de `performance.md` ya están
hechos: `render_chan` no calcula el ruido cuando `uegdb - s.uatt` está por debajo de −100, y
`refresh_ctl` sale antes con `s.ueg.done()`.

### P2. Memorizar la banda de ruido en `refresh_ctl` · idéntico bit a bit · **aplicada 2026-10-06**

`refresh_ctl` llama, cada 16 muestras y por cada operador no vocal vivo, a `noise_band` (tres o cuatro
interpolaciones y dos `pow(m, skirt)`), a `ures` (un `pow(10, …)`), a `noise_band_var` y a `db2lin`, y
todo ello depende sólo de `(ureg, u.skirt, u.res)`, que cambian con el controlador o la Fseq y no en
cada refresco. Guardar en `OpState` la última clave y los cuatro resultados (`na`, `na2`, `nscale`,
`nres` sin el término de nivel) y recalcular sólo cuando la clave cambie da el mismo resultado, porque
son funciones puras de enteros. En Vox Morph el perfil pone `noise_band`, `ures` y `__exp10` en unos
2,6 puntos de los 27; la ganancia esperada es de ese orden en los parches que usan los ocho operadores
no vocales y nula en los demás.

### P3. Cálculos por muestra que son constantes en los efectos · idéntico bit a bit · **aplicada 2026-10-06** (las cuatro filas de la tabla y el `pow(10, 0)` del wah)

Los efectos son un 5 % en Vox Morph, pero algunos tipos hacen libm por muestra sobre valores que sólo
cambian en `configure`. Moverlos a `configure` con la misma expresión no cambia ningún bit:

| tipo | línea | por muestra hoy |
|---|---|---|
| Gate | `vop3_effects.h:487` | `pow(10, umbral / 20)` |
| Compressor, Comp+Dist | `:499` | `pow(10, umbral / 20)` (el `pow(th / e, …)` de la línea 501 sí depende de la muestra) |
| Lo-Fi | `:537`, `:542` | `pow(2, bits - 1)` y `pow(10, (w2 - 6) / 20)` |
| Phaser 1 y 2 | `:404` | el mismo `tan(PI * f / sr)` calculado dos veces por canal; basta una |

Dos casos más son caros pero no se pueden mover sin cambiar la salida, y quedan anotados por si se mide:

- **Auto Wah, Touch Wah y Wah+Dist** (`:462`) llaman a `Biq::set` en cada muestra: `cos`, `sin` y un
  `pow(10, 0)` que siempre da 1. Quitar el `pow` cuando la ganancia es 0 es idéntico; recalcular el
  filtro cada N muestras no lo es.
- **`dist_stage`** (`:610`) hace dos `pow` por muestra y canal. Son inherentes a la curva elegida.

### P4. Tiempo real: el hilo de audio puede bloquearse · no afecta a la salida · **medida, no se aplica**

**Corrección del 2026-10-06, después de medir.** Lo que sigue describe el mecanismo correctamente, pero
exageraba el riesgo. Medido con `Device` en el M1 Pro (Release): `loadRomPerformance` retiene el candado
0,5 µs de media y 2,8 µs en el peor de las 384 performances; `getState`, 26 µs de media y 66 µs en el
peor; `setState`, 13 µs y 38 µs; y `FxBlock::clearState`, 22 µs con M1 aplicada (28 µs antes). Un bloque
de 256 muestras a 48 kHz son 5333 µs, y uno de 32 muestras, 667 µs: la peor espera es como mucho un 10 %
del bloque más pequeño habitual. Una reescritura sin candados no se justifica con estos números; si un
host con buffers muy cortos diera cortes al cargar, se volvería a medir allí. Lo que sigue queda como
descripción del mecanismo:

- `Synth::render` toma `std::lock_guard` sobre `mtx`, que es **bloqueante**. El plug-in hace
  `try_lock` sobre su propio `ctl`, pero llama a `dev.process` lo consiga o no, y el trabajador entra en
  `s.mtx` a través de `rom_perf`, `load_sysex` y `getState` (`rom.cpp:44`, `:58`, `:158`;
  `device.cpp:78`). Mientras dure la decodificación de una performance o la serialización del estado, el
  hilo de audio espera.
- `push_sysex` copia un `std::vector` dentro de `outQ` (una asignación de memoria en el hilo de audio
  cuando una respuesta sysex llega por `sendMidi`), y `nextMidiOut` borra del principio del vector.
- `FxBlock::clearState` borra 2 MB por bloque (1,5 MB con M1) en el hilo de audio al cambiar de tipo.

Lo que funciona en este tipo de motor es preparar fuera y publicar dentro: decodificar la performance en
una copia sin el candado y tomarlo sólo para intercambiarla, y sustituir `outQ` por una cola de un
productor y un consumidor de tamaño fijo. Es trabajo en `src/fsvr/` y `firmware/rom.cpp`, ninguno con
contrapartida en el hardware.

### P5. Contracción FMA: la referencia tampoco cuadra en ARM por esto · decisión de proyecto

`CLAUDE.md` atribuye el fallo de `regress.py` fuera de Windows a `rand()`. Hay una segunda causa: clang
en ARM contrae `a * b + c` en FMA por defecto, y eso cambia la salida. Medido con el arnés: el mismo
código da hash `4cd6c1a19afc3744` con el valor por defecto y `85e072d2e896579e` con
`-ffp-contract=off`, y la versión sin FMA es un 10 % más lenta en el M1 (8,19 s frente a 7,44 s).

Si se quiere que `regress_ref.json` valga en todas las plataformas, hacen falta las dos cosas:
`-ffp-contract=off` en `fs1rLib` y un generador propio en lugar de `rand()` (el motor ya tiene un
xorshift para el ruido). Lo segundo cambia la salida en Windows y exige un `--update` justificado en el
commit. Antes conviene comprobar si ese `rand()` sustituye a un generador del firmware: si el firmware
tiene el suyo, lo correcto es portarlo citando su `FUN_`, no inventar otro.

### P6. SIMD entre canales, no entre operadores · idéntico bit a bit si se hace en `double`

`performance.md` (punto 4) propone vectorizar los ocho operadores y advierte que el enrutado del
algoritmo (`Cb`, `H`, `S`, realimentación) es serie dentro del canal. El eje que no tiene esa
dependencia es el canal: dos canales de la misma parte comparten voz, algoritmo y forma de cada
operador, y no se leen entre sí. Procesar dos (NEON) o cuatro (AVX2) canales de la misma parte por
carriles mantiene el mismo orden de operaciones por canal, así que en `double` y sin FMA (P5) puede ser
idéntico bit a bit. Exige reescribir `render_chan` como estructura de arrays y agrupar canales por parte,
y las ramas por forma (`v.form`) obligan a máscaras. Es el cambio grande de esta lista; sólo merece la
pena si P1 y P2 no bastan.

### P7. Nivel en dominio lineal · no idéntico

`fm::db2lin` más `db2lin_fast` son un 10 %. En un segmento descendente el EG baja en dB de forma
lineal, lo que en amplitud es una progresión geométrica: una multiplicación por muestra en lugar de una
lectura interpolada de tabla. Acumula redondeo y cambia bits, así que entra en el grupo de P1 (banco de
capturas y registro de demos), con el error acotado contra la tabla de 1/16 dB que ya se acepta.

---

## 4. Experimentos que no funcionaron

Dos cambios evidentes en `render_chan`, los dos idénticos bit a bit (mismo hash) y los dos **más lentos**:

| cambio | total 8 performances | frente a la base (7,44–7,62 s) |
|---|---|---|
| fusionar los dos bucles de vida del final (`alive`, `carriersDone`) en el bucle de operadores | 7,83–8,09 s | +5 a +9 % |
| saltar un operador cuyo EG vocal y no vocal han terminado, sin grano en vuelo y con `att`, `attS` ≥ −20 dB (manteniendo el deslizamiento de `attS`) | 8,78 s | +15 % |

El segundo es correcto (`note_on` reinicia `attS` en `notes.cpp:113` y `EG::start` reinicia el
envolvente) y aun así pierde: en esta carga hay pocos operadores terminados, y la rama de más cambia cómo
el compilador organiza `render_chan`, que es `inline` y grande. La lección es la de `performance.md`:
**cualquier cambio en el bucle de muestra se mide antes de darlo por bueno**, y conviene medirlo en x86 y
en ARM, porque la forma del código manda más que el recuento de operaciones.

También se probó `-O2` frente a `-O3` con clang en ARM: mismo hash y mismo tiempo.

---

## 5. Resultado del primer grupo (2026-10-06)

Aplicadas M1, P2 y P3; P4 se midió y no se aplica (sección 3). Todo en el M1 Pro, Release:

| comprobación | resultado |
|---|---|
| hash del arnés, 8 performances (apéndice A) | `4cd6c1a19afc3744` antes y después |
| hash por tipo de efecto, 29 de variación y 41 de inserción, cuatro juegos de parámetros cada uno | idéntico en los 70 |
| WAV de `render_capture` con `-P 19`, `-P 24` y `-P 78`, binario anterior frente a nuevo | mismo SHA-1 |
| `tools/regress.py`, huella del binario anterior y comparación con el nuevo | 19 de 19 |
| `ctest` (effects, engine), `check_formant`, `check_presets` | pasan |
| tiempo total del arnés, mejor de cinco | 7,60 s → 7,14 s (−6 %) |
| A020 Vox Morph, mejor de cinco | 1,613 s → 1,558 s (−3,4 %) |
| memoria de las líneas de retardo de efectos | 6,63 MB → 5,13 MB |

La mejora de tiempo es mayor en el total que en Vox Morph porque M1 también reduce lo que el sistema
tiene que tocar en memoria y P2 actúa en todos los parches con ruido. Lo que más CPU dará sigue siendo
P1, que cambia la salida.

---

## 6. Observaciones laterales

- **`build/` está configurado en Debug** (`CMAKE_BUILD_TYPE:STRING=Debug` en `build/CMakeCache.txt`),
  aunque `CMakeLists.txt` pone Release por defecto si no se indica nada. Quien mida con ese árbol obtendrá
  números sin sentido; las medidas de aquí salen de un árbol Release aparte.
- **`Device::getState` vacía `outQ`** antes y después de serializar (`device.cpp:80` y `:88`). Si había
  respuestas sysex pendientes para el host, se pierden al guardar la sesión.
- Código muerto en `configure_reverb` (`vop3_effects.h:194`):
  `if (type == 13 || type == 14) { if (w[7 - 1] || true) {} }`.

---

## 7. Orden recomendado

| # | propuesta | salida | esfuerzo | ganancia |
|---|---|---|---|---|
| 1 | M1 `dl[3]` fuera | idéntica | una línea | 1,5 MB |
| 2 | P3 constantes de efectos | idéntica | pequeño | sólo en esos tipos |
| 3 | P2 memorizar banda de ruido | idéntica | pequeño | ~2–3 puntos en parches con ruido |
| 4 | P1 umbral −90 dB | cambia | una constante y el banco | ~13 % en Vox Morph (x86) |
| 5 | P4 candado y colas | idéntica | medio | elimina bloqueos al cargar |
| 6 | M2 líneas de 1,365 s | cambia fuera de rango | pequeño, más verificar la lista | 2,25 MB |
| 7 | P5 FMA y `rand()` | cambia | decisión de proyecto | referencia multiplataforma |
| 8 | M4 caliente/frío | idéntica | medio | por medir en x86 |
| 9 | M5 colas fijas en `Vop3` | idéntica | pequeño | prerrequisito para conectarlo |
| 10 | P6 SIMD entre canales | idéntica | grande | el mayor margen restante |
| 11 | P7 nivel lineal | cambia | medio | hasta ~10 % |

Cada cambio idéntico se demuestra con el hash de un render fijo antes y después, como pide `AGENTS.md`.
Los que cambian la salida pasan además `tools/regress.py` (con huella propia en macOS, véase
`CLAUDE.md`), el banco de capturas y el registro de demos, y su commit explica el porqué.

---

## Apéndice A. El arnés

Se compila contra las fuentes, no contra la biblioteca, para poder sustituir `ymp706.cpp` por una copia
modificada:

```cpp
#include "fs1r/internal.h"
#include <chrono>
int main(int argc, char** argv) {
    init_tables(); Rom R; load_rom(R, argv[1]);
    uint64_t h = 1469598103934665603ull; double tot = 0;
    for (int p : {0, 13, 19, 23, 24, 40, 77, 100}) {
        Synth* s = new Synth; s->rom = &R; rom_perf(*s, R, p);
        for (int i = 0; i < 8; i++) s->midi_in(0x90, 48 + i * 3, 100);
        static float L[256], Rb[256];
        auto t0 = std::chrono::steady_clock::now();
        for (int i = 0; i < 48000 * 6; i += 256) {
            if (i == 48000 * 3) for (int k = 0; k < 8; k++) s->midi_in(0x80, 48 + k * 3, 0);
            s->render(L, Rb, 256);
            for (int k = 0; k < 256; k++) { uint32_t a, b; memcpy(&a, &L[k], 4); memcpy(&b, &Rb[k], 4);
                h = (h ^ a) * 1099511628211ull; h = (h ^ b) * 1099511628211ull; }
        }
        double dt = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count(); tot += dt;
        printf("perf %3d %.3f s\n", p, dt); delete s;
    }
    printf("total %.3f s  hash %016llx\n", tot, (unsigned long long)h);
}
```

```bash
S=src   # o la copia modificada
clang++ -std=c++17 -O3 -DNDEBUG -DFSVR_MATH=1 -I$S hash.cpp $S/fs1r/chips/ymp706.cpp \
    $S/fs1r/firmware/*.cpp $S/fsvr/fastmath.cpp $S/fsvr/device.cpp $S/fsvr/selftest.cpp -o hash
./hash "Yamaha FS1R v1.20 EPROM Firmware.bin"
```
