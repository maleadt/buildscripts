#!/bin/bash
set -eu

# This script downloads KLEE and all of its dependencies, and then builds
# everything.
#
# Everything is downloaded into subdirectories of the current directory.
# 
# By default, a dependency (or KLEE) is not rebuilt if its subdirectory already
# existed in the current directory.
# Can force rebuilding everything with REBUILD_ALL=1, and of components with
# REBUILD_<COMPONENT>=1 (see below for names)
#
# If you rebuild a component, all dependencies are automatically rebuilt too.


LLVMVER=3.4

clanghelp() {
  echo This script requires LLVM $LLVMVER to be in the PATH, in particular the bin directory under src/build.
  echo Example: ~Lokaal/llvm/llvm-${LLVMVER}.src/build/debug+asserts/Debug+Asserts/bin
  exit 1
}

if [ $# -ne 1 ]; then
  echo Usage: $0 builddir
  exit 1
fi

BASEDIR=`realpath "$1"`
INSTALL_PREFIX="$BASEDIR/kleebuild"
mkdir -p "$INSTALL_PREFIX"

cd "$BASEDIR"

if [ ${REBUILD_ALL:=0} != 0 ]; then
  REBUILD_MINISAT=1
  REBUILD_CRYPTOMINISAT=1
  REBUILD_STP=1
  REBUILD_UCLIBC=1
  REBUILD_KLEE=1
fi

if [ ${REBUILD_MINISAT:=0} != 0 ]; then
  REBUILD_MINISAT=1
  REBUILD_KLEE=1
fi

if [ ${REBUILD_CRYPTOMINISAT:=0} != 0 ]; then
  REBUILD_CRYPTOMINISAT=1
  REBUILD_STP=1
  REBUILD_KLEE=1
fi

if [ ${REBUILD_STP:=0} != 0 ]; then
  REBUILD_STP=1
  REBUILD_KLEE=1
fi

if [ ${REBUILD_UCLIBC:=0} != 0 ]; then
  REBUILD_UCLIBC=1
  REBUILD_KLEE=1
fi

if [ ${REBUILD_KLEE:=0} != 0 ]; then
  REBUILD_KLEE=1
fi

if [ `clang --version|grep -q "^clang version $LLVMVER"` ]; then
  clanghelp
fi

clang=`which clang`
# ../bin
llvmtopdir=`dirname "$clang"`
# ../Debug+Asserts
llvmtopdir=`dirname "$llvmtopdir"`
# ../debug+asserts
llvmobjdir=`dirname "$llvmtopdir"`
# ../build
llvmtopdir=`dirname "$llvmobjdir"`
# ../llvm-3.4.src
llvmtopdir=`dirname "$llvmtopdir"`
if [ ! -f "$llvmtopdir"/LLVMBuild.txt  ]; then
  clanghelp
fi

mkdir -p "${INSTALL_PREFIX}"

if [ ! -d minisat ]; then
  git clone https://github.com/stp/minisat.git
  cd minisat
  git checkout -b kleerev 3db58943b6ffe855d3b8c9a959300d9a148ab554
  cd ..
  REBUILD_MINISAT=1
fi

if [ $REBUILD_MINISAT -eq 1 ]; then
  rm -rf minisat/build
  mkdir minisat/build
  cd minisat/build
  cmake -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" ..
  make -j $(nproc)
  make install
  cd ../..
fi

if [ ! -d cryptominisat ]; then
  git clone https://github.com/msoos/cryptominisat
  cd cryptominisat
  git checkout -b kleerev da41ca6b6d1b5a33856c1f3d7b95c3e4b145968f
  cd ..
  REBUILD_CRYPTOMINISAT=1
fi

if [ $REBUILD_CRYPTOMINISAT -eq 1 ]; then
  rm -rf cryptominisat/build/
  mkdir cryptominisat/build/
  cd cryptominisat/build/
  cmake -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" ..
  make -j $(nproc)
  make install
  cd ../..
fi

if [ ! -d stp ]; then
  git clone https://github.com/stp/stp.git
  cd stp
  git checkout -b kleerev 3785148da15919de445e476a6f20b06c881cf50c
  cd ..
  REBUILD_STP=1
fi

if [ $REBUILD_STP -eq 1 ]; then
  rm -rf stp/build
  mkdir stp/build
  cd stp/build
  cmake -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=TRUE -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" -Dcryptominisat4_DIR="${INSTALL_PREFIX}"/lib/cmake/cryptominisat4 -DCMAKE_LIBRARY_PATH="${INSTALL_PREFIX}"/lib -DPYTHON_LIB_INSTALL_DIR=$HOME/lib/python2.7/site-packages ..
  make -j $(nproc)
  make install
  cd ../..
fi


if [ ! -d klee-uclibc ]; then
  git clone https://github.com/klee/klee-uclibc.git
  cd klee-uclibc
  git checkout -b kleerev a8af87cdf58c27c57c654e864b3e6b76f7ed799b
  cd ..
  REBUILD_UCLIBC=1
fi

if [ $REBUILD_UCLIBC -eq 1 ]; then
  cd klee-uclibc
  if [[ -f Makefile.klee ]]; then
    make clean
  fi
  ./configure --make-llvm-lib
  make
  cd .. 
fi

if [ ! -d klee ]; then
  git clone https://github.com/klee/klee.git
  cd klee
  git checkout -b kleerev 58f947302c9807b7f6bea2fcb2a7bb325f8dd1b2
  cd ..
  REBUILD_KLEE=1
fi

if [ $REBUILD_KLEE -eq 1 ]; then
  cd klee
  if [ -f Makefile.config ]; then
    make clean
  fi
  ./configure --with-stp="${INSTALL_PREFIX}" --prefix="${INSTALL_PREFIX}" --with-llvmsrc="$llvmtopdir" --with-llvmobj="$llvmobjdir" --with-llvmcc="$clang" --with-llvmcxx="$clang" --with-uclibc=$PWD/../klee-uclibc --enable-posix-runtime
  make -j $(nproc)
  make install
  cd ../..
fi

echo
echo
echo KLEE has been installed in $INSTALL_PREFIX !
