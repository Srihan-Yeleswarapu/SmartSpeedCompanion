import SwiftUI

#if DEVELOPER_BUILD
public struct DeveloperTabView: View {
    @StateObject private var logger = DebugLogger.shared
    @State private var autoScroll = true
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    List(logger.logs) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.formattedTimestamp)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(DesignSystem.cyan)
                                
                                Spacer()
                            }
                            
                            Text(entry.message)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .padding(.vertical, 4)
                        .id(entry.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: logger.logs.count) { _, _ in
                        if autoScroll, let last = logger.logs.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                
                Divider()
                
                HStack {
                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .font(.caption)
                    
                    Spacer()
                    
                    Text("\(logger.logs.count) entries")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .padding()
                .background(DesignSystem.bgDeep)
            }
            .navigationTitle("DEVELOPER LOGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") {
                        logger.clear()
                    }
                    .foregroundColor(DesignSystem.alertRed)
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        DebugLogger.shared.log("Manual test log triggered")
                    }) {
                        Image(systemName: "plus.circle")
                    }
                }
            }
            .background(DesignSystem.bgDeep.ignoresSafeArea())
        }
    }
}
#endif
