import SwiftUI
import UIKit

struct DebugLogView: View {
    @ObservedObject var log: DebugLog
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(log.entries) { entry in
                            Text(entry.line)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: log.entries.count) { _, _ in
                    if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onAppear {
                    if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .navigationTitle("Debug log (\(log.entries.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(copied ? "Copied" : "Copy log") {
                        UIPasteboard.general.string = log.exportText
                        copied = true
                    }
                    Spacer()
                    Button("Clear", role: .destructive) {
                        log.clear()
                        copied = false
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
