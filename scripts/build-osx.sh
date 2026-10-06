#!/bin/sh
# Compila el plug-in de FSVR en macOS desde el CMakeLists de la raíz, con
# FSVR_BUILD_PLUGIN=ON: Hollow (hollow/) con la skin de plugin/skin y el motor
# fs1rLib detrás.
#
# Recibe el formato a compilar como primer argumento —AU, CLAP, VST3, VST2,
# Standalone o ALL—, porque compilar los cinco cuesta y casi nunca hace falta:
#
#   sh scripts/build-osx.sh AU     # sólo el .component
#   sh scripts/build-osx.sh ALL    # los cinco, lo que construye la CI
#
# Sin argumento no hace nada: no hay defecto a propósito, para que nadie se
# coma los cinco formatos por descuido.
#
# Siempre sale universal (arm64 y x86_64): lo fija hollow/cmake/HollowDefaults.cmake
# en la caché, igual que en la CI, y aquí no se toca.
#
# Al compilar bien, el script copia cada producto de build/plugin/out a
# bin/<Formato>/ (hollow_add_plugin, BIN): bin/AU/FSVR.component,
# bin/CLAP/FSVR.clap, bin/VST3/FSVR.vst3, bin/VST2/FSVR.vst y
# bin/Standalone/FSVR.app. Eso es lo que se prueba y lo que se instala.
#
# Palabras opcionales después del formato, en cualquier orden:
#
#   test      al terminar, compila y corre check_plugin y check_gui (ctest -R
#             "plugin|gui"), los checks que AGENTS.md exige si tocaste plugin/,
#             hollow/ o la skin. Con tres intentos, como la CI: son checks con
#             hilos y uno puede fallar suelto en una máquina cargada; un fallo
#             real falla los tres.
#   install   al terminar bien, copia los bundles a los directorios del sistema
#             (/Library/Audio/Plug-Ins/… y /Applications) reemplazando lo que
#             hubiera. Pide contraseña de administrador y pisa lo instalado, así
#             que no hay defecto: sin la palabra no se toca nada fuera de build/
#             y bin/.
#
#   sh scripts/build-osx.sh AU install         compila el .component y lo instala
#   sh scripts/build-osx.sh ALL test install   todo, con los checks, instalado
#
# El primer configure descarga los SDK de CLAP, VST3 y AU, clap-wrapper,
# RtAudio, RtMidi y los decodificadores de Import Audio, así que la primera vez
# necesita red.
#
# La salida de CMake y del compilador —miles de líneas— va entera a
# logs/build-osx-<fecha>-<hora>.log; por pantalla sólo pasan las etiquetas de
# cada paso. Si algo falla se vuelcan las últimas líneas del log. El andamiaje
# (colores, log, pasos, trap) está en common.sh.
set -e

ROOT=$(cd "$(dirname "$0")/.."; pwd)
. "$ROOT/scripts/common.sh"

uso()
{
    cat >&2 <<USAGE
${C_FUERTE}uso:${C_OFF} build-osx.sh <FORMATO> [test] [install]

  ${C_FUERTE}AU${C_OFF}          Audio Unit v2 (FSVR.component), el único que carga Logic Pro
  ${C_FUERTE}CLAP${C_OFF}        CLAP (FSVR.clap)
  ${C_FUERTE}VST3${C_OFF}        VST3 (FSVR.vst3)
  ${C_FUERTE}VST2${C_OFF}        VST2 (FSVR.vst)
  ${C_FUERTE}Standalone${C_OFF}  aplicación suelta (FSVR.app)
  ${C_FUERTE}ALL${C_OFF}         los cinco formatos

  ${C_FUERTE}test${C_OFF}        además, corre check_plugin y check_gui
  ${C_FUERTE}install${C_OFF}     además, instala en el sistema (contraseña de administrador):
              AU en /Library/Audio/Plug-Ins/Components, CLAP en .../CLAP,
              VST3 en .../VST3, VST2 en .../VST y Standalone en /Applications,
              reemplazando lo que hubiera. Sin esta palabra sólo se compila.

Ningún nombre distingue mayúsculas de minúsculas (au, Vst3, all...). Todo sale
universal (arm64 y x86_64), en bin/<Formato>/:

  sh scripts/build-osx.sh AU install          compila el .component y lo instala
  sh scripts/build-osx.sh VST3 test           compila el .vst3 y corre los checks
  sh scripts/build-osx.sh ALL test install    todo, con los checks, instalado
USAGE
    exit 1
}

