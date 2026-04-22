// EZRWorkerApp/Views/PageHeroHeader.swift
// 详情页统一大标题 + 副标题

import SwiftUI

struct PageHeroHeader: View {
    let title: String
    var subtitle: String? = nil
    /// 副标题最大行数
    var subtitleLineLimit: Int = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 36, weight: .bold))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .lineLimit(subtitleLineLimit)
            }
        }
    }
}
