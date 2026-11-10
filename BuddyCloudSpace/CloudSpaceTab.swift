import SwiftUI

struct CloudSpaceTab: View {
    @AppStorage(CloudSpaceConfiguration.defaultsKey) private var gatewayAddress = ""
    @Environment(\.openURL) private var openURL
    @State private var browser = CloudSpaceBrowser()
    @State private var showingConfiguration = false

    private var gatewayURL: URL? {
        try? CloudSpaceConfiguration.gatewayURL(from: gatewayAddress)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let gatewayURL {
                    gatewayContent(url: gatewayURL)
                } else {
                    setupContent
                }
            }
            .navigationTitle("CloudSpace")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("配置 gateway", systemImage: "slider.horizontal.3") {
                        showingConfiguration = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingConfiguration) {
            CloudSpaceConfigurationView(address: gatewayAddress) { address in
                gatewayAddress = address
            }
        }
        .onChange(of: gatewayAddress, initial: true) { _, address in
            browser.configure(address: address)
        }
    }

    private var setupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "externaldrive.badge.icloud")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("把 iCloud 带到云端工作区")
                        .font(.title2.bold())
                    Text("CloudSpace 连接你自己部署的 iCloud gateway，用于浏览文件和选择云端任务的工作目录。")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Label("1. 按开源文档部署 gateway", systemImage: "server.rack")
                    Text("在自己的服务器上完成 iCloud 授权、WebDAV 和 Tailscale 私网配置。Apple 账号和密码留在你自己的授权流程中。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Label("2. 在设备上连接 Tailscale", systemImage: "network")
                    Label("3. 填写 gateway 地址", systemImage: "link")
                }

                Button("配置已有 gateway", systemImage: "plus.circle") {
                    showingConfiguration = true
                }
                .buttonStyle(.borderedProminent)

                VStack(alignment: .leading, spacing: 12) {
                    Link(destination: CloudSpaceConfiguration.projectURL) {
                        Label("GitHub · Codex iCloud Workspace", systemImage: "arrow.up.right.square")
                    }
                    Link("查看完整部署方法", destination: CloudSpaceConfiguration.setupURL)
                }
                .font(.callout)
            }
            .padding(24)
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func gatewayContent(url: URL) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button("后退", systemImage: "chevron.left") { browser.goBack() }
                    .disabled(!browser.canGoBack)
                Button("前进", systemImage: "chevron.right") { browser.goForward() }
                    .disabled(!browser.canGoForward)
                Text(url.host ?? "gateway")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("重新载入", systemImage: "arrow.clockwise") { browser.reload() }
                Button("在浏览器打开", systemImage: "safari") { openURL(url) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
            ZStack(alignment: .top) {
                CloudSpaceBrowserView(browser: browser)
                    .opacity(browser.errorMessage == nil ? 1 : 0)

                if let errorMessage = browser.errorMessage {
                    ContentUnavailableView {
                        Label("暂时无法打开 gateway", systemImage: "network.slash")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试", systemImage: "arrow.clockwise") { browser.reload() }
                            .buttonStyle(.borderedProminent)
                        Button("在浏览器打开", systemImage: "safari") { openURL(url) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if browser.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .background(.regularMaterial, in: .capsule)
                        .padding(.top, 12)
                        .accessibilityLabel("正在载入 gateway")
                }
            }
        }
    }
}

private struct CloudSpaceConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    private let originalAddress: String
    let save: (String) -> Void

    init(address: String, save: @escaping (String) -> Void) {
        _address = State(initialValue: address)
        originalAddress = address
        self.save = save
    }

    private var validatedURL: URL? {
        try? CloudSpaceConfiguration.gatewayURL(from: address)
    }

    private var validationMessage: String? {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try CloudSpaceConfiguration.gatewayURL(from: address)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    addressField
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("gateway 地址")
                } footer: {
                    Text("只填写网页地址。认证由 gateway 自身处理；私有 gateway 需要先连接 Tailscale。地址保存在当前设备。")
                }

                Section {
                    Link("GitHub 开源项目", destination: CloudSpaceConfiguration.projectURL)
                    Link("部署与配置方法", destination: CloudSpaceConfiguration.setupURL)
                }

                if !originalAddress.isEmpty {
                    Section {
                        Button("清除 gateway 配置", role: .destructive) {
                            save("")
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("CloudSpace 配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let validatedURL else { return }
                        save(validatedURL.absoluteString)
                        dismiss()
                    }
                    .disabled(validatedURL == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 360)
        #endif
    }

    private var addressField: some View {
        TextField("https://gateway.example.ts.net/", text: $address)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
    }
}
