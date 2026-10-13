#!/usr/bin/env bash
# judge.sh -- C++ 评测脚本
#
# 功能: 编译选手代码 / SPJ, 逐个运行测试点, 判定 AC / WA / TLE / RE / MLE.
#
# ---------------------------------------------------------------------------
# MLE (内存超限) 判定与平台降级
# ---------------------------------------------------------------------------
# 判定优先级:
#   退出码 124                              -> TLE (最高优先)
#   退出码 134/139 且 -m > 0 且 ulimit -v 生效 -> MLE
#   其它非零退出码                          -> RE
#   退出码 0                                -> 进入 diff / SPJ 判定 WA 或 AC
#
# -m 限时通过子 shell 中的 `ulimit -v $((MB*1024))` 再 exec 选手程序实现.
#
# 降级行为: 部分平台 (典型为 Windows Git Bash / MSYS2) 的 `ulimit -v` 会"设置成功
# 但不生效"(实测: 设 65536 KB 后仍能分配并触碰 256 MB 内存并正常退出). 这种平台
# 上 MLE 无法可靠判定, 脚本自动跳过 MLE 判定, 134/139 一律按 RE 处理, 并在开始时
# 打印一行 "[warn] ... MLE detection disabled" 提示; 不会因此报错退出.
#
# 探测方式: 一次性编译一个极小的自检程序并做行为探测 (见 probe_ulimit_v):
# 在 64 MB 的 RLIMIT_AS 下再 mmap 64 MB 地址空间, mmap 失败 => ulimit -v 生效;
# mmap 成功 => 不生效. 结果缓存 (MleSupported), 每个测试点不重复编译/探测.
#
# ---------------------------------------------------------------------------
# 已知取舍 (兼容性说明)
# ---------------------------------------------------------------------------
# 1. timeout 使用 `-k 1` 保证超时后不会被忽略 TERM 的程序挂死. 由此产生两个
#    退出码: 正常 TERM 结束为 124; 必须升级到 KILL 时为 137. 因此 TLE 判定为
#    "退出码 124" 或 "退出码 137 且实际耗时确实达到限制", 避免把上升级为 KILL 的
#    超时误判成 RE. 可见行为与旧版一致或更严格, 文案与汇总行格式不变.
# 2. 编译错误信息 (g++ 的 stderr) 与旧版一致地丢弃, 仅打印 "CE";
#    若需诊断请手动运行 g++.
# ---------------------------------------------------------------------------

# 只启用 pipefail, 刻意不使用 set -u:
#   * 原脚本(以及本文件的既有风格)没有 set -u, 全部变量都有初值或用了 ${x:-} 守卫;
#   * 关掉 -u 后, "IndexedArray[name]" 这种不带 $ 的下标在运行时会被当作算术表达式
#     求值(空变量 -> 0, 从而静默写错位置). 本文件对索引数组一律写成 [var] 的语义
#     依赖着 -u 的约束, 所以这里保持与旧版一致的 "-o pipefail".
# 关联数组(键为点名字符串)用 declare -A 声明, 其下标不做算术求值, 不受此影响.
set -o pipefail
shopt -s nullglob

SH='.SH'               # bash -c 的 $0 占位, 与 judge.sh 自身无关
# MLE 探测固定使用的限制, 单位 KB (64 MB), 与自检程序自己申请的 64 MB 相匹配
ProbeLimitKB=65536

# ---------------------------------------------------------------- 输出颜色 ----
# tput 不可用或终端不支持颜色时降级为无颜色 (空字符串), 文字与旧版一致.
RST=''; RED=''; GRN=''; MAG=''; YEL=''
init_colors() {
    command -v tput >/dev/null 2>&1 || return 0
    local n
    n=$(tput colors 2>/dev/null) || n=0
    [[ ${n:-0} =~ ^[0-9]+$ ]] || n=0
    (( n >= 8 )) || return 0
    RST=$(tput sgr0 2>/dev/null)   || RST=''
    RED=$(tput setaf 1 2>/dev/null) || RED=''
    GRN=$(tput setaf 2 2>/dev/null) || GRN=''
    MAG=$(tput setaf 5 2>/dev/null) || MAG=''
    YEL=$(tput setaf 11 2>/dev/null) || YEL=''
}

