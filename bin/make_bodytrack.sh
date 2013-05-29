#!/usr/bin/env bash

if (( $# != 1 ))
then
    printf "USAGE: $0 <path to parsec>"
    exit 1
fi

cd $1

if (( $? == 1 ))
then
    printf "Bad path to parsec given: $1 ... exiting"
    exit 1
fi

cd pkgs/apps/bodytrack/src/TrackingBenchmark

if (( $? == 1 ))
then
    printf "Something is wrong with the directory structure in parsec or you gave me the wrong path to parsec. Path given: $1"
    exit 1
fi

# we rename this file so that it won't be included in the concatenated src.
mv TrackingModelTBB.cpp TrackingModelTBB.bkup
cat *.c* > bodytrack.cpp
mv TrackingModelTBB.bkup TrackingModelTBB.cpp

# now we undef USE_TBB to controll the includes and comment out duplicate template defs.
sed -i '1i#undef USE_TBB' bodytrack.cpp
sed -i '1459i/*' bodytrack.cpp
sed -i '1466a*/' bodytrack.cpp
sed -i '1771i/*' bodytrack.cpp
sed -i '1778a*/' bodytrack.cpp

g++ -DHAVE_CONFIG_H -I. -I../FlexImageLib -I.. -O3 -g -funroll-loops -fprefetch-loop-arrays -fpermissive -fno-exceptions  -static-libgcc -Wl,--hash-style=both,--as-needed -DPARSEC_VERSION=3.0-beta-20120904 -fexceptions  -MT FlexImage.lo -MD -MP -MF ../../obj/amd64-linux.gcc/FlexImageLib/.deps/FlexImage.Plo -I ../../obj/amd64-linux.gcc/ -L ../../obj/amd64-linux.gcc/FlexImageLib/.libs/ -I ../../../../libs/tbblib/src/include/ -L../../../../libs/tbblib/src/include/ -L ../../obj/amd64-linux.gcc/TrackingBenchmark/threads/.libs/ -S bodytrack.cpp -o bodytrack.s -lflex -lpthread -lthreads && echo $(pwd)/bodytrack.s
