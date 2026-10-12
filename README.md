# rpmrebuild [![Hits](https://hits.sh/github.com/KongQBin/rpmrebuild.svg?label=%E7%82%B9%E5%87%BB%E9%87%8F&color=007ec6)](https://hits.sh/github.com/KongQBin/rpmrebuild/)

rpmrebuild 用于从**已安装的软件**或**已有 RPM 文件**重新生成 RPM 包，适合找回已安装软件的安装包、修改 SPEC 元数据，以及调整包内文件和依赖。

原项目由 **Eric Gerbier** 和 **Valery Reznic** 开发。本仓库基于原项目及社区贡献继续维护，源码版本号目前为 **2.18**；本分支的修改见下文。原项目说明保留在 [src/README](src/README)，主页为 [rpmrebuild on SourceForge](https://sourceforge.net/projects/rpmrebuild/)。

## 工作方式

程序通过 `rpm` 查询包的元数据、依赖、文件属性和安装脚本，生成 SPEC，准备包内文件，然后调用 `rpmbuild` 构建新包。主要实现为 Bash 脚本，支持通过插件修改 SPEC 和文件。

- 从已安装软件重打包时，使用当前文件系统中的文件；配置或程序文件的本地修改会进入新包。
- 从 RPM 文件重打包时，通过 `rpm2cpio` 解包；失败后尝试使用 `rpm2archive`。
- 原包的数字签名不会保留，新包需要另行签名。
- 强制架构只调整打包信息，不会将包内二进制程序转换为另一种架构，也不会执行交叉编译。

## 相对原项目的修改

### 本分支的功能与修复

| 修改项 | 具体变化 |
| --- | --- |
| 解包变量修复 | 将解包流程中遗留的 `PAQUET` 引用修正为 `RPMREBUILD_PAQUET`，统一临时归档文件路径，修复传入 RPM 文件后解包失败的问题。 |
| 默认编辑器 | 编辑 SPEC 时默认使用 `vim`，仍优先遵循 `VISUAL`、`EDITOR` 环境变量。 |
| 显式强制架构 | 新增 `--force-arch=<arch>`，也支持 `FORCE_ARCH` 环境变量；指定后移除 SPEC 中的 `BuildArch`，通过目标架构和 RPM 宏控制构建。未指定时保留原包架构。 |
| 架构能力声明 | 强制架构时移除原包自动生成的 `包名(ISA)` Provides，避免新架构包继续声明旧架构能力；保留其他显式 Provides，处理带 Epoch 和外架构来源包。 |
| 语言文件保留 | 修复从 RPM 文件重打包时，因宿主机没有对应 `%lang` 文件而将其静默排除的问题；已安装包的缺失文件检查仍保留。 |
| 参数传递 | 构建参数和 RPM 宏定义改用 Bash 数组传递，移除这些调用中的 `eval`；验证强制架构值，避免参数被重新解释为 Shell 命令。 |
| 路径与文件名 | 转义生成的处理脚本中的路径，修复带空格的 SPEC 输出路径写错文件却返回成功的问题；读取文件记录时保留反斜杠和首尾空白，并在 SPEC 文件清单中转义反斜杠、双引号。 |
| 符号链接 | 复制已安装文件时保留悬空符号链接；处理 ghost 文件时识别已有链接，避免将其误当作缺失文件重新创建。 |
| 错误传播 | 对涉及查询和过滤的 SPEC 生成管道启用 `pipefail`，使上游失败正确终止流程；ShellCheck 检查脚本也正确传播失败退出码。 |
| 检查与测试 | 新增独立回归测试及 `test-regressions` Makefile 目标；修正静态检查发现的参数引用问题，并为生成脚本、信号处理等间接调用添加说明。 |

其中，参数传递的调整也改变了 `--additional` 的行为：支持用引号或反斜杠保留参数中的空格，但不再执行 Shell 命令、变量替换或命令替换。`--modify`、`--change-spec-*` 等用于执行用户命令的接口仍按各自原有用途工作。

### 保留的社区贡献

以下改进由社区贡献者 **林凌儿（linlinger）** 加入，本仓库保留并继续维护：

- **大于 4 GB RPM 的初步支持**：在 `rpm2cpio` 失败时增加 `rpm2archive` 备用解包路径，见提交 [a520912](https://github.com/KongQBin/rpmrebuild/commit/a5209127a626bce7410749504ab1ff3b91355faa)。本分支随后修复了该路径中的旧变量引用。
- **禁用重新生成 build-id 链接**：生成的 SPEC 设置 `_build_id_links none`，减少重打包时产生的文件冲突，见提交 [c8e3af1](https://github.com/KongQBin/rpmrebuild/commit/c8e3af1d8c0c1c0597942bb01e58780ae09b8e02)。

RPM 元数据提取、SPEC 生成、插件体系、文件属性处理等核心能力继承自原项目。上述列表用于说明后续维护，不将原有功能归为本分支新增功能。

## 运行依赖

需要 Bash、`rpm`、`rpmbuild`、`rpm2cpio`、`cpio`、`tar`，以及常用的 GNU 文本处理和文件工具，如 `awk`、`sed`、`grep`、`coreutils`。

- `rpm2archive`：使用备用解包路径时需要。
- `vim` 或通过 `VISUAL` / `EDITOR` 指定的编辑器：交互式编辑 SPEC 时需要。
- Python 3：运行新增回归测试时需要。
- ShellCheck：运行静态检查时需要，已验证版本为 **0.11.0**。CentOS 7 软件源中的 **0.3.8** 不支持检查脚本使用的 `-a`、`-x` 参数及源码注释格式。

GHC 和 Cabal 仅用于自行编译 ShellCheck，运行 rpmrebuild 不需要它们。

## 安装与直接运行

在仓库根目录执行 `make -C src` 生成安装所需的 SPEC 和手册。安装目录可通过 `TARGET_*` 变量指定，例如：

```bash
rpmrebuild_prefix=/opt/rpmrebuild-2.18
make -C src
sudo make -C src install \
  TARGET_DIR="$rpmrebuild_prefix/bin" \
  TARGET_LIB="$rpmrebuild_prefix/lib/rpmrebuild" \
  TARGET_PLUGIN="$rpmrebuild_prefix/lib/rpmrebuild/plugins" \
  TARGET_LOCALE="$rpmrebuild_prefix/lib/rpmrebuild/locale" \
  TARGET_MAN="$rpmrebuild_prefix/share/man"

export RPMREBUILD_ROOT_DIR="$rpmrebuild_prefix/lib/rpmrebuild"
export PATH="$rpmrebuild_prefix/bin:$PATH"
rpmrebuild --version
```

`RPMREBUILD_ROOT_DIR` 告诉入口脚本从哪里加载实现文件；使用上述自定义安装目录时，需要在使用 rpmrebuild 的 Shell 中保留此设置。

也可以直接在仓库根目录运行源码：

```bash
bash src/rpmrebuild.sh --help
bash src/rpmrebuild.sh --help-plugins
```

## 常用示例

下面的 `example-package` 和 `example.rpm` 分别代表已安装包名和输入 RPM 文件，请替换为实际名称。`-d` 指定新 RPM 的输出目录，`-b` 启用批处理模式。

```bash
# 从已安装的软件生成 RPM
rpmrebuild -b -d "$HOME/rpm-output" example-package

# 从已有 RPM 文件重新打包
rpmrebuild -b -p -d "$HOME/rpm-output" ./example.rpm

# 交互式编辑 SPEC 后重打包
rpmrebuild -e -p ./example.rpm

# 只导出 SPEC，不构建 RPM
rpmrebuild -p -s ./example.spec ./example.rpm

# 显式调整打包架构
rpmrebuild -b -p --force-arch=aarch64 ./example.rpm

# 向 rpmbuild 传递包含空格的宏定义
rpmrebuild -b -p --additional="--define 'message hello world'" ./example.rpm
```

`--force-arch` 接受由字母、数字和下划线组成的架构名。实际能否构建取决于本机 RPM 配置及包中的架构限制；它不保证包内程序能在目标架构上运行。

更多用法见 [英文手册源码](src/man/en/rpmrebuild.1.in)、`rpmrebuild --help`、`rpmrebuild --help-plugins`，以及维护者的 [使用说明](https://www.cnblogs.com/KBin/p/19911228)。

## 验证与测试

在仓库根目录执行：

```bash
# 静态检查
make -C src check

# 新增的独立回归测试
make -C src test-regressions
```

独立回归测试使用 Python 3 标准库，无需额外 Python 包；安装 RPM 构建工具后，会创建临时测试包并验证重打包结果。测试包、构建目录及输出均在临时目录中，不安装测试包。缺少 RPM 集成工具时，相关集成测试会被跳过。

目前 **17 项回归测试**已通过，覆盖语言文件及内容保留、架构和 Provides 一致性、Epoch、外架构来源包、参数引用、特殊路径、失败退出码和悬空链接；原有的 **10 项帮助测试**也已通过。验证环境为 **CentOS 7 / RPM 4.11.3 / ShellCheck 0.11.0**。

验证范围不等于所有历史测试都已通过：`src/t/` 中部分测试依赖特定已安装包和仓库未附带的 RPM 样本。大于 4 GB RPM 的备用解包路径及新版 RPM 的兼容性尚未完成实际验证。

## 目录结构

| 目录 / 文件 | 用途 |
| --- | --- |
| `src/rpmrebuild.sh` | 主流程、解包、架构处理和构建。 |
| `src/*.src` | 参数解析、RPM 查询格式、SPEC 生成及处理函数。 |
| `src/plugins/` | 修改文件、依赖和 SPEC 标签等插件。 |
| `src/t/` | 原有 Perl 测试。 |
| `test/test_regressions.py` | 新增的独立回归测试。 |
| `src/man/`、`src/locale/` | 手册与翻译。 |
| `grpmrebuild/`、`web/`、`doc/` | 图形入口及其他项目资料。 |

## 作者与许可证

原作者为 Eric Gerbier、Valery Reznic；本分支由 KongQBin 维护，并保留社区贡献者的署名和提交历史，详见 [src/AUTHORS](src/AUTHORS)。

项目遵循 **GNU GPL v2 或更高版本**，详见 [src/COPYING](src/COPYING) 和各源码文件中的许可证声明。
