import SwiftUI

/// Bottom bar shared by all sidebar sections: one primary "+ New …" button that truncates instead of wrapping,
/// plus optional icon-only accessories, so the bar never needs more width than the sidebar column.
/// Attach it with `.safeAreaBar(edge: .bottom)` (not `safeAreaInset`) to get the standard scroll-edge effect.
struct SidebarBottomBar<Accessories: View>: View {
    let title: String
    var systemImage = "plus"
    var role: ButtonRole?
    var isDisabled = false
    let action: () -> Void
    @ViewBuilder var accessories: Accessories

    var body: some View {
        // Liquid Glass: glass capsules grouped in a container so neighbouring shapes blend, placed with
        // `safeAreaBar` by callers so the system applies the scroll-edge effect to the list underneath.
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button(role: role, action: action) {
                    Label(title, systemImage: systemImage)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(isDisabled)
                .layoutPriority(1)
                Spacer(minLength: 4)
                accessories
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

extension SidebarBottomBar where Accessories == EmptyView {
    init(title: String, systemImage: String = "plus", role: ButtonRole? = nil, isDisabled: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, systemImage: systemImage, role: role, isDisabled: isDisabled, action: action) { EmptyView() }
    }
}

/// Icon-only accessory button with a tooltip and accessibility label.
struct SidebarIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .help(help)
        .accessibilityLabel(help)
    }
}
