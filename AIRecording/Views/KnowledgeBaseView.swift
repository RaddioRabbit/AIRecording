import SwiftUI

struct KnowledgeBaseView: View {
    @StateObject private var viewModel = KnowledgeBaseViewModel()

    var body: some View {
        HStack(spacing: 0) {
            KnowledgeSessionList(viewModel: viewModel)
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 260)
            Divider()
            KnowledgeConversationView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await viewModel.load() }
        .onDisappear { viewModel.cancelGeneration() }
    }
}

private struct KnowledgeSessionList: View {
    @ObservedObject var viewModel: KnowledgeBaseViewModel
    @State private var renamingSession: KnowledgeChatSession?
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                viewModel.createSession()
            } label: {
                Label("新建对话", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            List(selection: $viewModel.selectedSessionID) {
                ForEach(viewModel.sessions, id: \.objectID) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title ?? "新建对话")
                            .lineLimit(1)
                        Text(session.updatedAt ?? session.createdAt ?? .distantPast, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(session.objectID)
                    .contextMenu {
                        Button("重命名") {
                            renamingSession = session
                            title = session.title ?? ""
                        }
                        Button("删除", role: .destructive) {
                            viewModel.selectSession(session.objectID)
                            viewModel.deleteSelectedSession()
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .padding(12)
        .alert("重命名对话", isPresented: Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )) {
            TextField("对话名称", text: $title)
            Button("取消", role: .cancel) { renamingSession = nil }
            Button("保存") {
                if let session = renamingSession {
                    viewModel.selectSession(session.objectID)
                    viewModel.renameSelectedSession(to: title)
                }
                renamingSession = nil
            }
        }
    }
}

private struct KnowledgeConversationView: View {
    @ObservedObject var viewModel: KnowledgeBaseViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isIndexDegraded {
                Label("知识库索引正在补全，部分结果可能不完整。", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                Divider()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if viewModel.messages.isEmpty && !viewModel.isGenerating {
                        VStack(spacing: 10) {
                            Image(systemName: "books.vertical")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("开始提问")
                                .font(.headline)
                            Text("新建一个对话后，可以基于已转写的录音提问。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                            .frame(maxWidth: .infinity, minHeight: 300)
                    }
                    ForEach(viewModel.messages, id: \.objectID) { message in
                        KnowledgeMessageBubble(message: message)
                    }
                    if viewModel.isGenerating {
                        KnowledgeGeneratingBubble(
                            content: viewModel.displayedAnswer,
                            sources: viewModel.pendingSources
                        )
                    }
                    if let errorMessage = viewModel.errorMessage {
                        HStack(spacing: 8) {
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundStyle(.red)
                            if !viewModel.isGenerating {
                                Button("重试") { Task { await viewModel.retryLastQuestion() } }
                                    .buttonStyle(.link)
                            }
                        }
                        .padding(10)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(20)
            }
            Divider()
            composer
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextEditor(text: $viewModel.draft)
                .font(.body)
                .frame(minHeight: 36, maxHeight: 88)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
            if viewModel.isGenerating {
                Button("停止") { viewModel.cancelGeneration() }
                    .buttonStyle(.bordered)
            } else {
                Button("发送") {
                    let question = viewModel.draft
                    Task { await viewModel.send(question) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }
}

private struct KnowledgeMessageBubble: View {
    let message: KnowledgeChatMessage

    var body: some View {
        let isUser = message.roleEnum == .user
        VStack(alignment: isUser ? .trailing : .leading, spacing: 7) {
            Text(isUser ? "你" : "知识库")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isUser {
                Text(message.content ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MarkdownTextView(markdown: message.content ?? "")
            }
            if !isUser {
                KnowledgeSourceChipsView(sources: Array((message.sources as? Set<KnowledgeSourceLink>) ?? []))
            }
        }
        .padding(12)
        .frame(maxWidth: 640, alignment: isUser ? .trailing : .leading)
        .background(isUser ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

private struct KnowledgeGeneratingBubble: View {
    let content: String
    let sources: [KnowledgeSourceDTO]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("知识库正在生成回答")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !content.isEmpty {
                MarkdownTextView(markdown: content)
            }
            if !sources.isEmpty {
                Text("已找到 \(sources.count) 条来源")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 640, alignment: .leading)
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}
