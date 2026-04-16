// ClawdHome/Models/AgentStatus.swift
// 智能体运行状态

import Foundation

enum AgentStatus: String, Codable, Equatable {
    case idle              // workspace 存在，当前无活跃会话
    case active            // 有活跃 session
    case uninitialized     // 预置模板，workspace 尚未创建
}
