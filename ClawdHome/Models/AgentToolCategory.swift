// ClawdHome/Models/AgentToolCategory.swift
// 工具分类静态定义（Step 2 占位用）

import Foundation

struct AgentToolCategory: Identifiable {
    let id: String
    let name: String
    let icon: String          // SF Symbol name
    let tools: [String]       // 子工具名称

    /// 全部工具分类（与截图一致）
    static let all: [AgentToolCategory] = [
        AgentToolCategory(
            id: "filesystem",
            name: L10n.k("agent.tool.filesystem", fallback: "文件系统"),
            icon: "folder.fill",
            tools: ["List", "Read", "Grep", "Glob", "Ripgrep", "Write", "Edit"]
        ),
        AgentToolCategory(
            id: "web",
            name: L10n.k("agent.tool.web", fallback: "网络与浏览"),
            icon: "globe",
            tools: ["Web Search", "Web Fetch"]
        ),
        AgentToolCategory(
            id: "product",
            name: L10n.k("agent.tool.product", fallback: "选品找货"),
            icon: "bag.fill",
            tools: ["Product Supplier Search"]
        ),
        AgentToolCategory(
            id: "code",
            name: L10n.k("agent.tool.code", fallback: "代码与终端"),
            icon: "terminal.fill",
            tools: ["Bash", "Process", "Cron", "Question"]
        ),
        AgentToolCategory(
            id: "image",
            name: L10n.k("agent.tool.image", fallback: "图像与媒体"),
            icon: "photo.fill",
            tools: ["Image Generate", "Image Edit", "See Image"]
        ),
        AgentToolCategory(
            id: "utility",
            name: L10n.k("agent.tool.utility", fallback: "实用工具"),
            icon: "wrench.fill",
            tools: ["Weather", "Time", "Location", "MCP Call"]
        ),
        AgentToolCategory(
            id: "memory",
            name: L10n.k("agent.tool.memory", fallback: "记忆与规划"),
            icon: "brain.fill",
            tools: ["Memory Search", "Memory Get", "Task Create", "Task Get", "Task Update", "Task List"]
        ),
        AgentToolCategory(
            id: "collaboration",
            name: L10n.k("agent.tool.collaboration", fallback: "智能体协作"),
            icon: "person.3.fill",
            tools: ["Sessions Spawn", "Sessions List", "Sessions History", "Sessions Send"]
        ),
    ]
}
