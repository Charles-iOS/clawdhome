// ClawdHome/Models/AgentStatus.swift
// 智能体运行状态

import Foundation

enum AgentStatus: String, Codable, Equatable {
    case idle              // workspace 存在，但尚无会话
    case active            // 只要存在任意 session，即视为运行中
    case uninitialized     // 预置模板，workspace 尚未创建
}
