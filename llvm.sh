#!/bin/bash -ue

# For quick building using the defaults, use `yes ''`
# $ yes '' | ./llvm.sh VERSION=3.7

PREFIX=~/Lokaal/llvm



################################################################################
# Main
#

main() {
    #
    # Configuration
    #

    VERSION=${VERSION:-trunk}

    TOOL_BUILD=${TOOL_BUILD:-cmake}
    TOOL_BUILD=${TOOL_BUILD,,}
    if [[ $TOOL_BUILD != "cmake" && $TOOL_BUILD != "autotools" ]]; then
        echo "Invalid value for build system" >&2
        exit 1
    fi

    BUILD_CLANG=${BUILD_CLANG:-0}

    BUILD_TARGETS=${BUILD_TARGETS:-host}

    BUILD_DEBUG=1

    cat <<EOD
Build settings:
 - Toolchain version (\$VERSION): $VERSION
 - Build system (\$TOOL_BUILD=cmake|autotools): $TOOL_BUILD

Component selection:
 - Build clang (\$BUILD_CLANG=1|0): $BUILD_CLANG
 - Targets to build (\$BUILD_TARGETS=foo,bar): $BUILD_TARGETS

EOD

    read -r -n1 -p "Press any key to continue... "


    #
    # Prepare
    #

    # Determine source URL
    URL_PREFIX="https://llvm.org/svn/llvm-project"
    if [[ $VERSION == "trunk" ]]; then
        URL_POSTFIX="/trunk"
    else
        URL_POSTFIX="branches/release_"$(echo $VERSION | tr -d '.')
    fi

    # Determine path prefix
    PATH_PREFIX="$PREFIX/llvm-$VERSION"


    #
    # Check-out
    #

    URL_LLVM="${URL_PREFIX}/llvm/${URL_POSTFIX}"
    SRC_LLVM="${PATH_PREFIX}.src"

    download_svn "LLVM sources ($VERSION)" "${URL_LLVM}" "${SRC_LLVM}"

    if [[ $BUILD_CLANG ]]; then
        URL_CLANG="${URL_PREFIX}/cfe/${URL_POSTFIX}"
        SRC_CLANG="${SRC_LLVM}/tools/clang"

        download_svn "Clang sources ($VERSION)" "${URL_CLANG}" "${SRC_CLANG}"
    fi


    #
    # Build
    #

    mkdir -p "${SRC_LLVM}/build"

    # Determine shared build flags
    GLOBAL_FLAGS=()
    if [[ $TOOL_BUILD == "cmake" ]]; then
        GLOBAL_FLAGS+=(-DBUILD_SHARED_LIBS=On)
        GLOBAL_FLAGS+=(-DLLVM_TARGETS_TO_BUILD=${BUILD_TARGETS/,/;})
        GLOBAL_FLAGS+=(-DLLVM_BUILD_DOCS=Off)
    elif [[ $TOOL_BUILD == "autotools" ]]; then
        GLOBAL_FLAGS+=(--enable-shared)
        GLOBAL_FLAGS+=(--enable-targets=${BUILD_TARGETS})
        GLOBAL_FLAGS+=(--disable-docs)
    fi

    # HACK: current clang (3.6) fail to build clang 3.4 or earlier
    if verlte "3.4" "$VERSION"; then
        CC=/usr/local/lib/ccache/bin/clang
        CXX=/usr/local/lib/ccache/bin/clang++
    else
        CC=/usr/lib/ccache/bin/cc
        CXX=/usr/lib/ccache/bin/c++
    fi
    if [[ $TOOL_BUILD == "cmake" ]]; then
        GLOBAL_FLAGS+=(-DCMAKE_C_COMPILER=$CC)
        GLOBAL_FLAGS+=(-DCMAKE_CXX_COMPILER=$CXX)
    elif [[ $TOOL_BUILD == "autotools" ]]; then
        export CC
        export CXX
    fi

    if [[ ${BUILD_DEBUG} ]]; then
        BUILD_DEBUG="${SRC_LLVM}/build/debug+assert"
        DEST_DEBUG="${PATH_PREFIX}.debug+assert"

        BUILDTYPE_FLAGS=()
        if [[ $TOOL_BUILD == "cmake" ]]; then
            BUILDTYPE_FLAGS+=(-DCMAKE_BUILD_TYPE=Debug)
        elif [[ $TOOL_BUILD == "autotools" ]]; then
            BUILDTYPE_FLAGS+=(--enable-assertions)
        fi

        build_llvm  "LLVM ($VERSION debug)" "$VERSION" \
                    "${SRC_LLVM}" "${BUILD_DEBUG}" "${DEST_DEBUG}" \
                    "${GLOBAL_FLAGS[@]}" "${BUILDTYPE_FLAGS[@]}"
    fi


    echo "All done!"
    exit 0
}



