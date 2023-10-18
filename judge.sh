#!/usr/bin/bash

ulimit -s unlimited
#########################
op="-std=c++14 -O2"
gdbop="-std=c++14 -Og -g"
spjop="-std=c++14 -O2"
#########################
TimeLimit=1
SPJ="./"
RE=()
WA=()
TLE=()
CPP="4747732939492939492394948384923949294"
gdb=0
fre=0
ffile=""
dir="/tmp"
path=$(pwd)
ba="$(mktemp)"
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
        TLE=("${TLE[@]}" "$4")
    elif [[ $ret != 0 ]];then
        echo -n "$(tput setaf 5)RE"
        RE=("${RE[@]}" "$4")
    else
        if [ "$SPJ" != "./" ];then
            if ! "./$SPJ" "$1" "$2" "$3" ;then
                WA=("${WA[@]}" "$4")
            fi
        else
            if ! diff -ZB "$2" "$3" > /dev/null ;then
                echo -n "$(tput setaf 1)WA"
                WA=("${WA[@]}" "$4")
            else
                echo -n "$(tput setaf 2)AC"
            fi
        fi
    fi
    echo 
    echo "$(tput sgr0)Spend Time: $Time s"
    echo
}
Exit(){
    if [[ -f "$dir/$tmp"  ]];then
        rm "$dir/$tmp" -f
    fi
    rm "$ba" -f
    if [[ $fre -eq 1 && -e "$dir/$ffile.in" ]];then
        rm "$dir/$ffile.in" -f
        rm "$dir/$ffile.out" -f
        rm "$dir/$ffile.ans" -f
    fi
    exit "$1"
}
#########################
if [[ -f "$dir" ]];then
    echo "$dir no fonud."
    Exit -1
fi
a=$(ls ./*.cpp 2>/dev/null)
cnt=0
for in in $a
do
    p=${in:0:$((${#in}-4))}
    if [ "$p" != "$SPJ" ];then
        cpp=$in
        cnt=$((cnt+1))
    fi
done
if [[ $cnt -ge 2 && "$CPP" == "4747732939492939492394948384923949294" ]];then
    echo "too more cpp file here, please use -s."
    Exit -1
fi
if [[ $cnt == 0 ]];then
    echo "no cpp file here."
    Exit -1
fi
if [[ ! -e "$CPP" && "$CPP" != "4747732939492939492394948384923949294" ]];then
    echo "not find source."
    Exit -1
fi
if [ ! -e "$SPJ" ];then
    if [ -e "$SPJ.cpp" ];then
        
        if ! g++ "$SPJ.cpp" -o "$SPJ" $spjop 2>/dev/null ;then
            echo "$(tput setaf 11)special judge CE."
            Exit -1
        fi
    else
        echo "not find special judge."
        Exit -1
    fi
fi
if [ "$CPP" != "4747732939492939492394948384923949294" ];then
    cpp=$CPP
fi
tmp=${cpp:0:$((${#cpp}-4))}
if [[ $gdb != 1 ]];then
    g++ "$cpp" -o "$tmp" $op 2>/dev/null
    res=$?
else
    g++ "$cpp" -o "$tmp" $gdbop 2>/dev/null
    res=$?
fi
if [[ $res != 0 ]];then
    echo  "$(tput setaf 11)CE"
    Exit -1
fi
fl=$(ls ./*.in 2>/dev/null)
cnt=$(echo "$fl" | wc -w)
if [[ $cnt == 0 ]];then
    echo "no in/out/ans file here."
    Exit -1
fi
i=1
cp "$tmp" "/$dir/$tmp"
for in in $fl
do
    in=${in:2:${#in}}
    out=${in//.in/.out}
    ans=${in//.in/.ans}
    name=${in:0:$((${#in}-3))}
    echo "${name}[$i/$cnt]:"
    i=$((i+1))
    if [ ! -e "$ans" ]
    then
        if [ ! -e "$out" ];then
            if [ "$SPJ" != './' ];then
                cp "$in" "$ans"
            else
                echo "Skip"
                echo "not find out/ans file."
                echo
                continue
            fi
        else
            mv "$out" "$ans"
        fi
    fi
    if [[ $fre == 1 ]];then
        cp "$in" "$dir/$ffile.in"
        cp "$ans" "$dir/$ffile.ans"
        cd "$dir" || Exit -1
        echo "./$tmp 2>/dev/null" >"$ba"
        chmod u+x "$ba"
        Time=$( TIMEFORMAT="%R"; time ( timeout "$TimeLimit" "$ba") 2>&1 )
        ret=$?
        check "$ffile.in" "$ffile.out" "$ffile.ans" "$name"
        cd "$path" || Exit -1
        cp "$dir/$ffile.out" "$out"
        continue
    fi
    cp "$in" "$dir/$in"
    cp "$ans" "$dir/$ans"
    cd "$dir" || Exit -1
    echo "./$tmp <$in >$out 2>/dev/null" >"$ba"
    chmod u+x "$ba"
    Time=$( TIMEFORMAT="%R"; time ( timeout "$TimeLimit" "$ba") 2>&1 )
    ret=$?
    check "$in" "$out" "$ans" "$name"
    cd "$path" || Exit -1
    cp "$dir/$out" "$out"
    rm "$dir/$in" -f
    rm "$dir/$ans" -f
    rm "$dir/$out" -f
done
echo "$(tput setaf 5)RE on: ${RE[*]}"
echo "$(tput setaf 1)WA on: ${WA[*]}"
echo "$(tput sgr0)TLE on: ${TLE[*]}"
Exit 0