# ------------------------------------------------------------------ 清理 ----
WorkDir=''      # 本次运行的独立工作目录 (mktemp -d)
ProbeDir=''     # MLE 探测程序目录 (mktemp -d)
# cleanup / die / need_cmd 都通过 trap 或间接分支调用, shellcheck 会把函数体判为
# "unreachable" (SC2317). 这是误报, 按函数整体豁免, 不做逐行标注.
# shellcheck disable=SC2317
cleanup() {
    trap - EXIT INT TERM
    [[ -n ${WorkDir:-} && -d ${WorkDir:-} ]] && rm -rf -- "$WorkDir"
    [[ -n ${ProbeDir:-} && -d ${ProbeDir:-} ]] && rm -rf -- "$ProbeDir"
    return 0
}
trap cleanup EXIT INT TERM

# shellcheck disable=SC2317
die() {
    printf '%s\n' "$*" >&2
    exit 255
}

# shellcheck disable=SC2317
need_cmd() {
    command -v "$1" >/dev/null 2>&1 && return 0
    die "required command not found: $1"
}

# ------------------------------------------------------------------ Usage ----
func() {
    echo "Usage:"
    echo "./judge.sh [-t TimeLimit] [-c Checker] [-s Source] [-g] [-f Freopen file] [-m MemoryLimit]"
    echo "Description:"
    echo "TimeLimit, unit second."
    echo "Checker, the cpp or binary file of special judge."
    echo "Source, the cpp you want to run."
    echo "-g, generate debugging information at compile time."
    echo 'Freopen file, the name of in/out/ans name(if ues freopen).'
    echo "-m, memory limit in MB, 0 means unlimited. MLE detection is skipped"
    echo "    automatically on platforms where ulimit -v has no effect."
    exit 0
}

# ------------------------------------------------------------ MLE 有效性 ----
# 行为探测: 64 MB 的 RLIMIT_AS 下, 再申请 64 MB 地址空间是否失败.
# 用 mmap(MAP_PRIVATE|MAP_ANONYMOUS) 而不是 malloc: 它直接占用地址空间, 要么成功
# 要么 ENOMEM, 不会被优化器折叠 (malloc+memset 在 -O2 下会被整段消除并直接返回
# "失败" 的分支, 从而把不支持该限制的平台误判成支持).
# 返回 0 表示 ulimit -v 生效 (可判 MLE), 非 0 表示不生效 (需降级).
probe_ulimit_v() {
    command -v g++ >/dev/null 2>&1 || return 1
    local src="$ProbeDir/probe.cpp" bin="$ProbeDir/probe"
    # 把自检程序写到真实文件再编译: 不依赖 process substitution, 兼容面更宽.
    {
        printf '%s\n' \
            '#include <cstddef>' \
            '#include <cstdio>' \
            '#include <sys/mman.h>' \
            'int main(){' \
            '    const std::size_t n = (std::size_t)64 * 1024 * 1024;' \
            '    void* p = mmap(0, n, PROT_READ | PROT_WRITE,' \
            '                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);' \
            '    if (p == MAP_FAILED) { return 3; }' \
            '    std::printf("mapped\n");' \
            '    return 0;' \
            '}'
    } >"$src" 2>/dev/null || return 1
    g++ -O2 "$src" -o "$bin" >/dev/null 2>&1 || return 1
    [[ -f $bin ]] || return 1
    # 探测限制固定为 64 MB: 它只回答"内核是否执行 RLIMIT_AS"这一个问题,
    # 与用户传入的 -m 数值无关 (匹配自检程序自己去申请的 64 MB).    local probe_rc
    bash -c 'ulimit -v "$1" 2>/dev/null; exec "$2"' "$SH" "$ProbeLimitKB" "$bin" >/dev/null 2>&1
    probe_rc=$?
    [[ $probe_rc -eq 3 ]] && return 0
    return 1
}

