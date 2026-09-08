import SwiftUI

struct FileTabsView: View {
    @Bindable var model: SessionModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(model.documents) { document in
                    HStack(spacing: 8) {
                        Button { model.selectDocument(document.id) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "swift").foregroundStyle(.orange)
                                Text(document.name).lineLimit(1)
                                if document.isDirty { Circle().fill(.secondary).frame(width: 5, height: 5) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Select \(document.name)")
                        Button { model.closeDocument(document.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(.secondary)
                        }.buttonStyle(.plain).accessibilityLabel("Close \(document.name)")
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(document.id == model.activeDocumentID ? .white.opacity(0.07) : .clear)
                    .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.07)).frame(width: 1) }
                    .help(document.fileURL?.path ?? "Unsaved session")
                }
            }
        }.scrollIndicators(.hidden).frame(height: 30)
            .background(.black.opacity(0.12)).accessibilityIdentifier("document-tabs")
    }
}
