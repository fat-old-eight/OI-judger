#!/usr/bin/bash

ulimit -s unlimited
#########################
op="-std=c++14 -O2"
gdbop="-std=c++14 -Og -g"
spjop="-std=c++14 -O2"
dir=".judgerdir"
#########################
TimeLimit=1
SPJ="./"
RE=()
WA=()
TLE=()
CPP="4747732939492939492394948384923949294"
gdb=0
fre=0
rmdir=1
ffile=""
#########################

func() {
    echo "Usage:"
    echo "./judge.sh [-t TimeLimit] [-c Checker] [-s Source] [-g] [-f Freopen file]"
    echo "Description:"
    echo "TimeLimit, unit second."
    echo "Checker, the cpp or binary file of special judge."
    echo "Source, the cpp you want to run."
    echo "-g, generate debugging information at compile time."
    echo 'Freopen file, the name of in/out/ans name(if ues freopen).'
    exit 0
}

while getopts 'ht:c:s:gf:' OPT; do
    case $OPT in
        t) TimeLimit="$OPTARG";;
        c) SPJ="$OPTARG";;
        s) CPP="$OPTARG";;
        g) gdb=1;;
        f) fre=1;ffile="$OPTARG";;
        h) func;;
        ?) func;;
    esac
done
########function#########
check(){
    if [[ $ret == 124 ]];then
        echo -n "$(tput sgr0)TLE"
        TLE=("${TLE[@]}" $4)
    elif [[ $ret != 0 ]];then
        echo -n "$(tput setaf 5)RE"
        RE=("${RE[@]}" $4)
    else
        if [ $SPJ != "./" ];then
            "./$SPJ" $1 $2 $3
            if [[ $? != 0 ]];then
                WA=("${WA[@]}" $4)
            fi
        else
            diff -ZB $2 $3 > /dev/null
            if [[ $? != 0 ]];then
                echo -n "$(tput setaf 1)WA"
                WA=("${WA[@]}" $4)
            else
                echo -n "$(tput setaf 2)AC"
            fi
        fi
    fi
    echo $(tput sgr0)
    echo "Spend Time: $Time s"
    echo
}
#########################
a=$(ls *.cpp 2>/dev/null)
cnt=0
for in in $a
do
    p=${in:0:$(expr ${#in} - 4)}
    if [ p != $SPJ ];then
        cpp=$in
        cnt=$(expr $cnt + 1);
    fi
done
if [[ $cnt -ge 2 && $CPP == "4747732939492939492394948384923949294" ]];then
    echo "too more cpp file here, please use -s."
    exit -1
fi
if [[ $cnt == 0 ]];then
    echo "no cpp file here."
    exit -1
fi
if [[ ! -e $CPP && $CPP != "4747732939492939492394948384923949294" ]];then
    echo "not find source."
    exit -1
fi
if [ ! -e $SPJ ];then
    if [ -e "$SPJ.cpp" ];then
        g++ "$SPJ.cpp" -o $SPJ $spjop 2>/dev/null
        if [[ $? != 0 ]];then
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
if [[ $gdb != 1 ]];then
    g++ $cpp -o $tmp $op 2>/dev/null
else
    g++ $cpp -o $tmp $gdbop 2>/dev/null
fi
if [[ $? != 0 ]];then
    echo  "$(tput setaf 11)CE"
    exit -1
fi
fl=$(ls *.in 2>/dev/null)
cnt=0
for in in $fl
do
    cnt=$(expr $cnt + 1);
done
if [[ $cnt == 0 ]];then
    echo "no in/out/ans file here."
    exit -1
fi
i=1
if [[ $fre == 1 ]];then
    if [[ -d $dir ]];then
        rmdir=0
    else
        mkdir $dir
    fi
    cp $tmp "$dir/$tmp"
fi
for in in $fl
do
    out=$(echo $in | sed "s/.in$/.out/")
    ans=$(echo $in | sed "s/.in$/.ans/")
    name=${in:0:$(expr ${#in} - 3)}
    echo "$name[$i/$cnt]:"
    i=$(expr $i + 1)
    if [ ! -e $ans ]
    then
        if [ ! -e $out ];then
            if [ $SPJ != './' ];then
                cp $in $ans
            else
                echo "Skip"
                echo "not find out/ans file."
                echo
                continue
            fi
        else
            ans1=$(echo $in | sed "s/.in$/.out/")
            mv $ans1 $ans
        fi
    fi
    if [[ $fre == 1 ]];then
        cp $in "./$dir/$ffile.in"
        cp $ans "./$dir/$ffile.ans"
        cd $dir
        Time=$( TIMEFORMAT="%R"; time ( timeout $TimeLimit ./$tmp 2>/dev/null) 2>&1 )
        ret=$?
        check "$ffile.in" "$ffile.out" "$ffile.ans" $name
        cd ..
        continue
    fi
    Time=$( TIMEFORMAT="%R"; time ( timeout $TimeLimit ./$tmp <$in >$out 2>/dev/null) 2>&1 )
    ret=$?
    check $in $out $ans $name
done
if [[ $fre -eq 1 && $rmdir -eq 1 ]];then
    rm "./$dir/$ffile.in"
    rm "./$dir/$ffile.out"
    rm "./$dir/$ffile.ans"
    if [ $rmdir -eq 1 ];then
        rm $dir -r
    fi
fi
echo "$(tput setaf 5)RE on: ${RE[@]}"
echo "$(tput setaf 1)WA on: ${WA[@]}"
echo "$(tput sgr0)TLE on: ${TLE[@]}"