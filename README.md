# rpmrebuild [![Hits](https://hits.sh/github.com/KongQBin/rpmrebuild.svg?label=%E7%82%B9%E5%87%BB%E9%87%8F&color=007ec6)](https://hits.sh/github.com/KongQBin/rpmrebuild/)
- 使用说明暂时详见 [rpmrebuild - 博客园](https://www.cnblogs.com/KBin/p/19911228)
- 在原作者的基础上解决bug若干
- 优化发现的问题
- 持续维护中……


## 回归测试

运行 `make -C src test-regressions`。测试使用 Python 3 标准库；实际重打包测试还需要
`rpm`、`rpmbuild`、`rpm2cpio` 和 `cpio`，测试包及输出均在临时目录创建。

`--additional` 支持用引号或反斜杠保留参数中的空格，例如
`--additional="--define 'message hello world'"`；参数作为字面值传递，不执行 Shell 命令或变量替换。
`--force-arch` 接受由字母、数字和下划线组成的架构名，只改变打包架构，不转换二进制程序。
