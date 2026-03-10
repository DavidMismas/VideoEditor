import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProjectWorkspaceView: View {
    @Bindable var viewModel: EditorViewModel
    @State private var activeAlert: WorkspaceAlert?

    var body: some View {
        Group {
            if viewModel.hasActiveProject {
                VStack(spacing: 0) {
                    ProjectHeaderBar(
                        viewModel: viewModel,
                        onNewProject: {
                            viewModel.closeProject()
                        },
                        onOpenProject: openProject,
                        onSaveProject: saveProject,
                        onSaveProjectAs: saveProjectAsAction
                    )

                    if viewModel.hasMissingProjectAssets {
                        MissingAssetsBanner(viewModel: viewModel)
                    }

                    MainEditorView(viewModel: viewModel)
                }
            } else {
                ProjectLauncherView(
                    onCreateProject: createProject,
                    onOpenProject: openProject
                )
            }
        }
        .alert(activeAlert?.title ?? "", isPresented: Binding(
            get: { activeAlert != nil },
            set: { isPresented in
                if !isPresented {
                    activeAlert = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                activeAlert = nil
            }
        } message: {
            Text(activeAlert?.message ?? "")
        }
        .onChange(of: viewModel.pendingAlert) { _, newValue in
            guard let newValue else { return }
            activeAlert = newValue
            viewModel.pendingAlert = nil
        }
    }

    private func createProject(
        name: String,
        resolutionPreset: ProjectResolutionPreset,
        canvasOrientation: CanvasOrientation
    ) {
        do {
            try viewModel.createProject(
                name: name,
                resolutionPreset: resolutionPreset,
                canvasOrientation: canvasOrientation
            )
        } catch {
            presentAlert(title: "Could Not Create Project", message: error.localizedDescription)
        }
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [ProjectFileFormat.contentType, .json]
        panel.title = "Open Project"
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try viewModel.openProject(at: url)
        } catch {
            presentAlert(title: "Could Not Open Project", message: error.localizedDescription)
        }
    }

    private func saveProject() {
        do {
            if viewModel.projectFileURL == nil {
                try saveProjectAs()
            } else {
                try viewModel.saveProject()
            }
        } catch {
            presentAlert(title: "Could Not Save Project", message: error.localizedDescription)
        }
    }

    private func saveProjectAsAction() {
        do {
            _ = try saveProjectAs()
        } catch {
            presentAlert(title: "Could Not Save Project", message: error.localizedDescription)
        }
    }

    @discardableResult
    private func saveProjectAs() throws -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [ProjectFileFormat.contentType]
        panel.title = "Save Project"
        panel.prompt = "Save"
        panel.nameFieldStringValue = suggestedProjectFilename()

        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        if url.pathExtension.lowercased() != ProjectFileFormat.fileExtension {
            url.appendPathExtension(ProjectFileFormat.fileExtension)
        }
        try viewModel.saveProject(to: url)
        return url
    }

    private func suggestedProjectFilename() -> String {
        let rawName = viewModel.resolvedProjectName
        let sanitized = rawName.replacingOccurrences(of: "/", with: "-")
        return "\(sanitized).\(ProjectFileFormat.fileExtension)"
    }

    private func presentAlert(title: String, message: String) {
        activeAlert = WorkspaceAlert(title: title, message: message)
    }
}

private struct ProjectHeaderBar: View {
    @Bindable var viewModel: EditorViewModel
    let onNewProject: () -> Void
    let onOpenProject: () -> Void
    let onSaveProject: () -> Void
    let onSaveProjectAs: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.resolvedProjectName)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.textMain)

                    Text("\(viewModel.projectCanvasDescription) • \(viewModel.projectResolutionDescription)")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                }

                Spacer(minLength: 16)

                ProjectActionButton(title: "New Project", action: onNewProject)
                ProjectActionButton(title: "Open Project", action: onOpenProject)
                ProjectActionButton(title: "Save", action: onSaveProject, isPrimary: true)
                ProjectActionButton(title: "Save As", action: onSaveProjectAs)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [
                        Theme.panelBackground.opacity(0.98),
                        Theme.backgroundDark.opacity(0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            Divider()
                .background(Theme.separator)
        }
    }
}