################################################################################
# Auxiliary
#

verlte() {
    [  "$1" = "`echo -e "$1\n$2" | sort -V | head -n1`" ]
}

verlt() {
    [ "$1" = "$2" ] && return 1 || verlte $1 $2
}

download_svn() {
    NAME=$1
    URL=$2
    DEST=$3

    if [[ -d "${DEST}" ]]; then
        echo "Warning: directory for $NAME already exists..."
        read -r -n1 -p "Continue without doing anything [c], update [U] or start from scratch [s]? "
        echo
        case $REPLY in
            [uU]|"")
                svn update "${DEST}"
                ;;
            [sS])
                rm -rf "${DEST}"
                ;;
            [cC])
                ;;
            *)
                echo Invalid response >&2
                exit 1
                ;;
        esac
    fi

    if [[ ! -d "${DEST}" ]]; then
        svn co "${URL}" "${DEST}"
    fi
}

build_llvm() {
    NAME=$1
    VERSION=$2
    SRCDIR=$3
    BUILDDIR=$4
    DESTDIR=$5
    shift 5

    if [[ -d "${BUILDDIR}" ]]; then
        echo "Warning: build directory for $NAME already exists..."
        read -r -n1 -p "Continue without doing anything [c], perform incremental build [I] or start from scratch [s]? "
        echo
        case $REPLY in
            [iI]|"")
                ;;
            [sS])
                rm -rf "${BUILDDIR}" "${DESTDIR}"
                ;;
            [cC])
                return
                ;;
            *)
                echo Invalid response >&2
                exit 1
                ;;
        esac
    fi

    if [[ -d "${DESTDIR}" ]]; then
        rm -rf "${DESTDIR}"
    fi

    # Configure
    if [[ ! -d "${BUILDDIR}" ]]; then
        LOCAL_FLAGS=("$@")
        if [[ $TOOL_BUILD == "cmake" ]]; then
            LOCAL_FLAGS+=(-GNinja)
            LOCAL_FLAGS+=(-DCMAKE_INSTALL_PREFIX="${DESTDIR}")
        elif [[ $TOOL_BUILD == "autotools" ]]; then
            LOCAL_FLAGS+=(--prefix="${DESTDIR}")
        fi

        mkdir "${BUILDDIR}"
        pushd "${BUILDDIR}"
        if [[ $TOOL_BUILD == "cmake" ]]; then
            cmake "${LOCAL_FLAGS[@]}" "${SRCDIR}"
        elif [[ $TOOL_BUILD == "autotools" ]]; then
            "${SRCDIR}"/configure "${LOCAL_FLAGS[@]}"
        fi
        popd
    fi

    # Compile and install
    if [[ $TOOL_BUILD == "cmake" ]]; then
        TOOL_MAKE="ninja"
    elif [[ $TOOL_BUILD == "autotools" ]]; then
        TOOL_MAKE="make"
    fi
    $TOOL_MAKE -C "${BUILDDIR}" -j$(($(nproc)+1)) install

    # Clean?
    read -r -n1 -p "Clean the build directory of $NAME [y/N]? "
    echo
    case $REPLY in
        [yY])
            $TOOL_MAKE -C "${BUILDDIR}" clean
            ;;
        [nN]|"")
            ;;
        *)
            echo Invalid response >&2
            exit 1
            ;;
    esac

}


main "$@"
