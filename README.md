# OI-judger
已使用AI重構。
一個本地評測的bash腳本。
支持Linux與Windows，推薦在Linux下使用。
## 使用方式
需將其放入工作目錄中。

會自動編譯 SPJ 和 Source 文件。

```
Usage:
./judge.sh [-t TimeLimit] [-c Checker] [-s Source] [-g] [-f Freopen file] [-m MemoryLimit]
Description:
TimeLimit, unit second.
Checker, the cpp or binary file of special judge.
Source, the cpp you want to run.
-g, generate debugging information at compile time.
Freopen file, the name of in/out/ans name(if ues freopen).
-m, memory limit in MB, 0 means unlimited. MLE detection is skipped
    automatically on platforms where ulimit -v has no effect.
```
