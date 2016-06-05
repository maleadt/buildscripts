#!/bin/bash -ue

# For quick building using the defaults, use `yes ''`
# $ yes '' | VERSION=3.7 ./llvm.sh

# TODO: conditionalize ccache
# TODO: if compiling using clang & ccache,
#       use -Qunused-arguments & -fcolor-diagnostics ?
#       http://petereisentraut.blogspot.be/2011/05/ccache-and-clang.html
#       http://peter.eisentraut.org/blog/2014/12/01/ccache-and-clang-part-3/
export CCACHE_CPP2=1

# TODO: proper usage()


################################################################################
# Main
#

error() {
    echo "Error: $1" >&2
    exit 1
}

warn() {
    echo "Warning: $1" >&2
}

# `which`-like command, looking for a command (possibly a relative one, and
# possibly a set of colon-separated candidates) in a haystack of directories
#
# USAGE: full_which COMMAND[:COLON:SEPARATED] [COLON:SEPARATED:DIRS]
full_which() {
    local NEEDLES=$1
    if [[ $# == 1 ]]; then
        local HAYSTACK=$PATH
    else
        local HAYSTACK=$2
    fi

    for DIR in ${HAYSTACK//:/ }; do
        [[ -n "$DIR" ]] || continue

        for NEEDLE in ${NEEDLES//:/ }; do
            if [[ -f "$DIR/$NEEDLE" ]]; then
                echo "$DIR/$NEEDLE"
                return 0
            fi
        done
    done

    echo "Could not find $NEEDLES in $HAYSTACK" >&2
    return 1
}

write_config() {
    local FILENAME=$1
    >$FILENAME

    for VAR in  PREFIX VERSION TOOL_BUILD \
                BUILD_SHLIB BUILD_ASSERTIONS BUILD_DEBUG \
                BUILD_CLANG BUILD_RT BUILD_LLDB BUILD_TARGETS \
                CC CXX; do
        eval local DEFINED=\${$VAR+x}
        if [[ -n $DEFINED ]]; then
            echo Checking $VAR
            local VALUE=${!VAR}
            echo "$VAR='${VALUE//\'/''}'" >> $FILENAME
        fi
    done
}

main() {
    # If passed a path, read build.conf
    if [[ $# == 1 ]]; then
        local CONFIG=$1
        [[ -f $CONFIG ]] || error "build configuration '$1' does not exist"
        source "$CONFIG"
    elif [[ $# != 0 ]]; then
        error "invalid command-line arguments"
    fi


    #
    # Configuration
    #

    PREFIX=${PREFIX:-~/Lokaal/llvm}

    VERSION=${VERSION:-trunk}

    TOOL_BUILD=${TOOL_BUILD:-cmake}
    TOOL_BUILD=${TOOL_BUILD,,}
    if [[ $TOOL_BUILD != "cmake" && $TOOL_BUILD != "autotools" ]]; then
        error "invalid build system ${TOOL_BUILD}"
    fi

    BUILD_SHLIB=${BUILD_SHLIB:-1}

    BUILD_ASSERTIONS=${BUILD_ASSERTIONS:-1}
    BUILD_DEBUG=${BUILD_DEBUG:-0}

    BUILD_CLANG=${BUILD_CLANG:-0}
    BUILD_RT=${BUILD_RT:-0}
    BUILD_LLDB=${BUILD_LLDB:-0}

    if verlte "3.0" "$VERSION"; then
        BUILD_TARGET_HOST="X86"
    else
        BUILD_TARGET_HOST="host"
    fi
    BUILD_TARGETS=${BUILD_TARGETS:-${BUILD_TARGET_HOST}}

    # Case convert the build targets
    # TODO: not sure if this is correct
    if [[ $TOOL_BUILD == "cmake" ]]; then
        BUILD_TARGETS=${BUILD_TARGETS^^}
    elif [[ $TOOL_BUILD == "autotools" ]]; then
        BUILD_TARGETS=${BUILD_TARGETS,,}
    fi

    cat <<EOD
Build settings:
 - Installation prefix (\$PREFIX): $PREFIX
 - Toolchain version (\$VERSION): $VERSION
 - Build system (\$TOOL_BUILD=cmake|autotools): $TOOL_BUILD
 - Shared libraries (\$BUILD_SHLIB=1|0): $BUILD_SHLIB
 - Assertions (\$BUILD_ASSERTIONS=1|0): $BUILD_ASSERTIONS
 - Debug info (\$BUILD_DEBUG=1|0): $BUILD_DEBUG
EOD
    [[ -n ${CC+x} ]] && echo " - C compiler: $CC"
    [[ -n ${CXX+x} ]] && echo " - C++ compiler: $CXX"

    cat <<EOD

Component selection:
 - Build clang (\$BUILD_CLANG=1|0): $BUILD_CLANG
 - Build compiler-rt (\$BUILD_RT=1|0): $BUILD_RT
 - Build LLDB (\$BUILD_LLDB=1|0): $BUILD_LLDB
 - Targets to build (\$BUILD_TARGETS=foo,bar): $BUILD_TARGETS

EOD

    read -r -n1 -p "Press any key to continue... "
    echo



    #
    # Prepare
    #

    [[ -d "$PREFIX" ]] || error "installation prefix $PREFIX does not exist..."

    # Determine path prefix
    local PATH_PREFIX="$PREFIX/llvm-$VERSION"

    [[ $BUILD_DEBUG = 1 ]] && TAG="debug" || TAG="release"
    [[ $BUILD_ASSERTIONS = 1 ]] && TAG+="+asserts"

    local DESTDIR="${PATH_PREFIX}.$TAG"

    write_config $DESTDIR.conf.new
    if [[ -e $DESTDIR.conf ]]; then
        if ! diff $DESTDIR.conf.new $DESTDIR.conf >/dev/null; then
            warn "pre-existing build in $DESTDIR has been configured with different options:"
            diff $DESTDIR.conf.new $DESTDIR.conf || true
            echo
            read -r -n1 -p "Press any key to continue anyway... "
        fi
    fi
    mv $DESTDIR.conf.new $DESTDIR.conf


    #
    # Download
    #

    # Determine source URL
    local URL_PREFIX="https://llvm.org/svn/llvm-project"
    if [[ $VERSION == "trunk" ]]; then
        local URL_POSTFIX="/trunk"
    else
        local URL_POSTFIX="branches/release_"$(echo $VERSION | tr -d '.')
    fi

    local URL_LLVM="${URL_PREFIX}/llvm/${URL_POSTFIX}"
    local SRC_LLVM="${PATH_PREFIX}.src"

    download_svn "LLVM sources ($VERSION)" "${URL_LLVM}" "${SRC_LLVM}"

    local SRC_CLANG="${SRC_LLVM}/tools/clang"
    if [[ $BUILD_CLANG == 1 ]]; then
        local URL_CLANG="${URL_PREFIX}/cfe/${URL_POSTFIX}"

        download_svn "Clang sources ($VERSION)" "${URL_CLANG}" "${SRC_CLANG}"
    fi

    local SRC_RT="${SRC_LLVM}/projects/compiler-rt"
    if [[ $BUILD_RT == 1 ]]; then
        local URL_RT="${URL_PREFIX}/compiler-rt/${URL_POSTFIX}"

        download_svn "Runtime sources ($VERSION)" "${URL_RT}" "${SRC_RT}"
    fi

    local SRC_LLDB="${SRC_LLVM}/tools/lldb"
    if [[ $BUILD_LLDB == 1 ]]; then
        local URL_LLDB="${URL_PREFIX}/lldb/${URL_POSTFIX}"

        download_svn "LLDB sources ($VERSION)" "${URL_LLDB}" "${SRC_LLDB}"
    fi


    #
    # Build
    #

    local FLAGS=()

    # Fix up references to python if our system python is python3
    if [[ $(readlink $(which python)) =~ python3 ]]; then
        # TODO: is modifying scripts really necessary?
        ag -l '#!/usr/bin.*python\b' "${SRC_LLVM}" \
            | xargs perl -p -i -e 's{(#!/usr/bin.*)python\b}{$1python2}'
        FLAGS+=(-DPYTHON_EXECUTABLE=$(which python2))
    fi

    # Debug symbols
    if [[ $BUILD_DEBUG == 1 ]]; then
        if [[ $TOOL_BUILD == "cmake" ]]; then
            FLAGS+=(-DCMAKE_BUILD_TYPE=Debug)
        elif [[ $TOOL_BUILD == "autotools" ]]; then
            FLAGS+=(--disable-optimized --enable-debug-symbols --enable-keep-symbols)
        fi
    else
        if [[ $TOOL_BUILD == "cmake" ]]; then
            FLAGS+=(-DCMAKE_BUILD_TYPE=Release)
        elif [[ $TOOL_BUILD == "autotools" ]]; then
            FLAGS+=(--enable-optimized)
        fi
    fi

    # Assertions
    if [[ $BUILD_ASSERTIONS == 1 ]]; then
        if [[ $TOOL_BUILD == "cmake" ]]; then
            FLAGS+=(-DLLVM_ENABLE_ASSERTIONS=True)
        elif [[ $TOOL_BUILD == "autotools" ]]; then
            FLAGS+=(--enable-assertions)
        fi
    else
        if [[ $TOOL_BUILD == "cmake" ]]; then
            FLAGS+=(-DLLVM_ENABLE_ASSERTIONS=False)
        elif [[ $TOOL_BUILD == "autotools" ]]; then
            FLAGS+=(--disable-assertions)
        fi
    fi

    # Determine shared build flags
    if [[ $BUILD_SHLIB == 1 ]]; then
        if [[ $TOOL_BUILD == "cmake" ]]; then
            FLAGS+=(-DBUILD_SHARED_LIBS=On)
        elif [[ $TOOL_BUILD == "autotools" ]]; then
            FLAGS+=(--enable-shared)
        fi
    fi

    # Other
    if [[ $TOOL_BUILD == "cmake" ]]; then
        FLAGS+=(-DLLVM_TARGETS_TO_BUILD=${BUILD_TARGETS/,/;})
        FLAGS+=(-DLLVM_BUILD_DOCS=Off)
    elif [[ $TOOL_BUILD == "autotools" ]]; then
        FLAGS+=(--enable-targets=${BUILD_TARGETS})
        FLAGS+=(--disable-docs)
    fi

    LIBDIRS=$(ld --verbose | grep SEARCH_DIR \
            | perl -pe 's/SEARCH_DIR\("(.+?)"\)/\1/g' \
            | tr -s ' ;' \\012 | sed 's/^=//' | paste -sd ":" -)
    if [[ -z ${CC+x} ]]; then
        # HACK: current clang (3.6) fails to build clang 3.4 or earlier
        if verlt "3.4" "$VERSION"; then
            CC=$(full_which  "ccache/clang:ccache/bin/clang"     "$PATH:$LIBDIRS")
        else
            CC=$(full_which  "ccache/cc:ccache/bin/cc"   "$PATH:$LIBDIRS")
        fi
    fi
    if [[ -z ${CXX+x} ]]; then
        # HACK: current clang (3.6) fails to build clang 3.4 or earlier
        if verlt "3.4" "$VERSION"; then
            CXX=$(full_which "ccache/clang++:ccache/bin/clang++" "$PATH:$LIBDIRS")
        else
            CXX=$(full_which "ccache/c++:ccache/bin/c++" "$PATH:$LIBDIRS")
        fi
    fi
    if [[ $TOOL_BUILD == "cmake" ]]; then
        FLAGS+=(-DCMAKE_C_COMPILER=$CC)
        FLAGS+=(-DCMAKE_CXX_COMPILER=$CXX)
    elif [[ $TOOL_BUILD == "autotools" ]]; then
        export CC
        export CXX
    fi

    # Forcibly disable targets we don't want if their sources are present
    if [[ $BUILD_CLANG == 0 && -d $SRC_CLANG ]]; then
        if [[ $TOOL_BUILD == "cmake" ]]; then
            FLAGS+=(-DLLVM_EXTERNAL_CLANG_BUILD=Off)
        else
            error "not implemented"
        fi
    fi
    if [[ $BUILD_RT == 0 && -d $SRC_RT ]]; then
        if [[ $TOOL_BUILD == "cmake" ]]; then
            FLAGS+=(-DLLVM_EXTERNAL_COMPILER_RT_BUILD=Off)
        else
            error "not implemented"
        fi
    fi
    if [[ $BUILD_LLDB == 0 && -d $SRC_LLDB ]]; then
        if [[ $TOOL_BUILD == "cmake" ]]; then
            FLAGS+=(-DLLVM_EXTERNAL_LLDB_BUILD=Off)
        else
            error "not implemented"
        fi
    fi

    mkdir -p "${SRC_LLVM}/build"
    local BUILDDIR="${SRC_LLVM}/build/$TAG"

    build_llvm  "LLVM ($VERSION $TAG)" "$VERSION" "${SRC_LLVM}" \
                "${BUILDDIR}" "${DESTDIR}" "${FLAGS[@]}"

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
    local NAME=$1
    local URL=$2
    local DESTDIR=$3

    if [[ -d "${DESTDIR}" ]]; then
        echo "Warning: directory for $NAME already exists..."
        read -r -n1 -p "Continue without doing anything [c], update [U] or start from scratch [s]? "
        echo
        case $REPLY in
            [uU]|"")
                svn update "${DESTDIR}"
                ;;
            [sS])
                rm -rf "${DESTDIR}"
                ;;
            [cC])
                ;;
            *)
                error "invalid response"
                ;;
        esac
    fi

    if [[ ! -d "${DESTDIR}" ]]; then
        svn co "${URL}" "${DESTDIR}"
    fi
}

build_llvm() {
    local NAME=$1
    local VERSION=$2
    local SRCDIR=$3
    local BUILDDIR=$4
    local DESTDIR=$5
    shift 5

    if [[ -d "${BUILDDIR}" ]]; then
        warn "build directory for $NAME already exists..."
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
                error "invalid response"
                ;;
        esac
    fi

    if [[ -d "${DESTDIR}" ]]; then
        rm -rf "${DESTDIR}"
    fi

    # Configure
    if [[ ! -d "${BUILDDIR}" ]]; then
        local FLAGS=("$@")
        if [[ $TOOL_BUILD == "cmake" ]]; then
            FLAGS+=(-GNinja)
            FLAGS+=(-DCMAKE_INSTALL_PREFIX="${DESTDIR}")
        elif [[ $TOOL_BUILD == "autotools" ]]; then
            FLAGS+=(--prefix="${DESTDIR}")
        fi

        mkdir "${BUILDDIR}"
        pushd "${BUILDDIR}"
        if [[ $TOOL_BUILD == "cmake" ]]; then
            (set -x; cmake "${FLAGS[@]}" "${SRCDIR}")
        elif [[ $TOOL_BUILD == "autotools" ]]; then
            (set -x; "${SRCDIR}"/configure "${FLAGS[@]}")
        fi
        popd
    fi

    # Compile and install
    local TOOL_FLAGS=(-C "${BUILDDIR}")
    if [[ $TOOL_BUILD == "cmake" ]]; then
        TOOL_MAKE="ninja"
    elif [[ $TOOL_BUILD == "autotools" ]]; then
        TOOL_MAKE="make"
        TOOL_FLAGS+=(-j$(($(nproc)+1)))
    fi
    $TOOL_MAKE  "${TOOL_FLAGS[@]}" install

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
            error "invalid response"
            ;;
    esac

}


main "$@"
