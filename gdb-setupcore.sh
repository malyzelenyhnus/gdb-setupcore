#!/bin/bash
# jcejka@suse.de

if [ -n "${DEBUGINFOD_CACHE_PATH}" ]; then
    CACHE_DIR=${DEBUGINFOD_CACHE_PATH}
elif [ -n "${XDG_CACHE_HOME}" ]; then
    CACHE_DIR=$XDG_CACHE_HOME/debuginfod_client
else
    CACHE_DIR=$HOME/.cache/debuginfod_client
fi


function usage()
{
    echo "$0 <core file>"
    echo "Prepare debug resources for gdb using debuginfod"
    echo "Create directory with all debuginfos and binaries requested by GDB 10.1 to open core seamlessly."
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
WORK_DIR=$(pwd)/${CORE_SUBDIR}

#0x3ffacd00000+0x26000 d00a54489090b1a3e7770c7c0c5e176ac43a2f99@0x3ffacd001d8 . . /lib64/ld-2.22.so
eu-unstrip -n --core ${CORE} | while read ADDR ID FILE DBG BINARY; do
    BUILDID=${ID%%@*}

    BINARY_DIR=${WORK_DIR}/$(dirname ${BINARY})
    BINARY_NAME=$(basename ${BINARY})

    mkdir -p ${BINARY_DIR}
    debuginfod-find executable ${BUILDID}
    # create hardlink to executable (library or binary)
    echo " hardlink ${BINARY_DIR}/${BINARY_NAME} -> ~/.cache/debuginfod_client/${BUILDID}/executable"
    ln ~/.cache/debuginfod_client/${BUILDID}/executable ${BINARY_DIR}/${BINARY_NAME}

    # create soname links
    SN=$(readelf -a ${BINARY_DIR}/${BINARY_NAME} 2>&1 | grep SONAME | sed 's/.*\[\(.*\)\].*/\1/g')

    for SNX in ${SN}; do
	echo " soname link ${BINARY_DIR}/${SNX} -> ${BINARY_NAME}"
	ln -s ${BINARY_NAME} ${BINARY_DIR}/${SNX}
    done

    # TODO: should we prepare also links in ./usr/lib/debug for debuginfos?
    # it could be useful for environments with old gdb and new elfutils

    # TODO: backup / hardlink / reflog debuginfo and debugsources ?
    # would be nice to have them archived with project however debugsources
    # are downloaded on demand by gdb
done

# prepare gdb.ini
# TODO: determine the name of executable binary!
cat > ${CORE_NAME}.ini <<END
set solib-absolute-prefix ${WORK_SUBDIR}
set solib-search-path ${WORK_SUBDIR}/:${WORK_SUBDIR}/lib64:${WORK_SUBDIR}/usr/lib64
set print max-symbolic-offset 1
set prompt #
set height 0
core ${CORE}
END

echo "Done."
echo
echo "gdb --command ${CORE_NAME}.ini"
echo

