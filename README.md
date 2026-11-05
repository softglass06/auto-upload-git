# 自动上传 GitHub 小工具

一个 Windows 拖拽脚本:把项目文件夹拖到 `upload.cmd` 上,它会自动识别核心代码、过滤掉测试/构建文件,提交并推送到 GitHub,commit message 由 Claude 润色。

## 功能

- **拖拽即用**:把文件夹拖到 `upload.cmd` 图标上即可
- **自动识别三种情况**:
  - 文件夹自带 `.git` → 原地提交并推送
  - 没有 `.git` → 选择「新建独立仓库」或「复制进某个已有仓库」
- **双重过滤**:`filter-rules.txt` 里的默认规则 + 项目自己的 `.gitignore`
- **先预览后提交**:提交前列出会传哪些、跳过哪些,确认才动手
- **中文描述 → 规范 commit**:你打一句中文,调 Claude 润色成 conventional commit
- **自动补 remote**:目标仓库没有 `origin` 时,提示输入地址并 `git remote add`

## 安装

1. 下载 / 克隆本仓库到本地,例如 `C:\Users\you\auto-upload-git`
2. (可选)把 `upload.cmd` 发送快捷方式到桌面
3. (可选)编辑 `repos.txt` 和 `filter-rules.txt`

## 使用

把项目文件夹拖到 `upload.cmd` 上,按提示操作即可。也可以直接双击,会弹出选择文件夹的窗口。

## 依赖

- **Windows**(PowerShell 5.1 或更高)
- **git**,且在 PATH 中
- **Claude Code CLI**(可选,用于润色 commit message;没装会退回用你输入的原文)

## 配置

### repos.txt(已有仓库列表)

每行一个,格式 `名字|完整路径`,`#` 开头是注释:

```
my-project|D:\code\my-project
demo|C:\Users\you\projects\demo
```

### filter-rules.txt(过滤规则)

- `#` 开头是注释
- 目录名后加 `/` 表示整个目录跳过,例如 `node_modules/`
- 带 `*` 或 `?` 的通配符匹配文件名 / 目录名,例如 `*.test.*`
- 不带斜杠的普通名字匹配任何一层的同名目录或文件,例如 `__pycache__`

## 常见问题

- **脚本里为什么全是英文提示?** 是刻意的:PowerShell 5.1 会把无 BOM 的 `.ps1` 按 GBK 读,非 ASCII 字节会导致下一行被吞掉,所以脚本只用 ASCII。你输入中文描述、Claude 生成中文 commit 都完全正常。
- **想跳过 Claude 润色?** 不装 Claude Code CLI 即可,脚本会自动退回用你输入的原文。
- **别把含个人路径的 `repos.txt` 提交上去。**
