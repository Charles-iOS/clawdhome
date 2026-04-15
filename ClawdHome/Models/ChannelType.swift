// ClawdHome/Models/ChannelType.swift
// 消息渠道类型定义与当前可用渠道白名单

import Foundation
import SwiftUI

// MARK: - 渠道配置字段

struct ChannelConfigField: Identifiable {
    let id: String          // 字段标识，如 "appKey"
    let label: String       // 显示名称
    let placeholder: String // 输入提示
    let isSecure: Bool      // 是否为密钥字段（SecureField）
}

// MARK: - 渠道类型枚举

enum ChannelType: String, CaseIterable, Identifiable {
    case weixin
    case feishu
    case telegram
    case discord

    var id: String { rawValue }

    /// 当前版本在 UI 中开放的渠道
    static let enabledCases: [ChannelType] = [
        .feishu,
        .telegram,
    ]

    /// 渠道显示名称
    var displayName: String {
        switch self {
        case .weixin:    return "微信"
        case .feishu:    return "飞书"
        case .telegram:  return "Telegram"
        case .discord:   return "Discord"
        }
    }

    /// 渠道副标题
    var subtitle: String {
        switch self {
        case .weixin:    return "微信ClawBot"
        case .feishu:    return "飞书机器人"
        case .telegram:  return "Telegram Bot"
        case .discord:   return "Discord Bot"
        }
    }

    /// 渠道图标（SF Symbol）
    var iconName: String {
        switch self {
        case .weixin:    return "message.circle.fill"
        case .feishu:    return "paperplane.circle.fill"
        case .telegram:  return "paperplane.fill"
        case .discord:   return "gamecontroller.fill"
        }
    }

    /// 渠道图标颜色（字符串，兼容旧代码）
    var iconColor: String {
        switch self {
        case .weixin:    return "green"
        case .feishu:    return "blue"
        case .telegram:  return "cyan"
        case .discord:   return "indigo"
        }
    }

    /// 渠道图标 SwiftUI 颜色
    var swiftUIColor: Color {
        switch self {
        case .weixin:    return .green
        case .feishu:    return .blue
        case .telegram:  return .cyan
        case .discord:   return .indigo
        }
    }

    /// "如何接入？"文档链接（部分渠道有）
    var howToConnectURL: URL? {
        switch self {
        case .feishu:
            return URL(string: "https://open.feishu.cn/document/home/develop-a-bot-in-5-minutes/create-an-app")
        case .telegram:
            return URL(string: "https://core.telegram.org/bots#how-do-i-create-a-bot")
        case .weixin, .discord:
            return nil
        }
    }

    /// 是否支持群聊配对
    var supportsGroupChat: Bool {
        switch self {
        case .weixin: return false
        default:      return true
        }
    }

    /// 底部操作按钮文案
    var actionButtonTitle: String {
        switch self {
        case .weixin: return "绑定微信账号"
        default:      return "设置机器人"
        }
    }

    /// 是否使用交互式终端配对（微信走 QR 流程）
    var usesInteractiveOnboarding: Bool {
        self == .weixin
    }

    /// gateway config 路径前缀
    var configPathPrefix: String {
        "channels.\(rawValue)"
    }

    /// 该渠道需要配置的凭据字段
    var configFields: [ChannelConfigField] {
        switch self {
        case .feishu:
            return [
                ChannelConfigField(id: "appId", label: "App ID", placeholder: "cli_XXXXXXXXXX", isSecure: false),
                ChannelConfigField(id: "appSecret", label: "App Secret", placeholder: "请输入 App Secret", isSecure: true),
            ]
        case .telegram:
            return [
                ChannelConfigField(id: "botToken", label: "Bot Token", placeholder: "123456:ABC-DEF1234...", isSecure: true),
            ]
        case .discord:
            return [
                ChannelConfigField(id: "botToken", label: "Bot Token", placeholder: "请输入 Bot Token", isSecure: true),
                ChannelConfigField(id: "applicationId", label: "Application ID", placeholder: "请输入 Application ID", isSecure: false),
            ]
        case .weixin:
            return [] // 微信走 QR 配对流程，无需手动填写凭据
        }
    }
}
