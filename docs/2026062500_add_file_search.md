# 需求分析
在 Gemini 工具箱的"文件工具"分类中增加一个**文件搜索**功能。用户希望使用像 Everything (voidtools) 这样轻量、高效、成熟的开源绿色工具，占用内存极小，无安装依赖。

Everything 原理类比：就像书的目录索引 —— 普通搜索是逐页翻书（遍历磁盘），Everything 是直接查目录（读 NTFS MFT），所以几乎是瞬间出结果。Java 中类似 HashMap O(1) 查找 vs ArrayList 遍历对比；Python 中类似 `dict[key]` vs `for item in list`；JS 中类似 `Map.get()` vs `Array.find()`。

# 方案调研

## 候选工具对比

| 工具 | 大小 | 原理 | 内存 | 速度 | 绿色 |
|------|------|------|------|------|------|
| **Everything CLI (es.exe)** | ~500KB | NTFS MFT 索引 | <1MB | 毫秒级 | ✅ 单文件 |
| Windows 自带搜索 | 系统内置 | 遍历/索引 | 高 | 慢 | ❌ |
| `Get-ChildItem -Recurse` | PowerShell内置 | 遍历磁盘 | 中 | 极慢 | ✅ |
| fd (Rust) | ~3MB | 遍历+并行 | 低 | 快 | ✅ 单文件 |

**选择 Everything CLI (`es.exe`)** 的原因：
- 搜索速度最快（NTFS MFT 直接查询，毫秒级返回）
- 内存占用极小 (<1MB)
- 最成熟稳定（voidtools 维护近 20 年）
- 绿色单文件，无需安装，无需管理员权限
- Everything 本身已安装在大多数 Windows 开发者机器上

## 集成方式
- 通过 PowerShell 调用 `es.exe` CLI，解析 stdout 输出
- 搜索 `es.exe` 优先级：项目 `Tools\es\` 目录 > 系统 PATH > Everything 安装目录
- 若未找到，UI 显示引导信息并提供下载链接

# 方案确认
在 Gemini "文件工具"分类下新增**文件搜索**工具，调用 Everything CLI (`es.exe`) 实现全局文件秒搜。UI 提供搜索框、结果列表、打开文件/目录等操作。

# 方案详细说明

## UI 设计
- 搜索框：关键词输入，回车触发搜索
- 可选项：路径过滤、文件类型过滤、大小写敏感、全词匹配
- 结果列表：GridView（文件名、路径、大小、修改日期）
- 操作：双击打开文件/目录，右键菜单（打开位置、复制路径）
- 底部状态栏：显示结果数量、es.exe 状态

## 技术要点
1. es.exe 查找策略：`Tools\es\es.exe` → 系统 PATH → 注册表查找 Everything 安装路径
2. 异步搜索：使用 `Start-Job` 或 `Runspace` 避免 UI 卡死
3. 结果解析：es.exe 输出格式 `<path>` 每行一条，使用正则解析
4. 安全：搜索参数做转义，防止命令注入
5. 兼容：无 es.exe 时友好提示并提供下载链接

## Everything 下载地址
- 官网: https://www.voidtools.com/
- 直接下载 CLI: https://www.voidtools.com/ES-1.1.0.27.zip
- GUI 安装版: https://www.voidtools.com/Everything-1.4.1.1026.x64-Setup.exe
- 放置位置: 将 `es.exe` 解压到 `Tools\es\` 目录下，或放到系统 PATH 中任意位置

# 代码修改点

## 修改
1. `Config/tools.json` — 在"文件重命名"后添加"文件搜索"工具条目

## 新增
1. `Tools/FileSearch.ps1` — 文件搜索工具完整脚本，包含 WPF UI 和 es.exe 调用逻辑

## 删除
无

# commit信息
1). 新增文件搜索工具 (FileSearch.ps1)，集成 Everything CLI 实现毫秒级全局文件搜索
2). 更新 tools.json 注册文件搜索工具到文件工具分类
