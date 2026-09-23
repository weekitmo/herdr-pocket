## 提交规范

标题行中的type（必须）：commit 类型，只能填写如下类型：

- feat: 新功能、新特性
- fix: 修改 bug
- perf: 更改代码，性能优化
- refactor: 代码重构（重构，在不影响代码内部行为、功能下的代码修改）
- docs: 文档修改
- style: 代码格式修改, 注意不是 css 修改（例如分号修改）
- test: 测试用例新增、修改
- build: 影响项目构建或依赖项修改
- revert: 恢复上一次提交
- ci: 持续集成相关文件修改
- chore: 其他修改（不在上述类型中的修改）
- release: 发布新版本
- workflow: 工作流相关文件修改

## 其他说明

- scope（可选）: 用于说明commit 影响的范围, 比如: global, common, route, component, utils, build...
- subject: commit 的简短概述，不超过50个字符。
- body: commit 具体修改内容, 可以分为多行。
- footer: 一些备注, 通常是 BREAKING CHANGE 或修复的 bug 的链接。