# ------------------------------------------------------------------ 判定 ----
# $1=退出码 $2=输入名 $3=选手输出名 $4=答案名 $5=测试点显示名
# $6=real 秒数(原样打印) $7=real 毫秒(整数, 用于 TLE 边界判断)
# 副作用: 把本次判定结果写入 PointStatus[$CurrentPointIndex], 供 subtask 汇总使用.
# 三个 printf 与旧版逐字一致, 状态采集不产生任何输出.
check() {
    local rc=$1 fin=$2 fout=$3 fans=$4 disp=$5 wall=$6 wall_ms=$7 v
    if (( rc == 124 || (rc == 137 && wall_ms >= limit_ms) )); then
        printf '%s\n' "${RST}TLE"
        TLE+=("$disp")
        v=TLE
    elif (( rc != 0 )); then
        if (( MemLimit > 0 && MleSupported == 1 && (rc == 134 || rc == 139) )); then
            printf '%s\n' "${YEL}MLE"
            MLE+=("$disp")
            v=MLE
        else
            printf '%s\n' "${MAG}RE"
            RE+=("$disp")
            v=RE
        fi
    elif [[ $SPJ != './' ]]; then
        if "$spj_abs" "$fin" "$fout" "$fans" >/dev/null 2>&1; then
            printf '%s\n' "${GRN}AC"
            v=AC
        else
            printf '%s\n' "${RED}WA"
            WA+=("$disp")
            v=WA
        fi
    elif diff -ZB "$fout" "$fans" >/dev/null 2>&1; then
        printf '%s\n' "${GRN}AC"
        v=AC
    else
        printf '%s\n' "${RED}WA"
        WA+=("$disp")
        v=WA
    fi
    printf '%s\n' "${RST}Spend Time: $wall s"
    printf '\n'
    PointStatus[CurrentPointIndex]=$v
}

# --------------------------------------------------------------- subtask ----
# 状态 -> 颜色, 与判定输出保持同一风格
sub_color() {
    case $1 in
        AC)  printf '%s' "$GRN";;
        WA)  printf '%s' "$RED";;
        TLE) printf '%s' "$RST";;
        RE)  printf '%s' "$MAG";;
        MLE) printf '%s' "$YEL";;
        *)   printf '%s' "$RST";;
    esac
}