[ $# -ge 1 ] && [ $# -le 3 ] || uso

minusculas()
{
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# El nombre de cada formato en los tres sitios donde aparece: el argumento, el
# target que crea hollow_add_plugin (fsvr_<sufijo>) y la carpeta de bin/.
target_de()
{
    case $1 in
        AU)         echo fsvr_auv2 ;;
        CLAP)       echo fsvr_clap ;;
        VST3)       echo fsvr_vst3 ;;
        VST2)       echo fsvr_vst2 ;;
        Standalone) echo fsvr_standalone ;;
    esac
}

case $(minusculas "$1") in
    au|auv2)    FORMAT=AU ;;
    clap)       FORMAT=CLAP ;;
    vst3)       FORMAT=VST3 ;;
    vst2|vst)   FORMAT=VST2 ;;
    standalone) FORMAT=Standalone ;;
    all)        FORMAT=All ;;
    *)
        printf '%sFormato desconocido:%s %s\n\n' "$C_ROJO" "$C_OFF" "$1" >&2
        uso
        ;;
esac

if [ "$FORMAT" = All ]; then
    FORMATOS="AU CLAP VST3 VST2 Standalone"
else
    FORMATOS=$FORMAT
fi

BUILD="$ROOT/build/plugin"
BIN="$ROOT/bin"
PROBAR=
INSTALAR=
shift
for ARG do
    case $(minusculas "$ARG") in
        test|probar)      PROBAR=1 ;;
        install|instalar) INSTALAR=1 ;;
        *)
            printf '%sArgumento desconocido:%s %s\n\n' "$C_ROJO" "$C_OFF" "$ARG" >&2
            uso
            ;;
    esac
done

[ "$(uname -s)" = Darwin ] || fatal "este script es para macOS; en Windows está build.bat plugin"
command -v cmake >/dev/null 2>&1 || fatal "no está cmake (brew install cmake, 3.24 o más nuevo)"
xcode-select -p >/dev/null 2>&1 || fatal "faltan las herramientas de Xcode (xcode-select --install)"

log_abrir build-osx
titulo "Formato: $FORMAT (arm64;x86_64)"

# Configurar cuesta (descarga los SDK la primera vez) y CMake ya se reconfigura
# solo cuando cambia un CMakeLists, así que sólo se hace si la caché que hay no
# sirve: no existe, se configuró sin el plug-in o con otro macOS mínimo.
#
# El macOS mínimo: HollowDefaults.cmake pone 10.15, pero la libc++ de Xcode 27
# ya no acepta nada por debajo de 11.0 ("The selected platform is no longer
# supported by libc++", y clap-wrapper compila con -Werror), así que aquí se
# pasa 11.0. hollow/ no se toca, que debe seguir igual a la copia de Hollow.
# MACOS_MIN=10.15 lo devuelve a lo de la CI con un Xcode que aún lo acepte.
MACOS_MIN=${MACOS_MIN:-11.0}
CACHE="$BUILD/CMakeCache.txt"
if [ -f "$CACHE" ] && grep -qx 'FSVR_BUILD_PLUGIN:BOOL=ON' "$CACHE" &&
   grep -qx "CMAKE_OSX_DEPLOYMENT_TARGET:STRING=$MACOS_MIN" "$CACHE"; then
    paso "CMake ya configurado en build/plugin"
else
    paso "Configurando CMake, macOS $MACOS_MIN o más nuevo (la primera vez descarga los SDK)"
    cmd cmake -S "$ROOT" -B "$BUILD" -DFSVR_BUILD_PLUGIN=ON -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN"
fi

TARGETS=
for F in $FORMATOS; do
    TARGETS="$TARGETS $(target_de "$F")"
done
[ -n "$PROBAR" ] && TARGETS="$TARGETS check_plugin check_gui"

