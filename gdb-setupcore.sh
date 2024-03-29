#!/bin/bash
# jcejka@suse.de
# https://github.com/malyzelenyhnus/gdb-setupcore

function log()
{
    [ $OPT_VERBOSE -eq 0 ] && return
    echo "$@"
}

function usage()
{
    echo
    echo "$(basename $0) [options] <core file>"
    echo "Prepare debug resources for gdb using debuginfod"
    echo "Create directory with executable and all libraries"
    echo "requested by GDB 10.1 to open core seamlessly."
    echo ""
    echo
    echo "Options:"
    echo
    echo "    -h, --help        This help"
    echo "    -d, --debug       Print all commands before execution"
    echo "    -v, --verbose     Be more verbose"
    echo
}

SHORT_OPTS="dhv"
LONG_OPTS="debug,help,verbose"
OPT_TEMP="$(getopt -o "${SHORT_OPTS}" --long "${LONG_OPTS}" -n "gdb-setupcore.sh" -- "$@")"
eval set -- "$OPT_TEMP"

typeset -i OPT_DEBUG=0
# try use hardlinks if possible
typeset -i OPT_LINK=1
typeset -i OPT_VERBOSE=0
typeset -i EXIT=0

while [ "$1" ]; do
    case "$1" in
        "-d"|"--debug")
            set -x
            OPT_DEBUG=1
            ;;
        "-h"|"--help")
            usage
            exit
            ;;
        "-v"|"--verbose")
            # try to increase verbosity
            OPT_VERBOSE=$((${OPT_VERBOSE:-0} + 1))
            export DEBUGINFOD_PROGRESS=1
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown parameter '$1' found. Exiting..." >&2
            EXIT=1
        ;;
    esac
    shift
done

CORE=$1

if ! [ -r "${CORE}" ]; then
    echo "Error: cannot read core file \"${CORE}\"" >&2
    EXIT=1
fi

if [ -z "${DEBUGINFOD_URLS}" ]; then
    echo "Error: environment variable DEBUGINFOD_URLS not set." >&2
    EXIT=1
fi

if [ -z $(which debuginfod-find 2>/dev/null) ]; then
    echo "Error: debuginfod-find not found. "
    EXIT=1
fi

if [ -z $(which eu-unstrip 2>/dev/null) ]; then
    echo "Error: eu-unstrip not found. "
    EXIT=1
fi

[ ${EXIT} -eq 0 ] || exit ${EXIT}

CORE_NAME=$(basename ${CORE})
WORK_SUBDIR=${CORE_NAME}-root
WORK_DIR=$(pwd)/${WORK_SUBDIR}

# I did not found better way how to determine which of the records returned
# by eu-unstrip is executable and which are libraries so it's read from file's output

