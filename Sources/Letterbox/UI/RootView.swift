import SwiftUI

struct RootView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if store.account == nil {
                OnboardingView()
                    .frame(minWidth: 820, minHeight: 600)
            } else {
                MainShell()
            }
        }
        .onChange(of: store.pendingCompose) { _, id in
            guard let id else { return }
            openWindow(id: "compose", value: id)
            store.pendingCompose = nil
        }
    }
}

struct MainShell: View {
    @Environment(MailStore.self) private var store
    @AppStorage("listWidth") private var listWidth: Double = 410
    @AppStorage("dashboardReaderWidth") private var readerWidth: Double = 620

    private var onDashboard: Bool { store.sidebarSelection == .dashboard && store.searchText.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            NavRail()
                .frame(width: 240)
            Rectangle().fill(Theme.hairline).frame(width: 1)

            if onDashboard {
                HStack(spacing: 0) {
                    Group {
                        if Snapshot.isActive {
                            GeometryReader { _ in
                                DashboardView(scrollable: false, fixedWidth: Snapshot.dashboardWidth)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .background(Theme.canvas)
                            .clipped()
                        } else {
                            DashboardView()
                        }
                    }
                    .frame(minWidth: 460)
                    if store.openedMessage != nil || store.selection.count > 1 {
                        ResizeHandle(width: $readerWidth, range: 460...900, invert: true)
                        ReaderPane(dismissable: true)
                            .frame(width: readerWidth)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.28), value: store.openedID)
            } else {
                HStack(spacing: 0) {
                    MessageListPane()
                        .frame(width: listWidth)
                    ResizeHandle(width: $listWidth, range: 320...620)
                    ReaderPane(dismissable: false)
                }
            }
        }
        .background(Theme.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1100, minHeight: 660)
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if store.showPalette {
                CommandPalette()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.snappy(duration: 0.18), value: store.showPalette)
        .alert("Delete permanently?", isPresented: Binding(
            get: { store.confirmDeletion != nil },
            set: { if !$0 { store.confirmDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) { store.deleteConfirmed() }
            Button("Cancel", role: .cancel) { store.confirmDeletion = nil }
        } message: {
            Text("These messages will be removed from the server. This can’t be undone.")
        }
    }
}

/// A thin draggable divider between panes.
struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    var invert = false
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering || start != nil ? Theme.accent.opacity(0.5) : Theme.hairline)
            .frame(width: 1)
            .overlay(Color.clear.frame(width: 9).contentShape(Rectangle()))
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if start == nil { start = width }
                        let delta = invert ? -v.translation.width : v.translation.width
                        width = min(range.upperBound, max(range.lowerBound, (start ?? width) + delta))
                    }
                    .onEnded { _ in start = nil }
            )
    }
}
