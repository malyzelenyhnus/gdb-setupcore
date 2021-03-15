#!/bin/bash
# jcejka@suse.de

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
    echo "Create directory with executable and all libraries requested by GDB 10.1 to open core seamlessly."
    echo
    echo "Options:"
    echo
    echo "    -h, --help        This help"
    echo "    -d, --debug       Print all commands before execution"
    echo "    -s, --soft        Use softlinks to cached binaries.  Use if your debuginfod cache directory"
    echo "                      is on different filesystem than your working directory."
    echo "    -v, --verbose     Be more verbose"
    echo
}

SHORT_OPTS="dhsv"
LONG_OPTS="debug,help,soft,verbose"
OPT_TEMP="$(getopt -o "$SHORT_OPTS" --long "$LONG_OPTS" -n "gdb-setupcore.sh" -- "$@")"
eval set -- "$OPT_TEMP"

typeset -i OPT_DEBUG=0
typeset OPT_LINK=""
typeset -i OPT_VERBOSE=0

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
        "-s"|"--soft")
            OPT_LINK="-s"
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
            echo "Unknown parameter '$1' found. Exiting..."
        ;;
    esac
    shift
done

CORE=$1

if ! [ -r "${CORE}" ]; then
    echo "Error: cannot read core file \"${CORE}\"" >&2
    exit 1
fi

CORE_NAME=$(basename ${CORE})
WORK_SUBDIR=${CORE_NAME}-root
WORK_DIR=$(pwd)/${WORK_SUBDIR}
CORE_BINARY=$(file -b ${CORE} | sed -n "s/.*execfn: '\([^']*\)'.*/\1/p")

if [ -z "${CORE_BINARY}" ]; then
    CORE_BINARY=$(file -b ${CORE} | sed -n "s/.*from '\([^']*\)'.*/\1/p")
fi

if [ -z "${CORE_BINARY}" ]; then
    echo "Failed to determine executable binary's name." >&2
    echo "Please edit .ini file and set proper value to \"file\" option." >&2
else
    echo "Executable binary's name found: \"${CORE_BINARY}\""
fi

# get BUILD_IDs from core, get binaries using debuginfod and create links
# 0x3ffacd00000+0x26000 d00a54489090b1a3e7770c7c0c5e176ac43a2f99@0x3ffacd001d8 . . /lib64/ld-2.22.so

log "Reading symbols from core ${CORE}"
eu-unstrip -n --core ${CORE} | while read ADDR ID FILE DBG BINARY; do
    BUILDID=${ID%%@*}

    BINARY_DIR=${WORK_DIR}/$(dirname ${BINARY})
    BINARY_NAME=$(basename ${BINARY})

    log " downloading name: ${BINARY}, build-id: ${BUILDID}"

    mkdir -p ${BINARY_DIR}
    BINARY_CACHE_PATH=$(debuginfod-find executable ${BUILDID})
    if [ -z "${BINARY_CACHE_PATH}" ] || [ ! -f "${BINARY_CACHE_PATH}" ]; then
        echo "Failed to get executable for BUILD-ID \"${BUILDID}\"" >&2
        continue
    fi

    # create link to binary (library or binary)
    log " create link ${BINARY_DIR}/${BINARY_NAME} -> ${BINARY_CACHE_PATH}"
    ln ${OPT_LINK} "${BINARY_CACHE_PATH}" ${BINARY_DIR}/${BINARY_NAME}

    # create soname links
    SN=$(readelf -a "${BINARY_CACHE_PATH}" 2>&1 | grep SONAME | sed 's/.*\[\(.*\)\].*/\1/g')
    log " sonames found: $SN"

    for SNX in ${SN}; do
        if ! [ -f ${BINARY_DIR}/${SNX} ]; then
           log " create soname soft link ${BINARY_DIR}/${SNX} -> ${BINARY_NAME}"
           ln -s ${BINARY_NAME} ${BINARY_DIR}/${SNX}
        else
           log " soname link ${BINARY_DIR}/${SNX} already exists, skipping"
        fi

        # gdb sometimes searches library without version suffixes
        # after .so so create them as well
        while [[ "${SNX}" =~ '.so.' ]]; do
            SNX=${SNX%.*}
            if ! [ -f ${BINARY_DIR}/${SNX} ]; then
                log " create soft link ${BINARY_DIR}/${SNX} -> ${BINARY_NAME}"
                ln -s ${BINARY_NAME} ${BINARY_DIR}/${SNX}
            else
                log " link ${BINARY_DIR}/${SNX} already exists, skipping"
            fi
        done
    done

    # TODO: should we prepare also links in ./usr/lib/debug for debuginfos?
    # it could be useful for environments with old gdb and new elfutils

    # TODO: backup / hardlink / reflog debuginfo and debugsources ?
    # would be nice to have them archived with project however debugsources
    # are downloaded on demand by gdb
done

log "Creating .ini file for gdb"
# prepare gdb.ini
cat > ${CORE_NAME}.ini <<END
set solib-absolute-prefix ${WORK_SUBDIR}
set solib-search-path ${WORK_SUBDIR}/:${WORK_SUBDIR}/lib64:${WORK_SUBDIR}/usr/lib64
set print max-symbolic-offset 1
set prompt #
set height 0
file ${WORK_DIR}/${CORE_BINARY}
core ${CORE}
END

echo
echo "gdb --command ${CORE_NAME}.ini"
echo
log "Done."

