#!/usr/bin/bash

ulimit -s unlimited
#########################
TimeLimit=1
SPJ="./"
RE=()
WA=()
TLE=()
CPP="4747732939492939492394948384923949294"
#########################

func() {
    echo "Usage:"
    echo "./judge.sh [-t TimeLimit] [-c Checker] [-s Source]"
    echo "Description:"
    echo "TimeLimit,unit second."
    echo "Checker,the cpp or binary file of special judge."
    echo "Source,the cpp you want to run."
    exit -1
}
 
while getopts 'ht:c:s:' OPT; do
    case $OPT in
        t) TimeLimit="$OPTARG";;
        c) SPJ="$OPTARG";;
        s) CPP="$OPTARG";;
        h) func;;
        ?) func;;
    esac
done
#########################
a=$(ls *.cpp)
for in in $a
do
    p=${in:0:$(expr ${#in} - 4)}
    if [ p != $SPJ ];then
        cpp=$in
    fi
done
if [ ! -e $CPP ];then
    echo "not find source."
    exit -1
fi
if [ ! -e $SPJ ];then
    if [ -e "$SPJ.cpp" ];then
        g++ "$SPJ.cpp" -o $SPJ -std=c++14 -Wall -O2 2>/dev/null
        if [ $? -ne 0 ];then
            echo "$(tput setaf 11)special judge CE."
            exit -1
        fi
    else
        echo "not find special judge."
        exit -1
    fi
fi
if [ $CPP != "4747732939492939492394948384923949294" ];then
    cpp=$CPP
fi
tmp=${cpp:0:$(expr ${#cpp} - 4)}
g++ $cpp -o $tmp -std=c++14 -Wall -O2 2>/dev/null
if [ $? -ne 0 ];then
    echo  "$(tput setaf 11)CE"
    exit -1
fi
for in in $(ls *.in)
do
    out=$(echo $in | sed "s/.in$/.out/")
    ans=$(echo $in | sed "s/.in$/.ans/")
    if [ ! -e $ans ]
    then
        if [ ! -e $out ];then
            cp $in $ans
        else
            ans1=$(echo $in | sed "s/.in$/.out/")
            mv $ans1 $ans
        fi
    fi
    Time=$( TIMEFORMAT="%R"; time ( timeout $TimeLimit ./$tmp <$in > $out ) 2>&1 )
    ret=$?
    echo "${in:0:$(expr ${#in} - 3)}:"
    if [ $ret -eq 124 ];then
        echo -n "$(tput sgr0)TLE"
        TLE=("${TLE[@]}" ${in:0:$(expr ${#in} - 3)})
    elif [ $ret -ne 0 ];then
        echo -n "$(tput setaf 5)RE"
        RE=("${RE[@]}" ${in:0:$(expr ${#in} - 3)})
    else
        if [ $SPJ != "./" ];then
            "./$SPJ" $in $out $ans
            if [ $? -ne 0 ]
            then
                WA=("${WA[@]}" ${in:0:$(expr ${#in} - 3)})
            fi
        else
            diff -ZB $ans $out > /dev/null
            if [ $? -ne 0 ];then
                echo -n "$(tput setaf 1)WA"
                WA=("${WA[@]}" ${in:0:$(expr ${#in} - 3)})
            else
                echo -n "$(tput setaf 2)AC"
            fi
        fi
    fi
    echo $(tput sgr0)
    echo "Spend Time: $Time s"
    echo
done
echo "$(tput setaf 5)RE on: ${RE[@]}"
echo "$(tput setaf 1)WA on: ${WA[@]}"
echo "$(tput sgr0)TLE on: ${TLE[@]}"
