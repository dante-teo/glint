import SwiftUI

struct NewWorkspacePopover: View {
    @EnvironmentObject var store: WorkspaceStore
    let dismiss: () -> Void
    @State private var hoveredKind: WorkspaceKind?
    @State private var pickingFolder = false

    private var devinInstalled: Bool {
        DevinHookInstaller.isAgentPresent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(spacing: 3) {
                pickerRow(
                    kind: .terminal,
                    title: "Terminal",
                    subtitle: "Shell workspace",
                    icon: .system("terminal"),
                    badge: nil
                ) {
                    store.addWorkspace()
                    dismiss()
                }

                pickerRow(
                    kind: .agent,
                    title: "Devin Agent",
                    subtitle: "AI coding agent",
                    icon: .asset("DevinMark"),
                    badge: devinInstalled ? nil : "Not installed"
                ) {
                    pickDevinProject()
                }
            }
            .padding(6)
        }
        .frame(width: 286)
        .background(
            ZStack {
                VisualEffectBackground(material: .menu)
                LinearGradient(
                    colors: [
                        Theme.sidebarTintTop.opacity(0.97),
                        Theme.sidebarTintBottom.opacity(0.97),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
    }

    private var header: some View {
        HStack {
            Text("NEW WORKSPACE")
                .font(AppFonts.ui(10, weight: .semibold))
                .kerning(1.1)
                .foregroundStyle(Theme.text4)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func pickerRow(kind: WorkspaceKind,
                           title: LocalizedStringKey,
                           subtitle: LocalizedStringKey,
                           icon: PickerIcon,
                           badge: LocalizedStringKey?,
                           action: @escaping () -> Void) -> some View {
        let hovered = hoveredKind == kind
        return Button(action: action) {
            HStack(spacing: 10) {
                pickerIcon(icon, active: hovered)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(AppFonts.ui(13, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(AppFonts.ui(11))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let badge {
                    Text(badge)
                        .font(AppFonts.ui(9.5, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.73, blue: 0.36))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(red: 1.0, green: 0.73, blue: 0.36).opacity(0.14)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered ? Theme.overlay(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pickingFolder && kind == .agent)
        .onHover { hoveredKind = $0 ? kind : nil }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    @ViewBuilder
    private func pickerIcon(_ icon: PickerIcon, active: Bool) -> some View {
        switch icon {
        case .system(let name):
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(store.accent.opacity(active ? 0.26 : 0.16))
                .overlay {
                    Image(systemName: name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(store.accent)
                }
        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .padding(2)
                .shadow(color: Color(red: 0.16, green: 0.43, blue: 0.81).opacity(active ? 0.55 : 0),
                        radius: 6)
        }
    }

    private func pickDevinProject() {
        guard !pickingFolder else { return }
        pickingFolder = true
        store.newWorkspacePopoverOpen = false
        Task { @MainActor in
            let folder = await FolderPicker.pickProjectFolder()
            pickingFolder = false
            guard let folder else {
                store.newWorkspacePopoverOpen = true
                return
            }
            store.addAgentWorkspace(provider: .devin, projectPath: folder.path)
            dismiss()
        }
    }
}

private enum PickerIcon {
    case system(String)
    case asset(String)
}
