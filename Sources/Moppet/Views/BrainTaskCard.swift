import SwiftUI

/// 并行任务卡（设计文档 §5.11）：紧凑单行（显示优化——多任务并行时整条
/// 任务条不再把对话挤出屏幕）。行内：状态图标 + 标题 + 进行中工具 + 状态
/// 标签 + 取消。**不放流式正文**（R4：UI 重估放大，任务卡的刷新是事件
/// 驱动状态字段，不是每 token 全量重估）。
/// 「等待你」子态由 scheduler.stage(of:) 从 Approval/UserInput 中心查询
/// 派生，整行加主色描边高亮——需要人动手的事必须最先跳进眼睛。
struct BrainTaskCard: View {
    let task: BrainTask
    let stage: BrainTask.Stage
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .font(Airi.footnoteFont)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(Airi.footnoteFont.weight(.medium))
                    .foregroundStyle(Airi.neutral700)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let tool = task.lastToolName, stage == .running || stage == .awaitingUser {
                    Text(tool)
                        .font(Airi.monoCaption2Font)
                        .foregroundStyle(Airi.neutral500)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(stageLabel)
                .font(Airi.caption2Font.weight(.medium))
                .foregroundStyle(stageColor)
            if stage == .queued || stage == .running {
                Text(task.createdAt, style: .timer)
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral400)
                    .monospacedDigit()
                    .help(L("Elapsed time"))
            }
            if stage != .completed && stage != .failed && stage != .cancelled {
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Airi.footnoteFont)
                        .foregroundStyle(Airi.neutral400)
                }
                .buttonStyle(.plain)
                .help(L("Cancel task"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                .fill(stage == .awaitingUser ? Airi.primary.opacity(0.08) : Airi.neutral100.opacity(0.55))
                .strokeBorder(
                    stage == .awaitingUser ? Airi.primary.opacity(0.5) : Airi.neutral200,
                    lineWidth: stage == .awaitingUser ? 1.2 : 1
                )
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch stage {
        case .queued:
            Image(systemName: "hourglass")
                .foregroundStyle(Airi.neutral400)
        case .running:
            // 转动的迷你菊花：活着的任务一眼可辨
            ProgressView()
                .controlSize(.mini)
                .tint(Airi.primary)
        case .awaitingUser:
            Image(systemName: "person.wave.2.fill")
                .foregroundStyle(Airi.primary)
        case .completed, .failed, .cancelled:
            // 任务条只渲染非 ended 卡片（ended 由 transcript 结果行呈现）；
            // 兜底图标仅为穷举。
            Image(systemName: "circle.dotted")
                .foregroundStyle(Airi.neutral400)
        }
    }

    private var stageLabel: String {
        switch stage {
        case .queued: L("Queued")
        case .running: L("Running")
        case .awaitingUser: L("Waiting for you")
        case .completed: L("Completed")
        case .failed: L("Failed")
        case .cancelled: L("Cancelled")
        }
    }

    private var stageColor: Color {
        switch stage {
        case .queued: Airi.neutral500
        case .running: Airi.primary
        case .awaitingUser: Airi.primary
        case .completed: Airi.success
        case .failed: Airi.danger
        case .cancelled: Airi.neutral400
        }
    }
}