NUCLEOS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
paso "Compilando$TARGETS (Release, $NUCLEOS núcleos)"
# shellcheck disable=SC2086  # TARGETS se parte en palabras a propósito
cmd cmake --build "$BUILD" --config Release --parallel "$NUCLEOS" --target $TARGETS

# bin/ se rellena aquí desde build/plugin/out, y no se deja al POST_BUILD de
# hollow_add_plugin: ese paso sólo corre cuando el target se vuelve a enlazar,
# así que con todo al día (make no hace nada) un bin/<Formato> borrado no
# volvía. Se borra y se copia entero cada vez, con ditto, para que no quede
# dentro nada de un bundle anterior. Si la compilación falla, set -e sale antes
# de llegar aquí y bin/ no se toca.
OUT="$BUILD/out"
bundle_de()
{
    case $1 in
        AU)         echo "$OUT/FSVR.component" ;;
        CLAP)       echo "$OUT/FSVR.clap" ;;
        VST3)       echo "$OUT/FSVR.vst3" ;;
        VST2)       echo "$OUT/VST2/FSVR.vst" ;;
        Standalone) echo "$OUT/FSVR.app" ;;
    esac
}

paso "Copiando los productos a bin/"
for F in $FORMATOS; do
    ORIGEN=$(bundle_de "$F")
    [ -d "$ORIGEN" ] || fatal "compiló pero no apareció $ORIGEN; mira el log: $LOG"
    rm -rf "${BIN:?}/$F"
    mkdir -p "$BIN/$F"
    cmd ditto "$ORIGEN" "$BIN/$F/$(basename "$ORIGEN")"
done

if [ -n "$PROBAR" ]; then
    paso "Corriendo check_plugin y check_gui"
    cmd ctest --test-dir "$BUILD" -C Release -R "plugin|gui" --output-on-failure --repeat until-pass:3
fi

# Instalación (sólo con `install`) en los directorios del sistema, no en
# ~/Library: hacen falta permisos de administrador, así que se pide la
# contraseña una sola vez —con sudo -v, antes de tocar nada— y las copias
# siguientes reutilizan esa credencial. Se copia con ditto, que conserva
# atributos extendidos y firma del bundle, sobre el destino ya borrado:
# actualizar un bundle in situ deja dentro restos del anterior.
destino_de()
{
    case $1 in
        AU)         echo /Library/Audio/Plug-Ins/Components ;;
        CLAP)       echo /Library/Audio/Plug-Ins/CLAP ;;
        VST3)       echo /Library/Audio/Plug-Ins/VST3 ;;
        VST2)       echo /Library/Audio/Plug-Ins/VST ;;
        Standalone) echo /Applications ;;
    esac
}

instalar()
{
    DESTINO=$(destino_de "$1")
    for ORIGEN in "$BIN/$1"/*; do
        [ -e "$ORIGEN" ] || continue
        NOMBRE=$(basename "$ORIGEN")
        paso "Instalando $NOMBRE en $DESTINO"
        cmd sudo mkdir -p "$DESTINO"
        cmd sudo rm -rf "${DESTINO:?}/$NOMBRE"
        cmd sudo ditto "$ORIGEN" "$DESTINO/$NOMBRE"
        INSTALADOS="$INSTALADOS $DESTINO/$NOMBRE"
    done
}

INSTALADOS=
if [ -n "$INSTALAR" ]; then
    paso "Instalando en el sistema (contraseña de administrador)"
    sudo -v || fatal "sin permisos de administrador no se puede instalar"
    for F in $FORMATOS; do
        instalar "$F"
    done
    # macOS guarda en caché la lista de Audio Units: sin esto Logic puede
    # seguir cargando el .component anterior hasta reiniciar la sesión.
    case " $FORMATOS " in
        *" AU "*)
            paso "Refrescando la caché de Audio Units"
            killall -9 AudioComponentRegistrar >/dev/null 2>&1 || :
            ;;
    esac
fi

fin "Listo en $(transcurrido)s," "$(avisos) (log completo en $LOG)"
for F in $FORMATOS; do
    for P in "$BIN/$F"/*; do
        [ -e "$P" ] && ruta "Producto en" "$P"
    done
done
for P in $INSTALADOS; do
    ruta "Instalado en" "$P"
done