private struct ProjectActionButton: View {
    let title: String
    let action: () -> Void
    var isPrimary: Bool = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(isPrimary ? .black : Theme.textMain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isPrimary ? Theme.accentGreen : Theme.panelBackground.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.separator.opacity(isPrimary ? 0 : 1), lineWidth: 1)
                )
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

private struct MissingAssetsBanner: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.black)

            VStack(alignment: .leading, spacing: 2) {
                Text("Missing project files")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.black)
                Text(bannerText)
                    .font(.caption2)
                    .foregroundColor(.black.opacity(0.78))
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(red: 0.96, green: 0.74, blue: 0.25))
    }

    private var bannerText: String {
        let detail = viewModel.missingAssetsDetail
        if detail.isEmpty {
            return "\(viewModel.missingAssetsSummary) file(s) could not be found at their saved path."
        }
        return "\(viewModel.missingAssetsSummary) file(s) missing: \(detail)"
    }
}

private struct ProjectLauncherView: View {
    let onCreateProject: (String, ProjectResolutionPreset, CanvasOrientation) -> Void
    let onOpenProject: () -> Void

    @State private var projectName = ""
    @State private var resolutionPreset: ProjectResolutionPreset = .fullHD
    @State private var canvasOrientation: CanvasOrientation = .landscape

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Theme.backgroundDark,
                    Theme.panelBackground.opacity(0.95)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("VideoEditor")
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .foregroundColor(Theme.textMain)

                    Text("Start with a project. Resolution and canvas preset are fixed at project level and drive preview, timeline, and export.")
                        .font(.title3.weight(.medium))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: onOpenProject) {
                        Label("Open Existing Project", systemImage: "folder")
                            .font(.headline)
                            .foregroundColor(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(Theme.accentGreen)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 420, alignment: .leading)

                VStack(alignment: .leading, spacing: 18) {
                    Text("New Project")
                        .font(.title2.bold())
                        .foregroundColor(Theme.textMain)

                    launcherField(title: "Project Name") {
                        TextField("My project", text: $projectName)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Theme.backgroundDark.opacity(0.9))
                            .cornerRadius(10)
                            .foregroundColor(Theme.textMain)
                    }

                    launcherField(title: "Resolution") {
                        Picker("", selection: $resolutionPreset) {
                            ForEach(ProjectResolutionPreset.allCases) { preset in
                                Text(preset.fullLabel).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    launcherField(title: "Canvas") {
                        Picker("", selection: $canvasOrientation) {
                            ForEach(CanvasOrientation.allCases) { orientation in
                                Text(orientation.displayName).tag(orientation)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    HStack {
                        Text("Output")
                            .foregroundColor(Theme.textSecondary)
                        Spacer()
                        Text(outputSummary)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.accentGreen)
                    }

                    Button(action: startProject) {
                        Text("Start Project")
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.accentPink)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
                .padding(24)
                .frame(width: 440)
                .background(Theme.panelBackground.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Theme.separator.opacity(0.85), lineWidth: 1)
                )
                .cornerRadius(18)
            }
            .padding(36)
        }
    }

    private var outputSummary: String {
        let size = canvasOrientation.applied(to: resolutionPreset.baseLandscapeSize)
        return "\(canvasOrientation.displayName) • \(Int(size.width))x\(Int(size.height))"
    }

    private func startProject() {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmed.isEmpty ? "Untitled Project" : trimmed
        onCreateProject(resolvedName, resolutionPreset, canvasOrientation)
    }

    private func launcherField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(Theme.textSecondary)
            content()
        }
    }
}