log "Use gdb to get name of executable binary from core"
CORE_BINARY=$(unset DEBUGINFOD_URLS; gdb -ex quit -c ${CORE} 2>/dev/null | sed -n 's/^Core was generated by `\(.*\)'\''\.$/\1/p' | cut -f1 -d' ')

if [ -z "${CORE_BINARY}" ]; then
    log "Use file utility to get name of executable binary from core"
    CORE_BINARY=$(file -b ${CORE} | sed -n "s/.*execfn: '\([^']*\)'.*/\1/p")
fi

if [ -z "${CORE_BINARY}" ]; then
    log "Failed to find 'execfn' name from core, let's try another way..."
    CORE_BINARY=$(file -b ${CORE} | sed -n "s/.*from '\([^']*\)'.*/\1/p")
fi

if [ -z "${CORE_BINARY}" ]; then
    echo "Failed to determine executable binary's name." >&2
    echo "Please edit .ini file and set proper value to \"file\" option." >&2
else
    echo "Executable binary's name found: \"${CORE_BINARY}\""
fi

log "Reading symbols from core ${CORE}"

# get BUILD_IDs from core, get binaries using debuginfod and create links
# 0x3ffacd00000+0x26000 d00a54489090b1a3e7770c7c0c5e176ac43a2f99@0x3ffacd001d8 . . /lib64/ld-2.22.so
# 0x7ffe71bf0000+0x1000 e77a560007595d823e2c5a34697c0b0ae1ffc767@0x7ffe71bf0540 . - linux-vdso.so.1
# 0x7f0af6dd7000+0xc430 a16a9a5f268f00fca20f0f135a7327682ddb503c@0x7f0af6dd72e8 /lib64/libnss_sss.so.2 . libnss_sss.so.2
# ....
eu-unstrip -n --core ${CORE} | while read ADDR ID FILE DBG MODULE_NAME; do
    BUILDID=${ID%%@*}

    if [ "${FILE}" = '.' ] || [ "${FILE}" = '-' ]; then
            BINARY_PATH="${MODULE_NAME}"
    else
            BINARY_PATH="${FILE}"
    fi
    BINARY_DIR="${WORK_DIR}/$(dirname ${BINARY_PATH})"
    BINARY_NAME="$(basename ${BINARY_PATH})"

    log " downloading: ${BINARY_PATH}, build-id: ${BUILDID}"

    mkdir -p "${BINARY_DIR}"
    BINARY_CACHE_PATH=$(debuginfod-find executable ${BUILDID})
    if [ -z "${BINARY_CACHE_PATH}" ] || [ ! -f "${BINARY_CACHE_PATH}" ]; then
        echo "Failed to get executable for BUILD-ID \"${BUILDID}\" for \"${BINARY_PATH}\"" >&2
        continue
    fi

    if [ -f "${BINARY_DIR}/${BINARY_NAME}" ]; then
        log "file ${BINARY_DIR}/${BINARY_NAME} already exists, skipping"
    else
        # create link if possible, otherwise copy
        if [ ${OPT_LINK} -eq 1 ] && ln "${BINARY_CACHE_PATH}" "${BINARY_DIR}/${BINARY_NAME}" 2>/dev/null; then
            log "create link ${BINARY_DIR}/${BINARY_NAME} -> ${BINARY_CACHE_PATH}"
        else
            # if link failed once use only copy next time
            OPT_LINK=0
            cp "${BINARY_CACHE_PATH}" "${BINARY_DIR}/${BINARY_NAME}"
            log "copy ${BINARY_CACHE_PATH} to ${BINARY_DIR}/${BINARY_NAME}"
        fi
    fi

    # create soname links
    SN=$(eu-readelf -a "${BINARY_CACHE_PATH}" 2>&1 | grep SONAME | sed 's/.*\[\(.*\)\].*/\1/g')
    log " sonames found: $SN"

    for SNX in ${SN}; do
        if ! [ -f "${BINARY_DIR}/${SNX}" ]; then
           log " create soname soft link ${BINARY_DIR}/${SNX} -> ${BINARY_NAME}"
           ln -s "${BINARY_NAME}" "${BINARY_DIR}/${SNX}"
        else
           log " soname link ${BINARY_DIR}/${SNX} already exists, skipping"
        fi

        # gdb sometimes searches library without version suffixes
        # after .so so create them as well
        while [[ "${SNX}" =~ '.so.' ]]; do
            SNX=${SNX%.*}
            if ! [ -f "${BINARY_DIR}/${SNX}" ]; then
                log " create soft link ${BINARY_DIR}/${SNX} -> ${BINARY_NAME}"
                ln -s "${BINARY_NAME}" "${BINARY_DIR}/${SNX}"
            else
                log " link ${BINARY_DIR}/${SNX} already exists, skipping"
            fi
        done
    done
done

# fix common aliases to bash
[ "${CORE_BINARY}" = "/bin/sh" ] && CORE_BINARY="/bin/bash"
[ "${CORE_BINARY}" = "-sh" ] && CORE_BINARY="/bin/bash"

GDB_EXEC_FILE="${WORK_DIR}/${CORE_BINARY}"
# executable path returned by "file" reflect relative path or symlinks used when started
# and might differ from path returned by eu-unstrip under which is the executable stored
if ! [ -f "${GDB_EXEC_FILE}" ]; then
    log "${GDB_EXEC_FILE} does not exists, let's find where is it"
    GDB_EXEC_FILE=$(find ${WORK_DIR} -name $(basename "${CORE_BINARY}"))
fi
log "executable is ${GDB_EXEC_FILE}"

log "Creating .ini file for gdb"

# prepare gdb ini file
cat > ${CORE_NAME}.ini <<END
set solib-absolute-prefix ${WORK_SUBDIR}
set solib-search-path ${WORK_SUBDIR}/:${WORK_SUBDIR}/lib64:${WORK_SUBDIR}/usr/lib64
set print max-symbolic-offset 1
set height 0
file ${GDB_EXEC_FILE}
core ${CORE}
END

echo
echo "gdb --command ${CORE_NAME}.ini"
echo
log "Done."