# D 方案: 测试点名(不含 .in) 是否形如 sub<数字>_<非空>
# 匹配则打印 <数字>, 不匹配返回 1.
# 说明: 用显式正则而不是 glob, 因为 glob 无法表达"sub 后至少一位数字"
# (sub_1.in 会被 sub*_*.in 误匹配). 正则大小写敏感, 故 Sub1_1.in 不匹配.
subtask_of_name() {
    if [[ $1 =~ ^sub([0-9]+)_(.+)\.in$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# $1=subtask 标识 -> 把其在 SubIds 中的下标写入全局 SubIdxResult; 不存在则先追加.
# 必须走全局变量而不是 printf 返回值: 用 $(subtask_index ...) 取值会让函数在子 shell
# 里执行, SubIds/SubPoints 等追加全部丢失, 且下标会退化成空串(等于下标 0), 使
# SubPoints 被写到错误的位置.
subtask_index() {
    local id=$1 i
    for (( i = 0; i < ${#SubIds[@]}; i++ )); do
        if [[ ${SubIds[i]} == "$id" ]]; then SubIdxResult=$i; return 0; fi
    done
    SubIds+=("$id")
    SubPoints+=("")
    SubTotal+=(0)
    SubPass+=(0)
    SubStatus+=("")
    SubIdxResult=$(( ${#SubIds[@]} - 1 ))
    return 0
}

# $1=点下标 $2=subtask 标识: 把该点加入分组 (last-wins 时先移除旧归属)
subtask_assign() {
    local pidx=$1 id=$2 si
    subtask_index "$id"
    si=$SubIdxResult
    if [[ -n ${PointSub[pidx]:-} ]]; then
        subtask_remove_point "$pidx" "${PointSub[pidx]}"
    fi
    PointSub[pidx]=$id
    SubPoints[si]="${SubPoints[si]} $pidx"
    SubTotal[si]=$(( SubTotal[si] + 1 ))
}

# $1=点下标 $2=旧的 subtask 标识: 从该组移除这个点 (用于 last-wins 重分配)
subtask_remove_point() {
    local pidx=$1 oldid=$2 i si=-1 kept="" p
    for (( i = 0; i < ${#SubIds[@]}; i++ )); do
        if [[ ${SubIds[i]} == "$oldid" ]]; then si=$i; break; fi
    done
    (( si >= 0 )) || return 0
    for p in ${SubPoints[si]}; do
        [[ $p == "$pidx" ]] && continue
        kept="$kept $p"
    done
    SubPoints[si]="$kept"
    SubTotal[si]=$(( SubTotal[si] - 1 ))
}

# 所有测试点跑完后调用: 按 SubIds 顺序统一打印各组汇总.
# 无任何 subtask 时一行都不打印, 以此保证纯独立点场景与旧版逐字一致.
report_subtasks() {
    local i
    (( ${#SubIds[@]} > 0 )) || return 0
    for (( i = 0; i < ${#SubIds[@]}; i++ )); do
        (( SubTotal[i] > 0 )) || continue   # 成员全为空/全被跳过的组不打印
        printf '%sSubtask %s: %s (%s/%s)\n' \
            "$(sub_color "${SubStatus[i]}")" "${SubIds[i]}" \
            "${SubStatus[i]}" "${SubPass[i]}" "${SubTotal[i]}"
    done
}

# 重新统计每组的点数/AC 数并定状态: 组成员为空则不产生状态.
# 判定规则: 组内全部 AC => 该组 AC; 否则取第一个非 AC 点的状态.
compute_subtask_results() {
    local i members pidx st
    for (( i = 0; i < ${#SubIds[@]}; i++ )); do
        members=${SubPoints[i]}
        SubTotal[i]=0
        SubPass[i]=0
        SubStatus[i]=""
        for pidx in $members; do
            st=${PointStatus[$pidx]:-}
            [[ -n $st ]] || continue        # SKIP 的点不参与 subtask 统计
            SubTotal[i]=$(( SubTotal[i] + 1 ))
            if [[ $st == AC ]]; then
                SubPass[i]=$(( SubPass[i] + 1 ))
            elif [[ -z ${SubStatus[i]} ]]; then
                SubStatus[i]=$st             # 第一个非 AC 状态
            fi
        done
        if (( SubTotal[i] > 0 )) && [[ -z ${SubStatus[i]} ]]; then
            SubStatus[i]=AC
        fi
    done
}

# -------------------------------------------------------------------- CLI ----
TimeLimit=1
SPJ="./"
SPJ_BASE="./"
RE=()
WA=()
TLE=()
MLE=()
CPP=""
gdb=0
fre=0
ffile=""
data=""
MemLimit=0
MleSupported=0
CPP_CHECKER=""     # 是否显式传入 -c (用于区分默认的 SPJ="./")
KillAfter=1        # timeout -k 的宽限秒数, 保证忽略 TERM 的程序也能被终止
# --- subtask 相关状态 (C 方案: subtasks.txt 优先; D 方案: 文件名规则) -----------
# 全部用索引数组 + 两个关联数组(仅索引名可能为任意字符串处).
# 关联数组必须用 declare -A 声明: 普通的 X=() 会退化成索引数组, 于是以任意
# 字符串作下标时会被当作算术表达式求值 (a -> $a), 在 set -u 下直接报
# "unbound variable". 这两个数组按字典序点名的键必须走关联数组。
# 纯独立点场景下这些变量始终为空, 因此不产生任何额外输出.
declare -A CfgPointSub=()   # [点名] = 配置里的 subtask 标识 (C 方案)
declare -A DynPointSub=()   # [点名] = D 文件名规则识别出的 subtask 标识
CfgOrderName=()    # 配置里出现的点名, 按文件顺序 (关联数组 ${!x[@]} 无顺序, 必须另存)
CfgOrderId=()      # 与 CfgOrderName 同下标: 对应的 subtask 标识
SubIds=()          # 出现顺序的 subtask 标识列表 (C 按配置顺序, D 按 sort 后的首次出现顺序)
SubPoints=()       # 与 SubIds 同下标: "idx1 idx2 ..." 该组的测试点下标
SubTotal=()        # 与 SubIds 同下标: 该组实际执行的点数
SubPass=()         # 与 SubIds 同下标: 该组中 AC 的点数
SubStatus=()       # 与 SubIds 同下标: 首个非 AC 状态; 全 AC 则为 AC
PointStatus=()     # [点下标] = AC/WA/TLE/RE/MLE; SKIP 的点不参与 subtask 统计
PointSub=()        # [点下标] = 该点的 subtask 标识 (last-wins 重分配时会被改写)
SubIdxResult=0     # subtask_index 的返回值出口 (避免用 $(...) 导致副作用丢失)
CurrentPointIndex=0
while getopts 'ht:c:s:gf:d:m:' OPT; do
    case $OPT in
        t) TimeLimit="$OPTARG";;
        c) SPJ="$OPTARG"; CPP_CHECKER=1;;
        s) CPP="$OPTARG";;
        g) gdb=1;;
        f) fre=1; ffile="$OPTARG";;
        m) MemLimit="$OPTARG";;
        d) data="$OPTARG";;
        h) func;;
        ?) func;;
    esac
done

[[ $TimeLimit =~ ^[1-9][0-9]*$ ]] || die "invalid -t value: $TimeLimit (positive integer expected)"
[[ $MemLimit =~ ^[0-9]+$ ]] || die "invalid -m value: $MemLimit (non-negative integer expected)"
limit_ms=$(( TimeLimit * 1000 ))

# -s 前置校验: 与旧版同样只检查存在性 (-e), 同样打印 "not find source." 并 exit 255,
# 但改为在编译 SPJ / 枚举 cpp 之前就完成, 避免对不存在的源文件做多余动作.
if [[ -n $CPP && ! -e $CPP ]]; then
    printf '%s\n' "not find source."
    exit 255
fi

# 规范 -c 传入的路径, 避免旧版 "././xxx" 之类的拼接; SPJ_BASE 用于识别 SPJ 源文件.
# 未传 -c 时 SPJ 保持 "./" 这一"无 SPJ"标记, 不做规范化, 否则后面的
# `[[ ! -e $SPJ ]]` 会因目录 "." 存在而误判, 走进 "not find special judge.".
if [[ -n $CPP_CHECKER ]]; then
    while [[ $SPJ == ./* ]]; do SPJ=${SPJ#./}; done
fi
SPJ_BASE="$SPJ"
case $SPJ_BASE in
    *.cpp) SPJ_BASE=${SPJ_BASE%.cpp};;
esac
# 判定时进程工作目录会切到测试点目录, 旧版 "./$SPJ" 于是总在 /tmp 下找不到 SPJ
# (被静默当成 WA). 这里把它解析成基于源目录的绝对路径, 语义与旧版一致但真正可用.
spj_abs="$SPJ"
if [[ $SPJ != './' ]]; then spj_abs="$PWD/$SPJ"; fi

init_colors

# ----------------------------------------------------------- 依赖与环境 ----
need_cmd g++
need_cmd mktemp
need_cmd timeout
need_cmd find
need_cmd sort
need_cmd diff

# ulimit -s unlimited: 失败时不再中断 (Linux 上 -s 单位是 KB, 这里沿用旧写法)
ulimit -s unlimited || true

WorkDir=$(mktemp -d) || die "mktemp -d failed"
base=$PWD    # 源数据目录的绝对路径; 每个测试点会 cd 到自己的工作目录, 结束时再 cd 回来

# 旧版此处是 `[[ -f "$dir" ]]` (死代码, 恒假). 修正为目录检查; 现在工作目录由
# mktemp -d 生成, 因此文案 "not found." 同时覆盖 mktemp 失败与目录不可用两种情况.
if [[ ! -d $WorkDir ]]; then
    printf '%s not found.\n' "$WorkDir"
    exit 255
fi

# --------------------------------------------------------------- 选手源 ----
cnt=0
cpp=""
for f in ./*.cpp; do
    [[ -e $f ]] || continue
    b=${f%.cpp}
    if [[ $b != "$SPJ_BASE" ]]; then
        cpp=$f
        cnt=$(( cnt + 1 ))
    fi
done
if (( cnt >= 2 )) && [[ -z $CPP ]]; then
    echo "too more cpp file here, please use -s."
    exit 255
fi
if (( cnt == 0 )); then
    echo "no cpp file here."
    exit 255
fi

# ----------------------------------------------------------- SPJ 与源 ----
if [[ ! -e $SPJ ]]; then
    if [[ -e "$SPJ.cpp" ]]; then
        if ! g++ "$SPJ.cpp" -o "$SPJ" -std=c++14 -O2 2>/dev/null; then
            printf '%s\n' "${YEL}special judge CE."
            exit 255
        fi
    else
        echo "not find special judge."
        exit 255
    fi
fi

# -s 的存在性已在上面前置校验过, 这里只接管源文件
if [[ -n $CPP ]]; then
    cpp=$CPP
fi

# --------------------------------------------------------------- 编译 ----
tmp=${cpp%.cpp}
if (( gdb == 1 )); then
    compile_flags=(-std=c++14 -Og -g)
else
    compile_flags=(-std=c++14 -O2)
fi
if ! g++ "$cpp" -o "$tmp" "${compile_flags[@]}" 2>/dev/null; then
    printf '%s\n' "${YEL}CE"
    exit 255
fi
bin="$tmp"
# Windows 环境 (MSYS2/Git Bash) 下 g++ 会自动补 .exe. 这里刻意不用 [[ -x ]]:
# Cygwin 的 X_OK 会把任何 .exe 都判为可执行, 从而误选到同名可执行文件.
[[ -f $bin ]] || bin="$tmp.exe"
# 转成绝对路径: 选手程序是在每个测试点的工作目录里启动的, 相对路径会失效.
bin="$PWD/$bin"

# ------------------------------------------------------------ MLE 探测 ----
if (( MemLimit > 0 )); then
    ProbeDir=$(mktemp -d) || ProbeDir=""
    if [[ -n $ProbeDir && -d $ProbeDir ]] && probe_ulimit_v; then
        MleSupported=1
    else
        MleSupported=0
        printf '%s\n' "${YEL}[warn] memory limit (-m ${MemLimit}MB) has no effect on this platform; MLE detection disabled, 134/139 is reported as RE."
    fi
fi

# ------------------------------------------------------------- 测试点 ----
fl=()
while IFS= read -r t; do
    [[ -n $t ]] && fl+=("$t")
done < <(find . -maxdepth 1 -name "${data}*.in" | sort)
count=${#fl[@]}
if (( count == 0 )); then
    echo "no in/out/ans file here."
    exit 255
fi

# ------------------------------------------------- subtask 分组与识别 ----
# 1) C 方案: 当前目录存在 subtasks.txt 时优先使用它
# 2) D 方案: 未出现在配置中的点回退到文件名规则 sub<N>_*.in
# 两者都没有 => 独立点, 输出与旧版逐字一致.
PointNameOf() { printf '%s' "${1%.in}"; }

if [[ -f subtasks.txt ]]; then
    cfg_line=0
    while IFS= read -r cfg_line_str || [[ -n $cfg_line_str ]]; do
        cfg_line=$(( cfg_line + 1 ))
        cfg_line_str=${cfg_line_str%%#*}          # # 起的整行/行尾注释
        read -r -a cfg_fields <<< "$cfg_line_str" # 按空白拆分, 自动跳过连续空白/tab
        (( ${#cfg_fields[@]} == 0 )) && continue  # 空行/纯注释行
        cfg_id=${cfg_fields[0]}                   # 标识原样使用(可为数字或名称)
        for (( k = 1; k < ${#cfg_fields[@]}; k++ )); do
            cfg_name=${cfg_fields[k]}
            cfg_name=${cfg_name%.in}              # 宽容: 配置里带 .in 后缀也接受
            cfg_prev=${CfgPointSub[$cfg_name]:-}
            if [[ -n $cfg_prev && $cfg_prev != "$cfg_id" ]]; then
                printf '%s\n' "${YEL}[warn] subtasks.txt:$cfg_line: point '$cfg_name' reassigned from subtask '$cfg_prev' to '$cfg_id'." >&2
            fi
            CfgPointSub[$cfg_name]=$cfg_id        # last-wins
            CfgOrderName+=("$cfg_name")           # 按文件顺序记录, 供后面按序登记分组
            CfgOrderId+=("$cfg_id")
        done
    done < subtasks.txt

    # 配置里引用了磁盘上不存在的测试点: 警告并从分组中忽略
    for cfg_name in "${!CfgPointSub[@]}"; do
        cfg_hit=0
        for in_path in "${fl[@]}"; do
            cfg_pname=$(PointNameOf "${in_path#./}")
            if [[ $cfg_pname == "$cfg_name" ]]; then cfg_hit=1; break; fi
        done
        if (( cfg_hit == 0 )); then
            printf '%s\n' "${YEL}[warn] subtasks.txt: point '$cfg_name' not found among test points; ignored." >&2
            unset "CfgPointSub[$cfg_name]"
        fi
    done
fi

# 预解析每个测试点的 subtask, 并建 D 方案映射 (仅使用文件名规则)
sub_idx=0
for in_path in "${fl[@]}"; do
    sub_idx=$(( sub_idx + 1 ))
    PointSub[sub_idx]=""
    if sub_id=$(subtask_of_name "${in_path#./}"); then
        DynPointSub[$(PointNameOf "${in_path#./}")]=$sub_id
    fi
done

# 组建分组: C 方案按配置文件顺序登记 (保证 Subtask 行的显示顺序 = 配置顺序),
# 再处理回退到 D 方案的点.
# 注意: 不能遍历 "${!CfgPointSub[@]}" 来决定顺序 —— 关联数组的键顺序是任意的.
cfg_i=0
for (( cfg_i = 0; cfg_i < ${#CfgOrderName[@]}; cfg_i++ )); do
    cfg_name=${CfgOrderName[cfg_i]}
    # last-wins 后被 unset 的(重分配走了的)或引用不存在的点, 这里跳过
    [[ -n ${CfgPointSub[$cfg_name]:-} ]] || continue
    sub_idx=0
    for in_path in "${fl[@]}"; do
        sub_idx=$(( sub_idx + 1 ))
        if [[ $(PointNameOf "${in_path#./}") == "$cfg_name" ]]; then
            subtask_assign "$sub_idx" "${CfgOrderId[cfg_i]}"
            break
        fi
    done
done
sub_idx=0
for in_path in "${fl[@]}"; do
    sub_idx=$(( sub_idx + 1 ))
    [[ -z ${PointSub[$sub_idx]:-} ]] || continue     # 已由 C 方案分组
    sub_file=${in_path#./}
    sub_name=$(PointNameOf "$sub_file")
    # C 方案优先, 否则回退 D 方案(用完整文件名匹配); 都没有则该点为独立点
    sub_id=${CfgPointSub[$sub_name]:-}
    [[ -n $sub_id ]] || sub_id=${DynPointSub[$sub_name]:-}
    if [[ -n $sub_id ]]; then
        subtask_assign "$sub_idx" "$sub_id"
    fi
done

idx=0
for in_path in "${fl[@]}"; do
    idx=$(( idx + 1 ))
    rel=${in_path#./}
    name=${rel%.in}
    echo "${name}[$idx/$count]:"

    out_name="${rel//.in/.out}"
    ans_name="${rel//.in/.ans}"
    # 下面会 cd 进测试点目录, 先把这些相对源目录的路径固化成绝对路径
    in_abs="$base/$rel"
    ans_abs="$base/$ans_name"
    out_abs="$base/$out_name"

    # 答案文件补全, 与旧版行为一致
    if [[ ! -e $ans_name ]]; then
        if [[ ! -e $out_name ]]; then
            if [[ $SPJ != './' ]]; then
                cp -- "$in_abs" "$ans_abs"
            else
                echo "Skip"
                echo "not find out/ans file."
                echo
                continue
            fi
        else
            mv -- "$out_abs" "$ans_abs"
        fi
    fi

    # 每个测试点一个独立工作目录: 取代硬编码 /tmp, 并避免测试点间互相污染.
    # 与旧版一致地把进程工作目录切到测试点目录: 这样输入重定向名固定为 infile,
    # 且 freopen 模式下选手程序能在自己的 cwd 里读到 <ffile>.in / 写出 <ffile>.out.
    if ! cwd=$(mktemp -d "$WorkDir/case.XXXXXX"); then
        echo "cannot create case directory."
        exit 255
    fi
    # rel / out_name / ans_name 都是相对源目录的路径, 下面会 cd 进测试点目录,
    # 因此上面的 in_abs / ans_abs / out_abs 必须在 cd 之前算好.
    cd "$cwd" || { echo "$cwd not found."; exit 255; }
    cp -- "$in_abs" infile
    cp -- "$ans_abs" ansfile

    # 用 bash -c + 重定向直接执行, 不再生成临时 shell 脚本 / chmod.
    if (( fre == 1 )); then
        cp -- "$in_abs" "$ffile.in"
        cp -- "$ans_abs" "$ffile.ans"
    fi

    # -m 生效时: ulimit -v $((MB*1024)) 之后用 exec 替换掉这个子 shell.
    # 注意: 重定向不能通过数组展开传递 ("${arr[@]}" 会把 < 与文件名当成
    # bash -c 的位置参数, 不会真的重定向), 所以必须写进命令串里.
    if (( fre == 1 )); then
        stdin_src=/dev/null      # freopen 模式: 选手程序自己开 <ffile>.in
    else
        stdin_src=infile
    fi
    if (( MemLimit > 0 && MleSupported == 1 )); then
        vmem=$(( MemLimit * 1024 ))
        cmd="ulimit -v $vmem 2>/dev/null; exec \"\$1\" <$stdin_src >outfile 2>stderr.txt"
    else
        cmd="exec \"\$1\" <$stdin_src >outfile 2>stderr.txt"
    fi
    run_cmd=(bash -c "$cmd" "$SH" "$bin")

    # time 的 %R 走 stderr, 因此只把内置命令的 stderr 收进命令替换,
    # 选手程序自身的 stdout/stderr 由命令串里的重定向丢弃.
    wall=$( { TIMEFORMAT='%R'; time timeout -k "$KillAfter" "$TimeLimit" "${run_cmd[@]}"; } 2>&1 >/dev/null )
    rc=$?
    [[ $wall =~ ^[0-9]+(\.[0-9]+)?$ ]] || wall=0
    # 把 "%R" 的秒换算成整数毫秒. 纯 bash 实现, 不依赖 awk / printf 的浮点与
    # locale; 注意不能对 "2.006" 直接切片, 否则会得到 200 而不是 2006.
    # 退出码 124 = timeout 的 TERM 路径; 137 = 必须升级到 KILL 的路径,
    # 后者只有耗时确实达到限制时才计为 TLE, 以免真正的 SIGKILL 被误判成 TLE.
    wall_sec=${wall%%.*}
    wall_frac=${wall#*.}
    [[ $wall_frac == "$wall" ]] && wall_frac=''
    wall_frac="${wall_frac}000"
    wall_ms="${wall_sec}${wall_frac:0:3}"
    [[ $wall_ms =~ ^[0-9]+$ ]] || wall_ms=0

    # 告知 check() 这是第几个点, 以便把判定结果写入 PointStatus 供 subtask 汇总使用
    # (subtask 归属由 run 前的分组阶段确定, 判定阶段不需要)
    CurrentPointIndex=$idx
    if (( fre == 1 )); then
        check "$rc" "$ffile.in" "$ffile.out" "$ffile.ans" "$name" "$wall" "$wall_ms"
    else
        check "$rc" infile outfile ansfile "$name" "$wall" "$wall_ms"
    fi

    if (( fre == 1 )); then
        if [[ -e $ffile.out ]]; then
            cp -- "$ffile.out" "$out_abs"
        fi
    else
        # 与旧版一致: 无论判定结果, 都把选手输出拷回源目录
        [[ -e outfile ]] && cp -- outfile "$out_abs"
    fi
    cd "$base" || exit 255
    rm -rf -- "$cwd"
done

# subtask 汇总: 所有点跑完后再统一打印, 按 SubIds 顺序; 无 subtask 时零输出.
compute_subtask_results
report_subtasks
if (( ${#SubIds[@]} > 0 )); then
    sub_passed=0
    sub_counted=0
    for (( sub_i = 0; sub_i < ${#SubIds[@]}; sub_i++ )); do
        (( SubTotal[sub_i] > 0 )) || continue   # 空组不计入分母
        sub_counted=$(( sub_counted + 1 ))
        [[ ${SubStatus[sub_i]} == AC ]] && sub_passed=$(( sub_passed + 1 ))
    done
    printf '%sSubtasks: %s/%s passed\n' "$RST" "$sub_passed" "$sub_counted"
fi

printf '%s\n' "${MAG}RE on: ${RE[*]}"
printf '%s\n' "${RED}WA on: ${WA[*]}"
printf '%s\n' "${RST}TLE on: ${TLE[*]}"
printf '%s\n' "${YEL}MLE on: ${MLE[*]}"
exit 0
