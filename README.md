# script

常用命令行脚本集合。

## cherry-all

将指定 commit **cherry-pick** 到选定的本地分支。

| 平台 | 入口 |
|------|------|
| Windows | `cherry-all.cmd` → `cherry-all.ps1` |
| macOS / Linux | `cherry-all.sh` |

### 安装

**Windows**

1. 把本目录加入用户 PATH（例如 `E:\script`）
2. 新开终端后可直接执行 `cherry-all`

**macOS / Linux**

```bash
chmod +x cherry-all.sh
sudo ln -sf "$(pwd)/cherry-all.sh" /usr/local/bin/cherry-all
# 或放到 ~/bin 并确保在 PATH 中
```

### 用法

先进入目标 git 仓库目录：

```bash
# 交互选择分支
cherry-all <commit-hash>

# 直接指定分支（支持通配符）
cherry-all <commit-hash> --branches master,new-ui
# Windows PowerShell 参数形式：
cherry-all <commit-hash> -Branches master,new-ui

# 处理全部本地分支
cherry-all <commit-hash> --all          # Unix
cherry-all <commit-hash> -All           # Windows

# 有未提交改动时自动 stash / 恢复
cherry-all <commit-hash> --stash        # Unix
cherry-all <commit-hash> -Stash         # Windows

# 仅预览
cherry-all <commit-hash> --dry-run      # Unix
cherry-all <commit-hash> -DryRun        # Windows

# 冲突时跳过该分支继续
cherry-all <commit-hash> --continue-on-conflict   # Unix
cherry-all <commit-hash> -ContinueOnConflict      # Windows
```

### 交互选择

列出本地分支后，可输入：

- 编号 / 区间：`1,3,5-8`
- 名称或通配：`master,项目-*`
- 全部：`a` / `all` / `*`
- 取消：直接回车

### 说明

- 需要干净工作区（或使用 `--stash` / `-Stash`）
- 已包含该 commit 的分支会自动跳过
- 结束后会切回原来的分支
- Windows 下对 git 输出按 UTF-8 解码，避免中文分支名乱码
