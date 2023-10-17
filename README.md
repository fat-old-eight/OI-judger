# OI-judger
一個本地評測的bash腳本。
僅支持Linux。
## 使用方式
需將其放入工作目錄中。

會自動編譯 SPJ 和 Source 文件。
```
Usage:
./judge.sh [-t TimeLimit] [-c Checker] [-s Source] [-g]
Description:
TimeLimit,unit second.
Checker,the cpp or binary file of special judge.
Source,the cpp you want to run.
-g,generate debugging information at compile time.
```
## 注意
現在不支持 subtest 和判斷 MLE。

以及如果文件夾下有多個 cpp 文件，請指定 Source。

歡迎 PR。（如果不介意如答辯一樣的代碼的話。）
