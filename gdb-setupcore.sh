#!/bin/bash
# jcejka@suse.de


function usage()
{
    echo
    echo "$0 <core file>"
    echo "Prepare debug resources for gdb using debuginfod"
    echo "Create directory with executable and all libraries requested by GDB 10.1 to open core seamlessly."
    echo
}

if [ $# -ne 1 ] || [ "$1" == "-h" ] || [ "$1" == "--help" ] || [ "$1" == "--usage" ]; then
    usage
    exit
fi

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
    echo "Failed to determine executable binary's name." >&2
    echo "Please edit .ini file and set proper value to \"file\" option." >&2
fi

# get BUILD_IDs from core, get binaries using debuginfod and create links
# 0x3ffacd00000+0x26000 d00a54489090b1a3e7770c7c0c5e176ac43a2f99@0x3ffacd001d8 . . /lib64/ld-2.22.so

eu-unstrip -n --core ${CORE} | while read ADDR ID FILE DBG BINARY; do
    BUILDID=${ID%%@*}

    BINARY_DIR=${WORK_DIR}/$(dirname ${BINARY})
    BINARY_NAME=$(basename ${BINARY})

    mkdir -p ${BINARY_DIR}
    BINARY_CACHE_PATH=$(debuginfod-find executable ${BUILDID})
    if ! [ -f "${BINARY_CACHE_PATH}" ]; then
        echo "Failed to get executable for BUILD-ID \"${BUILDID}\"" >&2
        continue
    fi

    # create hardlink to binary (library or binary)
    ln "${BINARY_CACHE_PATH}" ${BINARY_DIR}/${BINARY_NAME}

    # create soname links
    SN=$(readelf -a "${BINARY_CACHE_PATH}" 2>&1 | grep SONAME | sed 's/.*\[\(.*\)\].*/\1/g')

    for SNX in ${SN}; do
        if ! [ -f ${BINARY_DIR}/${SNX} ]; then
           # echo " soname link ${BINARY_DIR}/${SNX} -> ${BINARY_NAME}"
           ln -s ${BINARY_NAME} ${BINARY_DIR}/${SNX}
        fi

        # gdb sometimes searches library without version suffixes
        # after .so so create them as well
        while [[ "${SNX}" =~ '.so.' ]]; do
            SNX=${SNX%.*}
            if ! [ -f ${BINARY_DIR}/${SNX} ]; then
                ln -s ${BINARY_NAME} ${BINARY_DIR}/${SNX}
            fi
        done
    done

    # TODO: should we prepare also links in ./usr/lib/debug for debuginfos?
    # it could be useful for environments with old gdb and new elfutils

    # TODO: backup / hardlink / reflog debuginfo and debugsources ?
    # would be nice to have them archived with project however debugsources
    # are downloaded on demand by gdb
done

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

echo "Done."
echo
echo "gdb --command ${CORE_NAME}.ini"
echo

