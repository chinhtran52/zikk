import SwiftUI
import AppKit
import SwiftData
import APIStore
import DesignSystem

/// Main window: sidebar with sections, tabbed workspace in the detail column.
public struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel
    @State private var workspace: Workspace?
    @State private var loadError: String?

    public init(services: AppServices) {
        _model = State(initialValue: AppModel(services: services))
    }

    public var body: some View {
        Group {
            if let workspace {
                NavigationSplitView {
                    SidebarView(workspace: workspace)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
                } detail: {
                    WorkspaceView(workspace: workspace)
                }
                .environment(model)
                .focusedSceneValue(\.appModel, model)
                .environment(\.codeEditorFontSize, CGFloat(model.services.settings.editorFontSize))
                .onChange(of: model.tabs.map(\.id)) { model.saveSession() }
                .onChange(of: model.selectedTabID) { model.saveSession() }
                .onChange(of: scenePhase) { if scenePhase != .active { model.saveSession() } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.saveSession() }

                .sheet(isPresented: $model.isShowingCookies) {
                    CookieManagerView()
                        .environment(model)
                }
                .sheet(isPresented: $model.isShowingImport) {
                    ImportView(workspace: workspace)
                        .environment(model)
                }
                .fileExporter(isPresented: Binding(get: { model.pendingExport != nil }, set: { if !$0 { model.pendingExport = nil } }),
                              document: model.pendingExport?.file, contentType: model.pendingExport?.file.contentType ?? .json, defaultFilename: model.pendingExport?.fileName) { _ in
                    model.pendingExport = nil
                }
                .sheet(item: $model.saveRequestTarget) { document in
                    SaveRequestSheet(document: document, workspace: workspace)
                        .environment(model)
                }
            } else if let loadError {
                ContentUnavailableView(L("Could not open workspace"), systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                let loaded = try StoreFactory.defaultWorkspace(in: context)
                model.attach(workspace: loaded, context: context)
                workspace = loaded
                model.restoreSession()
                CookieStore.load(into: model.services.cookieJar, context: context)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

extension RequestDocument: Identifiable {
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension FocusedValues {
    @Entry public var appModel: AppModel?
}
