[English](README.md) | [简体中文](README.zh-CN.md)

# mission-control — 一键掌控你的整个 Agent 智能体集群

`mc status`。单面板呈现。纯标准库实现，零外部依赖。Agent 集群领域的 `htop`：分布式链路跟踪 (traces)、LangSmith 云端状态、集群组件健康度、code-factory 冒烟检测、运行平面、连接器与 Tailscale 状态 —— 一屏通览，一键触发。

## 60 秒快速上手

```bash
curl -o mc https://raw.githubusercontent.com/empire-mind/mission-control/main/mc
chmod +x mc
./mc status
```

## 真实状态：内部自用验证，尚非正式产品

本项目最初作为 empire-mind agent 运行时的状态监控面板而构建，因此带有明显特征：部分检测项会读取特定环境路径（如 `~/workspace/org/…`、本地 LangSmith 认证代理以及 Tailscale 快照标记）。在未部署该环境的普通机器上运行时，这些模块会明确报告“not found”（未找到）或提供单行引导，而绝不会崩溃 —— 优雅降级是本项目的核心设计原则；对于目前尚未完善之处，欢迎参与认领 `good first issue`。

当前最值得借鉴的是本项目的**架构范式**：单一纯标准库脚本、一个通用的 `section()` 辅助函数、每个检测项均为独立且绝不抛出异常的小函数。我们已将该规范提炼为一份仅需 10 行代码的插件契约（详见 [docs/PLUGIN-CONTRACT.md](docs/PLUGIN-CONTRACT.md)）—— 这是本项目杠杆效应最高的贡献方向。

## 命令参考

| 命令 | 功能描述 |
|---|---|
| `./mc status` | 完整的单面板状态监控（8 个核心检测项及概览条） |
| `./mc traces [N]` | 查看本地 JSONL 存储中的最近 N 条链路追踪事件（默认 5 条） |
| `./mc eval` | 7 项全栈自检测试套件；失败时返回退出码 1 |
| `./mc heal` | 自动重启异常的本地服务（涵盖 8 大工具集） |
| `./mc runs [N]` | 每次调用的耗时与执行记录摘要 |
| `./mc costs [N]` | 预估调用成本数据行 —— 每项数字均明确标注 ESTIMATE（仅供预估） |

## 设计原则

- **纯标准库 (Stdlib only)**：若需要通过 pip 安装依赖，则不属于 `mc` 的范畴。
- **检测段绝不抛出异常 (Never raise in a section)**：检测失败时仅打印一行诊断并继续执行 —— 一个会意外崩溃的状态面板比没有面板更糟糕。
- **预估值必须明确标注 ESTIMATE**：所有成本相关数据行必须清晰标示为预估值。
- **60 秒原则**：通过 `curl` 下载，赋予权限，即刻查看输出。配置流程超过一分钟即视为缺陷。

## 本地开发与测试

```bash
./mc eval        # 栈内自检套件，提交 PR 前必须通过
python3 -m py_compile mc
python3 -m pytest tests/test_mc.py
```

详见 [CONTRIBUTING.md](CONTRIBUTING.md) 以及插件开发规范 [docs/PLUGIN-CONTRACT.md](docs/PLUGIN-CONTRACT.md)。

## 贡献指南

**我们对每一个 issue 和外部 PR 均承诺在 7 个自然日内给出首次回应。** 标记为 `good first issue` 的任务通常适合在一个晚上内完成 —— 插件契约扩展和优雅降级审核是最佳切入点。完整说明请参阅 [CONTRIBUTING.md](CONTRIBUTING.md)。安全漏洞报告请遵循组织的 [SECURITY.md](https://github.com/empire-mind/.github/blob/main/SECURITY.md)。

## 许可证

MIT — 详见 [LICENSE](LICENSE)。
