# Andamiaje común de scripts/: colores, log, pasos y el trap de salida.
#
# No se ejecuta: se incluye con `.` desde build-osx.sh (y cualquier otro script
# de aquí que lo necesite). El script que lo incluye ya ha
# calculado ROOT:
#
#   ROOT=$(cd "$(dirname "$0")/.."; pwd)
#   . "$ROOT/scripts/common.sh"
#   log_abrir build-osx                     # crea el log e instala el trap
#   titulo "Formato: AU"
#   paso "Configurando CMake"
#   cmd cmake ... ; fin "Listo: ..."
#
# Si el script define una función `limpiar`, el trap la llama al salir (haya
# fallado o no) antes de decidir si vuelca el log.
#
# Colores sólo cuando la salida es una terminal: con NO_COLOR, TERM=dumb o
# redirigida a fichero (la CI) sale texto pelado. FORCE_COLOR=1 los impone
# igualmente, para canalizar a `less -R`.

if [ -n "${FORCE_COLOR:-}" ] ||
   { [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; }; then
    C_OFF=$(printf   '\033[0m')
    C_FUERTE=$(printf '\033[1m')
    C_TENUE=$(printf  '\033[2m')
    C_ROJO=$(printf   '\033[1;31m')
    C_VERDE=$(printf  '\033[1;32m')
    C_AMBAR=$(printf  '\033[1;33m')
    C_AZUL=$(printf   '\033[1;34m')
    C_CIAN=$(printf   '\033[36m')
else
    C_OFF= C_FUERTE= C_TENUE= C_ROJO= C_VERDE= C_AMBAR= C_AZUL= C_CIAN=
fi

# Cuántos logs de cada script se conservan (el que se abre ahora incluido).
LOGS_QUE_QUEDAN=${LOGS_QUE_QUEDAN:-10}

# Abre logs/<nombre>-<fecha>-<hora>.log y deja el camino en $LOG. A partir de
# aquí un fallo ya no es mudo: el trap vuelca la cola del log.
log_abrir()
{
    LOGDIR="$ROOT/logs"
    mkdir -p "$LOGDIR"

    # Se escribe uno por ejecución y nadie los borra: se podan los de este
    # mismo script antes de abrir el nuevo, que los interesantes son los
    # últimos. `logs/` entero sigue siendo borrable a mano.
    ls -t "$LOGDIR/$1"-*.log 2>/dev/null | tail -n "+$LOGS_QUE_QUEDAN" |
    while IFS= read -r viejo; do
        rm -f "$viejo"
    done

    LOG="$LOGDIR/$1-$(date +%Y%m%d-%H%M%S).log"
    : > "$LOG"
    INICIO=$(date +%s)
    trap al_salir EXIT
}

# El log se traga la salida de las herramientas, así que un fallo sin contexto
# sería indepurable: se vuelcan las últimas líneas y se dice dónde está el resto.
al_salir()
{
    ESTADO=$?
    if command -v limpiar >/dev/null 2>&1; then
        # Un fallo limpiando no puede tapar ni cambiar el estado de salida real.
        limpiar || :
    fi
    if [ "$ESTADO" -ne 0 ] && [ -z "${SIN_VOLCADO:-}" ]; then
        printf '\n%sFALLÓ%s (estado %s). Últimas 40 líneas de %s%s%s:\n\n' \
               "$C_ROJO" "$C_OFF" "$ESTADO" "$C_CIAN" "$LOG" "$C_OFF" >&2
        printf '%s' "$C_TENUE" >&2
        tail -n 40 "$LOG" >&2
        printf '%s\n' "$C_OFF" >&2
    fi
    exit "$ESTADO"
}

# Cabecera: qué se va a hacer y dónde queda el log.
titulo()
{
    printf '%s%s%s    %sLog: %s%s\n' "$C_FUERTE" "$1" "$C_OFF" "$C_TENUE" "$LOG" "$C_OFF"
}

# Una etiqueta por paso en pantalla; en el log, una cabecera con el segundo en
# que empieza —para ver dónde se va el tiempo— que separa la salida de cada
# herramienta de la de la anterior.
paso()
{
    printf '%s==>%s %s\n' "$C_AZUL" "$C_OFF" "$1"
    printf '\n===== [t+%ss] %s =====\n' "$(transcurrido)" "$1" >> "$LOG"
}

# Ejecuta una herramienta con toda su salida al log.
cmd()
{
    "$@" >> "$LOG" 2>&1
}

# Error propio del script (no de una herramienta): no hay nada útil en el log,
# así que se dice y se sale sin volcarlo.
fatal()
{
    SIN_VOLCADO=1
    printf '%sError:%s %s\n' "$C_ROJO" "$C_OFF" "$1" >&2
    exit "${2:-1}"
}

# Segundos transcurridos desde log_abrir.
transcurrido()
{
    echo $(( $(date +%s) - INICIO ))
}

# Cuenta de avisos del compilador en el log, coloreada si no es cero. Se cuentan
# líneas distintas: en un binario universal cada aviso sale una vez por
# arquitectura, y contarlas todas informaba del doble.
avisos()
{
    N=$(grep 'warning:' "$LOG" | sort -u | wc -l | tr -d ' ')
    if [ "$N" -eq 0 ]; then
        printf '%s avisos' "$N"
    else
        printf '%s%s avisos%s' "$C_AMBAR" "$N" "$C_OFF"
    fi
}

# Despedida: el primer argumento en verde, el resto —cuentas, camino del log—
# en texto normal para que conserven su propio color. Las líneas siguientes
# (rutas de productos) las imprime cada script con `ruta`.
fin()
{
    printf '\n%s%s%s' "$C_VERDE" "$1" "$C_OFF"
    if [ $# -gt 1 ]; then
        printf ' %s' "$2"
    fi
    printf '\n'
}

ruta()
{
    printf '%s %s%s%s\n' "$1" "$C_CIAN" "$2" "$C_OFF"
}
