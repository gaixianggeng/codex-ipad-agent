import XCTest

final class MimiRemotePhysicalSmokeUITests: XCTestCase {
    private var app: XCUIApplication!
    private let selectedValues = ["Selected", "已选择"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // 使用只存在于 Debug 构建的内存样例，保证新安装、无真实历史数据的设备也能
        // 完整覆盖 Composer；不会写入或替换用户保存的连接和会话。
        app.launchArguments += [
            "--debug-skip-pairing",
            "--debug-seed-ui"
        ]
        if name.contains("testMCPToolApprovalShowsScopedTrustActions") {
            app.launchArguments.append("--debug-seed-mcp-approval-ui")
        }
        if name.contains("testWideIPadFloatingSidebarDragDoesNotStealSessionRowGestures") {
            // 13-inch iPad 竖屏仍是 regular width，同时避开横屏自由窗口对屏幕左缘拖动的系统仲裁。
            XCUIDevice.shared.orientation = .portrait
        }
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 25),
            "MimiRemote 未能在真机前台启动"
        )
    }

    override func tearDownWithError() throws {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name)-final"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // 设备方向属于跨测试共享状态。每个用例结束时恢复竖屏，避免一个旋转用例
        // 改变下一个用例的导航层级和可点击区域。
        XCUIDevice.shared.orientation = .portrait
        app = nil
    }

    func testLaunchAndQRScannerCanBePresentedRepeatedly() throws {
        XCTAssertGreaterThan(app.windows.count, 0, "启动后应存在可交互窗口")

        try openHostInstaller()
        assertHostInstallerSupportsMacAndWindows()

        try presentQRScanner()
        assertScannerRemainsPresented()
        app.descendant(identifier: "qrScanner.close").tap()
        XCTAssertTrue(
            app.descendant(identifier: "qrScanner.close").waitForNonExistence(timeout: 8),
            "关闭扫码页后应回到连接设置"
        )

        try presentQRScanner()
        assertScannerRemainsPresented()
        app.descendant(identifier: "qrScanner.close").tap()
    }

    private func openHostInstaller() throws {
        try enterWorkbenchIfNeeded()
        try openSettings()

        let connection = app.descendant(identifier: "settings.connectionManagement")
        XCTAssertTrue(scrollUntilHittable(connection), "设置页应提供电脑连接管理入口")
        connection.tap()

        XCTAssertTrue(
            app.descendant(identifier: "settings.hostInstaller.platform").waitForExistence(timeout: 8),
            "未配对时连接管理页应展示电脑平台选择器"
        )
    }

    private func assertHostInstallerSupportsMacAndWindows() {
        let platformPicker = app.descendant(identifier: "settings.hostInstaller.platform")
        let mac = platformPicker.buttons["Mac"]
        let windows = platformPicker.buttons["Windows"]

        XCTAssertTrue(mac.waitForExistence(timeout: 4), "安装入口应提供 Mac 选项")
        XCTAssertTrue(windows.waitForExistence(timeout: 4), "安装入口应提供 Windows 选项")

        windows.tap()
        XCTAssertTrue(
            waitUntilLabelContains(
                app.descendant(identifier: "settings.hostInstaller.installationDetail"),
                text: "Windows"
            ),
            "切换后应展示 Windows 安装说明"
        )
        XCTAssertTrue(
            app.descendant(identifier: "settings.hostInstaller.githubRelease").exists,
            "Windows 安装入口应继续提供 GitHub Releases"
        )
        XCTAssertTrue(
            app.descendant(identifier: "settings.hostInstaller.share").exists,
            "Windows 安装入口应支持分享下载链接"
        )

        mac.tap()
        XCTAssertTrue(
            waitUntilLabelContains(
                app.descendant(identifier: "settings.hostInstaller.installationDetail"),
                text: "Mac"
            ),
            "切回后应展示 Mac 安装说明"
        )
    }

    func testWideIPadFloatingSidebarSurfaceKeepsNavigationUsable() throws {
        rotate(to: .landscapeLeft)

        if firstExistingButton(
            labels: ["收起会话列表", "Collapse conversation list"],
            timeout: 3
        ) == nil,
           let showSidebar = firstExistingButton(
               labels: ["显示边栏", "Show Sidebar"],
               timeout: 5
           ) {
            showSidebar.tap()
        }

        guard let collapseSidebar = firstExistingButton(
            labels: ["收起会话列表", "Collapse conversation list"],
            timeout: 8
        ) else {
            XCTFail("iPad 浮动侧栏应提供可访问的收起按钮")
            return
        }
        XCTAssertTrue(
            app.descendant(identifier: "hostSwitcher.menu").waitForExistence(timeout: 8),
            "浮动侧栏应保留电脑切换入口"
        )
        assertMinimumTouchTarget(collapseSidebar, named: "浮动侧栏收起按钮")

        let sessionFilter = app.descendant(identifier: "sessions.filter")
        if sessionFilter.waitForExistence(timeout: 5) {
            XCTAssertGreaterThanOrEqual(
                sessionFilter.frame.minX,
                collapseSidebar.frame.maxX,
                "详情页 leading 工具栏不能被浮动侧栏覆盖"
            )
        }

        guard let workspaces = firstExistingButton(
            labels: ["工作区", "Workspace"],
            timeout: 5
        ) else {
            XCTFail("浮动侧栏应保留工作区入口")
            return
        }
        workspaces.tap()
        let workspaceBrowser = app.descendant(identifier: "workspace.browser")
        XCTAssertTrue(
            workspaceBrowser.waitForExistence(timeout: 8),
            "工作区主内容应保持可访问"
        )
        XCTAssertGreaterThanOrEqual(
            workspaceBrowser.frame.minX,
            collapseSidebar.frame.maxX,
            "展开侧栏后工作区必须获得真实的右侧布局区域，不能只裁切原始整屏内容"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "MIM-41-iPad-floating-sidebar-landscape"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        collapseSidebar.tap()
        guard let showSidebar = firstExistingButton(
            labels: ["显示边栏", "Show Sidebar"],
            timeout: 8
        ) else {
            XCTFail("收起浮动侧栏后应保留原生显示边栏入口")
            return
        }
        assertMinimumTouchTarget(showSidebar, named: "浮动侧栏显示按钮")
        showSidebar.tap()
        guard firstExistingButton(
            labels: ["收起会话列表", "Collapse conversation list"],
            timeout: 8
        ) != nil else {
            XCTFail("重新展开侧栏后导航与选择状态应保持可用")
            return
        }
    }

    func testInspectorPresentationSurvivesIPadRotation() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Inspector 的 sheet / attached 切换只在 iPad 验收。"
        )
        rotate(to: .portrait)
        try openComposerIfNeeded()

        let inspectorButton = app.descendant(identifier: "sessionDetail.inspector")
        XCTAssertTrue(inspectorButton.waitForExistence(timeout: 10), "中等宽度应展示独立 Inspector 入口")
        inspectorButton.tap()

        let inspectorContent = app.descendant(identifier: "sessionInspector.content")
        XCTAssertTrue(inspectorContent.waitForExistence(timeout: 10), "竖屏中等宽度应打开 Inspector Sheet")

        rotate(to: .landscapeLeft)
        XCTAssertTrue(inspectorContent.waitForExistence(timeout: 10), "旋转后 Inspector 内容不应丢失")

        rotate(to: .portrait)
        XCTAssertTrue(inspectorContent.waitForExistence(timeout: 10), "返回中等宽度后 Inspector 应保持展示")

        let closeButton = app.descendant(identifier: "sessionDetail.inspector")
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Inspector 展示期间应保留同一工具栏入口")
        closeButton.tap()
        XCTAssertTrue(inspectorContent.waitForNonExistence(timeout: 10), "关闭后不应残留 Sheet 或 attached Inspector")
    }

    func testWideIPadFloatingSidebarDragDoesNotStealSessionRowGestures() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "浮动侧栏拖动只在 iPad regular width 下验收。"
        )
        try enterWorkbenchIfNeeded()

        if firstExistingButton(
            labels: ["收起会话列表", "Collapse conversation list"],
            timeout: 3
        ) == nil,
           let showSidebar = firstExistingButton(
               labels: ["显示边栏", "Show Sidebar"],
               timeout: 5
           ) {
            showSidebar.tap()
        }

        guard let collapseSidebar = firstExistingButton(
            labels: ["收起会话列表", "Collapse conversation list"],
            timeout: 8
        ) else {
            return XCTFail("iPad 浮动侧栏应先处于展开态")
        }
        let identifiedSessionRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sessions.row."))
        let seededSessionRows = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ OR label CONTAINS %@",
                "mimi-remote",
                "sample-app"
            )
        )
        // SwiftUI 在部分系统版本会把 row 合并为整行 Button，而不透传子视图 identifier。
        // 优先使用稳定 identifier；Debug 样例下回退到已知工作区标签，避免把定位器缺失误报成功能失败。
        let sessionRow = identifiedSessionRows.firstMatch.exists
            ? identifiedSessionRows.firstMatch
            : seededSessionRows.firstMatch
        guard sessionRow.waitForExistence(timeout: 12) else {
            return XCTFail("Debug 样例应提供可交互的会话 row")
        }

        let sidebarTrailingX = collapseSidebar.frame.maxX
        sessionRow.swipeUp()
        XCTAssertEqual(
            collapseSidebar.frame.maxX,
            sidebarTrailingX,
            accuracy: 2,
            "纵向列表手势不得改变侧栏 progress"
        )
        sessionRow.swipeLeft()
        XCTAssertEqual(
            collapseSidebar.frame.maxX,
            sidebarTrailingX,
            accuracy: 2,
            "row 横向 swipe 不得被侧栏拖动 recognizer 接管"
        )

        let window = app.windows.firstMatch
        let width = max(window.frame.width, 1)
        let closeStart = window.coordinate(
            // 300pt 列内扣除 12pt surface outer inset 后，22pt 拖动带中心是 x=277。
            withNormalizedOffset: CGVector(dx: 277 / width, dy: 0.5)
        )
        let closeEnd = window.coordinate(
            withNormalizedOffset: CGVector(dx: 12 / width, dy: 0.5)
        )
        closeStart.press(forDuration: 0.1, thenDragTo: closeEnd)
        guard firstExistingButton(
            labels: ["显示边栏", "Show Sidebar"],
            timeout: 8
        ) != nil else {
            return XCTFail("trailing 22pt 拖动带关闭后应显示等价的展开按钮")
        }

        let height = max(window.frame.height, 1)
        let protectedZoneOpenEndX = 310 / width
        let protectedY = CGFloat(65)
        let protectedStart = window.coordinate(
            // 65pt 仍严格位于顶部 72pt 保护区内，同时避开 reveal 按钮和系统极端顶缘。
            withNormalizedOffset: CGVector(dx: 1 / width, dy: protectedY / height)
        )
        let protectedEnd = window.coordinate(
            withNormalizedOffset: CGVector(dx: protectedZoneOpenEndX, dy: protectedY / height)
        )
        protectedStart.press(forDuration: 0.1, thenDragTo: protectedEnd)
        guard firstExistingButton(
            labels: ["显示边栏", "Show Sidebar"],
            timeout: 2
        ) != nil else {
            return XCTFail("leading edge 顶部 72pt 保护区不得触发侧栏重开")
        }
        // 底部 72pt 会被 iPadOS 窗口管理器优先接管并改变窗口几何；对应拒绝边界由纯布局测试覆盖。

        let openStart = window.coordinate(
            // 20pt 仍位于应用的 leading 22pt 命中带内，同时避开 iPadOS 绝对屏幕边缘仲裁。
            withNormalizedOffset: CGVector(dx: 20 / width, dy: 0.5)
        )
        let openEnd = window.coordinate(
            withNormalizedOffset: CGVector(dx: 310 / width, dy: 0.5)
        )
        openStart.press(forDuration: 0.1, thenDragTo: openEnd)

        let collapseSidebarLabels = ["收起会话列表", "Collapse conversation list"]
        guard firstExistingButton(
            labels: collapseSidebarLabels,
            timeout: 8
        ) != nil else {
            return XCTFail("leading 22pt edge 应能直接重新展开侧栏")
        }
        XCTAssertTrue(
            waitForFreshButtonHorizontalPosition(
                labels: collapseSidebarLabels,
                maxX: sidebarTrailingX,
                accuracy: 2
            ),
            "重新展开后侧栏应回到原始展开位置"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "MIM-72-iPad-sidebar-drag-row-competition"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testVoiceProviderInlineSelectionSurvivesRotation() throws {
        try enterWorkbenchIfNeeded()
        try openSettings()

        let voiceInput = app.descendant(identifier: "settings.voiceInput")
        XCTAssertTrue(scrollUntilHittable(voiceInput), "设置页应提供语音输入入口")
        let originalValue = "\(voiceInput.value ?? "")"
        let originalProviderWasOnDevice =
            originalValue.contains("On-device") || originalValue.contains("设备端")

        voiceInput.tap()

        guard let codex = firstExistingButton(labels: ["Codex"], timeout: 5) else {
            XCTFail("语音输入行应直接弹出提供方选择菜单")
            return
        }
        codex.tap()
        XCTAssertTrue(
            waitForControlValue(voiceInput, containing: ["Codex"]),
            "在弹出菜单选择 Codex 后应立即保存设备级偏好"
        )

        rotate(to: .landscapeLeft)
        let landscapeVoiceInput = app.descendant(identifier: "settings.voiceInput")
        XCTAssertTrue(
            scrollUntilHittable(landscapeVoiceInput),
            "横屏后应仍能找到语音输入选择组件"
        )
        XCTAssertTrue(
            waitForControlValue(landscapeVoiceInput, containing: ["Codex"]),
            "横屏后语音输入选择不应丢失"
        )

        rotate(to: .portrait)
        let portraitVoiceInput = app.descendant(identifier: "settings.voiceInput")
        XCTAssertTrue(
            scrollUntilHittable(portraitVoiceInput),
            "竖屏后应仍能找到语音输入选择组件"
        )
        XCTAssertTrue(
            waitForControlValue(portraitVoiceInput, containing: ["Codex"]),
            "竖屏后语音输入选择不应丢失"
        )

        if originalProviderWasOnDevice {
            portraitVoiceInput.tap()
            guard let onDevice = firstExistingButton(
                labels: ["On-device", "设备端"],
                timeout: 5
            ) else {
                XCTFail("测试结束时应能从同一弹出菜单恢复设备端语音")
                return
            }
            onDevice.tap()
            XCTAssertTrue(
                waitForControlValue(
                    portraitVoiceInput,
                    containing: ["On-device", "设备端"]
                ),
                "测试结束时应恢复原语音提供方"
            )
        }
    }

    func testMePageCombinesQuotaActivityPreferencesAndMore() throws {
        try enterWorkbenchIfNeeded()
        try openSettings()

        let tokenUsage = app.descendant(identifier: "settings.tokenUsage")
        let tokenQuota = app.descendant(identifier: "settings.tokenUsage.quota")
        let tokenActivity = app.descendant(identifier: "settings.tokenUsage.activity")
        let activityGrid = app.descendant(identifier: "settings.tokenActivity.grid")
        let activityUnavailable = app.descendant(identifier: "settings.tokenActivity.unavailable")
        let macDevices = app.descendant(identifier: "settings.connectionManagement")
        let appearance = app.descendant(identifier: "settings.appearance")
        let language = app.descendant(identifier: "settings.language")
        let voiceInput = app.descendant(identifier: "settings.voiceInput")
        let defaultPermissions = app.descendant(identifier: "settings.defaultPermissions")
        let diagnostics = app.descendant(identifier: "settings.diagnostics")
        let advanced = app.descendant(identifier: "settings.advancedDevelopment")
        let aboutLegal = app.descendant(identifier: "settings.aboutLegal")

        XCTAssertTrue(tokenUsage.waitForExistence(timeout: 8), "我的页面应展示统一 Token 模块")
        XCTAssertTrue(tokenQuota.waitForExistence(timeout: 4), "Token 模块应展示当前剩余列")
        XCTAssertTrue(tokenActivity.waitForExistence(timeout: 4), "Token 模块应展示活动列")
        XCTAssertTrue(
            activityGrid.waitForExistence(timeout: 4)
                || activityUnavailable.waitForExistence(timeout: 1),
            "Token 模块应展示真实点格数据或诚实的不可用状态"
        )
        XCTAssertTrue(macDevices.waitForExistence(timeout: 4), "设置页应展示 Mac 多设备入口")
        XCTAssertTrue(appearance.waitForExistence(timeout: 4), "设置页应展示偏好设置")

        XCTAssertGreaterThanOrEqual(tokenUsage.frame.height, 150, "Token 模块应完整容纳圆环与点格图")
        XCTAssertGreaterThan(tokenUsage.frame.width, 250, "Token 模块应使用完整分组宽度")
        XCTAssertLessThan(tokenQuota.frame.midX, tokenActivity.frame.midX, "当前剩余应稳定位于活动列左侧")
        XCTAssertLessThan(tokenQuota.frame.minX, tokenActivity.frame.minX, "Token 两个主模块不得回退为上下堆叠")
        XCTAssertEqual(macDevices.frame.height, 52, accuracy: 1, "Mac 与设备应保持标准行高")
        XCTAssertEqual(appearance.frame.height, 52, accuracy: 1, "偏好项应保持标准行高")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "me-token-usage-overview"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertTrue(
            scrollUntilHittable(language, maximumSwipes: 4),
            "我的页面应能滚动到语言入口"
        )
        XCTAssertEqual(language.frame.height, 52, accuracy: 1, "语言行应保持标准行高")

        XCTAssertTrue(
            scrollUntilHittable(defaultPermissions, maximumSwipes: 6),
            "设置页应能滚动到默认权限行内选择器"
        )
        XCTAssertTrue(voiceInput.exists, "设置页应展示语音行内选择器")
        XCTAssertEqual(voiceInput.frame.height, 52, accuracy: 1, "语音输入行应保持标准行高")
        XCTAssertEqual(defaultPermissions.frame.height, 52, accuracy: 1, "默认权限行应保持标准行高")

        XCTAssertTrue(scrollUntilHittable(aboutLegal), "我的页面应能滚动到“更多”分区")
        // “Mac 与设备”已在页面顶部验证；滚到底部后它可能被 List 懒加载卸载，
        // 这里只检查当前可见的“更多”入口，避免把视口状态误判为功能缺失。
        let bottomRows = [diagnostics, advanced, aboutLegal]
        for row in bottomRows {
            XCTAssertTrue(row.waitForExistence(timeout: 4), "“更多”分区入口应存在")
            XCTAssertEqual(
                row.frame.height,
                52,
                accuracy: 1,
                "“更多”分区应统一使用标准行高"
            )
        }

        let bottomScreenshot = XCTAttachment(screenshot: app.screenshot())
        bottomScreenshot.name = "me-preferences-and-more"
        bottomScreenshot.lifetime = .keepAlways
        add(bottomScreenshot)
    }

    func testComposerPlanGoalAndModelMenusSurviveRotationWithoutCrash() throws {
        try openComposerIfNeeded()

        try selectMode(identifier: "composer.mode.plan")
        rotate(to: .landscapeLeft)
        assertModeSelected(expectedValues: ["planning mode", "计划模式"])
        try selectMode(identifier: "composer.mode.plan")

        try selectMode(identifier: "composer.mode.goal")
        rotate(to: .portrait)
        assertModeSelected(expectedValues: ["Goal mode", "目标模式"])

        let model = app.descendant(identifier: "composer.model")
        XCTAssertTrue(model.waitForExistence(timeout: 10), "Composer 应展示模型入口")
        model.tap()
        XCTAssertTrue(
            app.descendant(identifier: "composer.modelPicker").waitForExistence(timeout: 8),
            "模型选择浮层应能正常构建，不能触发 compact toolbar 栈溢出"
        )
        dismissPresentedMenuOrPopover()
        XCTAssertEqual(app.state, .runningForeground, "完成紧凑工具栏操作后 App 应保持前台运行")
    }

    func testMCPToolApprovalShowsScopedTrustActions() throws {
        try openComposerIfNeeded()

        let approveOnce = app.descendant(identifier: "approval.approveOnce")
        let allowForSession = app.descendant(identifier: "approval.allowMCPForSession")
        let alwaysAllow = app.descendant(identifier: "approval.alwaysAllowMCPTool")
        let reject = app.descendant(identifier: "approval.reject")

        XCTAssertTrue(approveOnce.waitForExistence(timeout: 12), "MCP 工具审批应保留单次允许入口")
        XCTAssertTrue(allowForSession.waitForExistence(timeout: 5), "Codex 声明 session 持久化后应展示本次会话允许")
        XCTAssertTrue(alwaysAllow.waitForExistence(timeout: 5), "Codex 声明 always 持久化后应展示始终允许")
        XCTAssertTrue(reject.waitForExistence(timeout: 5), "MCP 工具审批应始终允许拒绝")

        assertMinimumTouchTarget(approveOnce, named: "单次允许")
        assertMinimumTouchTarget(allowForSession, named: "本次会话允许")
        assertMinimumTouchTarget(alwaysAllow, named: "始终允许")
        assertMinimumTouchTarget(reject, named: "拒绝")
        XCTAssertEqual(app.state, .runningForeground, "展示完整 MCP 信任选项后 App 应保持前台运行")
    }

    func testComposerCameraAttachmentCanPresentAndCancel() throws {
        try openComposerIfNeeded()

        let addContent = app.descendant(identifier: "composer.addContent")
        XCTAssertTrue(addContent.waitForExistence(timeout: 10), "Composer 应保留原位置的加号入口")
        assertMinimumTouchTarget(addContent, named: "加号")
        addContent.tap()

        let file = app.descendant(identifier: "composer.addContent.file")
        let camera = app.descendant(identifier: "composer.addContent.camera")
        let photos = app.descendant(identifier: "composer.addContent.photos")
        XCTAssertTrue(file.waitForExistence(timeout: 8), "添加内容面板应展示文件入口")
        XCTAssertTrue(camera.waitForExistence(timeout: 8), "添加内容面板应展示适合触控的相机入口")
        XCTAssertTrue(photos.waitForExistence(timeout: 8), "添加内容面板应展示照片入口")
        assertMinimumTouchTarget(file, named: "文件入口")
        assertMinimumTouchTarget(camera, named: "相机入口")
        assertMinimumTouchTarget(photos, named: "照片入口")

        installCameraPermissionMonitor()
        camera.tap()
        handleCameraPermissionIfPresented()

        let choosePhotos = firstExistingButton(labels: ["Choose Photos", "选择照片"], timeout: 2)
        if choosePhotos != nil {
            throw XCTSkip("当前设备已拒绝或限制相机权限；已验证降级提示，跳过系统相机取消操作")
        }

        let picker = app.descendant(identifier: "composer.cameraAttachmentPicker")
        let cancel = firstExistingButton(labels: ["Cancel", "取消"], timeout: 15)
        let pickerIsPresented = picker.exists || cancel != nil

        XCTAssertTrue(pickerIsPresented, "点击相机后应稳定展示系统相机界面")
        guard let cancel else {
            XCTFail("系统相机界面应提供取消按钮")
            return
        }
        cancel.tap()

        XCTAssertTrue(
            addContent.waitForExistence(timeout: 12),
            "取消拍摄后应回到 Composer，且加号位置保持不变"
        )
        XCTAssertEqual(app.state, .runningForeground, "取消拍摄后 App 应保持前台运行")
    }

    func testComposerFileImporterCanPresentAndCancel() throws {
        try openComposerIfNeeded()

        let addContent = app.descendant(identifier: "composer.addContent")
        XCTAssertTrue(addContent.waitForExistence(timeout: 10), "Composer 应保留原位置的加号入口")
        addContent.tap()

        let file = app.descendant(identifier: "composer.addContent.file")
        XCTAssertTrue(file.waitForExistence(timeout: 8), "添加内容面板应展示文件入口")
        assertMinimumTouchTarget(file, named: "文件入口")
        file.tap()

        guard let cancel = firstExistingButton(labels: ["Cancel", "取消"], timeout: 15) else {
            XCTFail("系统文件选择器应提供取消按钮")
            return
        }
        cancel.tap()

        XCTAssertTrue(
            addContent.waitForExistence(timeout: 12),
            "取消文件选择后应回到 Composer，且加号位置保持不变"
        )
        XCTAssertEqual(app.state, .runningForeground, "取消文件选择后 App 应保持前台运行")
    }

    func testComposerSkillPickerSupportsImmediateMultiSelectFromBothEntrances() throws {
        try openComposerIfNeeded()

        let addContent = app.descendant(identifier: "composer.addContent")
        XCTAssertTrue(addContent.waitForExistence(timeout: 10), "Composer 应展示加号入口")
        addContent.tap()

        let addContentSkill = app.descendant(identifier: "composer.addContent.skills")
        XCTAssertTrue(addContentSkill.waitForExistence(timeout: 8), "添加内容面板应展示 Skill 入口")
        addContentSkill.tap()

        let imagegen = app.descendant(identifier: "composer.skillPicker.row.imagegen")
        let swiftUI = app.descendant(identifier: "composer.skillPicker.row.swiftui-ui-patterns")
        let done = app.descendant(identifier: "composer.skillPicker.done")
        XCTAssertTrue(imagegen.waitForExistence(timeout: 8), "统一 Skill 面板应展示固定调试数据")
        XCTAssertTrue(swiftUI.waitForExistence(timeout: 4))
        XCTAssertTrue(done.waitForExistence(timeout: 4))
        assertMinimumTouchTarget(imagegen, named: "Skill 行")
        assertMinimumTouchTarget(done, named: "完成按钮")

        imagegen.tap()
        XCTAssertTrue(waitUntilSelected(imagegen), "勾选 Skill 后应立即生效")
        swiftUI.tap()
        XCTAssertTrue(waitUntilSelected(swiftUI), "同一面板应支持连续多选")
        imagegen.tap()
        XCTAssertTrue(waitUntilNotSelected(imagegen), "再次点击已选 Skill 应立即取消")
        done.tap()

        XCTAssertTrue(
            app.descendant(identifier: "composer.skillAttachment.swiftui-ui-patterns")
                .waitForExistence(timeout: 8),
            "完成关闭面板后，当前勾选应保留到附件条"
        )
        XCTAssertFalse(
            app.descendant(identifier: "composer.skillAttachment.imagegen").exists,
            "已经取消的 Skill 不应留在附件条"
        )

        // iPad 保留输入框上方的快捷入口；iPhone 设计上只通过加号进入。
        // 若当前布局有快捷入口，复用同一组行和即时多选语义再验证一次。
        let directSkill = app.descendant(identifier: "composer.skill")
        if directSkill.waitForExistence(timeout: 2), directSkill.isHittable {
            directSkill.tap()
            let directImagegen = app.descendant(identifier: "composer.skillPicker.row.imagegen")
            let directSwiftUI = app.descendant(identifier: "composer.skillPicker.row.swiftui-ui-patterns")
            XCTAssertTrue(directImagegen.waitForExistence(timeout: 8))
            XCTAssertTrue(waitUntilSelected(directSwiftUI), "两个入口必须读取同一组选中状态")
            directImagegen.tap()
            XCTAssertTrue(waitUntilSelected(directImagegen))
            app.descendant(identifier: "composer.skillPicker.done").tap()
            XCTAssertTrue(
                app.descendant(identifier: "composer.skillAttachment.imagegen")
                    .waitForExistence(timeout: 8),
                "快捷入口的选择也应写入同一附件条"
            )
        }

        XCTAssertEqual(app.state, .runningForeground, "连续选择和取消 Skill 后 App 应保持前台运行")
    }

    func testWorkspaceCharacterIconsRenderAndPickerCanOpen() throws {
        // 角色图测试直接进入目标页，避免真机上恢复路由与底部栏布局差异造成误报。
        app.terminate()
        app.launchArguments.append("--debug-open-workspaces")
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 25),
            "MimiRemote 应能直接进入工作区"
        )

        let iconButtons = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.card.icon."))
        XCTAssertTrue(
            iconButtons.firstMatch.waitForExistence(timeout: 15),
            "工作区卡片应展示可更换的《西游记》角色头像"
        )
        assertMinimumTouchTarget(iconButtons.firstMatch, named: "工作区角色头像")

        let workspaceScreenshot = XCTAttachment(screenshot: app.screenshot())
        workspaceScreenshot.name = "workspace-character-cards"
        workspaceScreenshot.lifetime = .keepAlways
        add(workspaceScreenshot)

        iconButtons.firstMatch.tap()
        let picker = app.descendant(identifier: "workspace.characterPicker")
        XCTAssertTrue(
            picker.waitForExistence(timeout: 10),
            "点击头像后应打开角色选择器"
        )

        let characterButtons = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.character."))
        XCTAssertEqual(characterButtons.count, 20, "角色选择器应完整展示 20 个角色")
        assertMinimumTouchTarget(characterButtons.firstMatch, named: "角色选择按钮")

        let pickerScreenshot = XCTAttachment(screenshot: app.screenshot())
        pickerScreenshot.name = "workspace-character-picker"
        pickerScreenshot.lifetime = .keepAlways
        add(pickerScreenshot)
    }

    func testWorkspaceRemoveDirectoryConfirmationAnchorsToCardAcrossIPadLayouts() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "目录移除确认的 popover 锚点只在 iPad regular width 下验收。"
        )
        try relaunchDirectlyIntoWorkspaces()

        let projectID = "debug-sample-app"
        for (orientation, attachmentName) in [
            (UIDeviceOrientation.landscapeLeft, "landscape-sidebar"),
            (.portrait, "portrait")
        ] {
            rotate(to: orientation)

            let source = app.descendant(identifier: "workspace.card.actions.\(projectID)")
            XCTAssertTrue(source.waitForExistence(timeout: 10), "旋转后工作区卡片操作入口应保持可见")
            assertMinimumTouchTarget(source, named: "工作区卡片操作入口")
            source.tap()

            let request = app.descendant(identifier: "workspace.remove.request.\(projectID)")
            XCTAssertTrue(request.waitForExistence(timeout: 6), "卡片菜单应提供移除目录入口")
            request.tap()

            let confirmation = app.descendant(identifier: "workspace.remove.confirm.\(projectID)")
            XCTAssertTrue(confirmation.waitForExistence(timeout: 8), "移除目录后应展示系统确认弹窗")
            assertPopover(confirmation, isAnchoredNear: source)

            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "workspace-remove-confirmation-\(attachmentName)"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            dismissPresentedMenuOrPopover()
            XCTAssertTrue(
                confirmation.waitForNonExistence(timeout: 6),
                "点击弹窗外部应取消移除并关闭确认弹窗"
            )
            XCTAssertTrue(source.exists, "取消后工作区仍应保留在列表中")
        }

        let source = app.descendant(identifier: "workspace.card.actions.\(projectID)")
        source.tap()
        let request = app.descendant(identifier: "workspace.remove.request.\(projectID)")
        XCTAssertTrue(request.waitForExistence(timeout: 6))
        request.tap()
        let confirmation = app.descendant(identifier: "workspace.remove.confirm.\(projectID)")
        XCTAssertTrue(confirmation.waitForExistence(timeout: 8))
        confirmation.tap()

        XCTAssertTrue(
            source.waitForNonExistence(timeout: 8),
            "确认后只应从当前工作区列表移除 Debug 样例目录"
        )
    }

    func testWorkspaceIconStyleSwitchesBetweenEmojiAndJourney() throws {
        // 直接进入工作区，避免恢复到会话详情时底部设置入口不在可访问性树中。
        app.terminate()
        app.launchArguments.append("--debug-open-workspaces")
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 25),
            "MimiRemote 应能直接进入工作区"
        )

        try enterWorkbenchIfNeeded()
        try openWorkspaceAppearanceSettings()

        let picker = app.descendant(identifier: "settings.workspaceIconStyle")
        XCTAssertTrue(picker.waitForExistence(timeout: 8), "外观设置应展示工作区图标风格")
        assertMinimumTouchTarget(picker, named: "工作区图标风格")

        let expectedStyleIdentifiers = [
            "journey",
            "threeKingdoms",
            "waterMargin",
            "redChamber",
            "onePiece",
            "naruto",
            "digimon",
            "emoji"
        ]
        var optionFrames: [CGRect] = []
        for styleID in expectedStyleIdentifiers {
            let option = app.descendant(
                identifier: "settings.workspaceIconStyle.option.\(styleID)"
            )
            XCTAssertTrue(
                option.waitForExistence(timeout: 5),
                "工作区图标风格应展示 \(styleID)"
            )
            assertMinimumTouchTarget(option, named: "\(styleID) 风格选项")
            optionFrames.append(option.frame)
        }
        assertWorkspaceStyleGridUsesFourColumns(optionFrames)

        guard firstExistingButton(
            labels: ["西游记", "Journey to the West"],
            timeout: 5
        ) != nil, let emoji = firstExistingButton(labels: ["Emoji"], timeout: 5) else {
            XCTFail("工作区图标风格应同时提供《西游记》和 Emoji")
            return
        }
        let originallyUsedEmoji = isSelected(emoji)

        emoji.tap()
        XCTAssertTrue(waitUntilSelected(emoji), "选择 Emoji 后应立即保存")
        try relaunchDirectlyIntoWorkspaces()
        XCTAssertTrue(
            currentWorkspaceIconLabelContainsEmoji(),
            "切换到 Emoji 后，工作区卡片应立即恢复 Emoji 图标"
        )

        try openWorkspaceAppearanceSettings()
        guard let currentJourney = firstExistingButton(
            labels: ["西游记", "Journey to the West"],
            timeout: 5
        ) else {
            XCTFail("重新进入设置后应仍能找到《西游记》选项")
            return
        }
        currentJourney.tap()
        XCTAssertTrue(waitUntilSelected(currentJourney), "选择《西游记》后应立即保存")
        try relaunchDirectlyIntoWorkspaces()
        XCTAssertFalse(
            currentWorkspaceIconLabelContainsEmoji(),
            "切回《西游记》后，工作区卡片不应继续显示 Emoji"
        )

        // 真机测试不应永久改变用户原来的视觉偏好。
        if originallyUsedEmoji {
            try openWorkspaceAppearanceSettings()
            guard let originalEmoji = firstExistingButton(labels: ["Emoji"], timeout: 5) else {
                XCTFail("测试结束时应能恢复 Emoji 偏好")
                return
            }
            originalEmoji.tap()
            XCTAssertTrue(waitUntilSelected(originalEmoji), "测试结束时应恢复原 Emoji 偏好")
        }
    }

    private func assertWorkspaceStyleGridUsesFourColumns(_ frames: [CGRect]) {
        XCTAssertEqual(frames.count, 8)
        guard frames.count == 8 else { return }

        let firstRowY = frames[0].midY
        let secondRowY = frames[4].midY
        for frame in frames.prefix(4) {
            XCTAssertEqual(frame.midY, firstRowY, accuracy: 2, "前四个风格应位于第一排")
        }
        for frame in frames.suffix(4) {
            XCTAssertEqual(frame.midY, secondRowY, accuracy: 2, "后四个风格应位于第二排")
        }
        XCTAssertGreaterThan(secondRowY - firstRowY, 44, "两排风格不应重叠")
    }

    private func presentQRScanner() throws {
        installCameraPermissionMonitor()

        // 扫码页关闭后会回到连接管理页。优先复用当前页面的入口，避免为了第二次
        // 拉起扫码器又退回工作台并重新进入设置，降低实体机导航差异带来的误报。
        let currentConnectionScan = app.descendant(identifier: "settings.connection.scanQRCode")
        let firstSetupScan = app.descendant(identifier: "settings.hostInstaller.scan")
        if currentConnectionScan.exists, currentConnectionScan.isHittable {
            currentConnectionScan.tap()
        } else if firstSetupScan.exists, firstSetupScan.isHittable {
            firstSetupScan.tap()
        } else {
            try enterWorkbenchIfNeeded()
            try openSettings()
            let connection = app.descendant(identifier: "settings.connectionManagement")
            XCTAssertTrue(scrollUntilHittable(connection), "设置页应提供 Mac 连接管理入口")
            connection.tap()
            let scan = app.descendant(identifier: "settings.connection.scanQRCode")
            let setupScan = app.descendant(identifier: "settings.hostInstaller.scan")
            if scrollUntilHittable(scan, maximumSwipes: 4) {
                scan.tap()
            } else {
                XCTAssertTrue(scrollUntilHittable(setupScan), "连接管理页应提供二维码扫码入口")
                setupScan.tap()
            }
        }

        handleCameraPermissionIfPresented()
        XCTAssertTrue(
            app.descendant(identifier: "qrScanner.close").waitForExistence(timeout: 15),
            "首次点击扫码后扫码页应保持展示，不能拉起相机后立刻收回"
        )
    }

    private func assertScannerRemainsPresented() {
        let close = app.descendant(identifier: "qrScanner.close")
        let disappearance = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: close
        )
        let result = XCTWaiter.wait(
            for: [disappearance],
            timeout: 2.5
        )
        XCTAssertEqual(result, .timedOut, "扫码页至少应稳定展示 2.5 秒")
        XCTAssertTrue(close.exists, "相机初始化后扫码页不应自动消失")
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func installCameraPermissionMonitor() {
        addUIInterruptionMonitor(withDescription: "Camera permission") { alert in
            let allowButtons = ["Allow", "允许", "Allow While Using App", "使用 App 时允许"]
                .map { alert.buttons[$0] }
            if let button = allowButtons.first(where: \.exists) {
                button.tap()
                return true
            }
            return false
        }
    }

    private func handleCameraPermissionIfPresented() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 6) else {
            return
        }
        let allowButtons = ["Allow", "允许", "Allow While Using App", "使用 App 时允许"]
            .map { alert.buttons[$0] }
        guard let button = allowButtons.first(where: \.exists) else {
            XCTFail("相机权限弹窗出现后应提供允许按钮")
            return
        }
        button.tap()
    }

    private func assertMinimumTouchTarget(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // 真机读取的是系统最终命中矩形，可同时覆盖 SwiftUI 内容形状和平台适配结果。
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, "\(name)宽度应至少为 44pt", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(name)高度应至少为 44pt", file: file, line: line)
    }

    private func assertPopover(
        _ confirmation: XCUIElement,
        isAnchoredNear source: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let windowFrame = app.windows.firstMatch.frame
        let confirmationFrame = confirmation.frame
        let sourceFrame = source.frame

        XCTAssertGreaterThanOrEqual(confirmationFrame.minX, windowFrame.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(confirmationFrame.maxX, windowFrame.maxX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(confirmationFrame.minY, windowFrame.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(confirmationFrame.maxY, windowFrame.maxY, file: file, line: line)
        // 系统确认按钮与 source rect 的中心应保持在一个 popover 宽度内；
        // 旧实现挂在整页根视图时，两者会横跨主内容与左侧会话栏。
        XCTAssertLessThanOrEqual(
            abs(confirmationFrame.midX - sourceFrame.midX),
            max(confirmationFrame.width, 360),
            "确认弹窗必须锚定在对应卡片操作入口附近",
            file: file,
            line: line
        )
    }

    private func openComposerIfNeeded() throws {
        let options = app.descendant(identifier: "composer.options")
        if options.waitForExistence(timeout: 4) {
            return
        }

        try enterWorkbenchIfNeeded()
        let sessionRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sessions.row."))
        guard sessionRows.firstMatch.waitForExistence(timeout: 25) else {
            throw XCTSkip("当前设备没有可打开的样例会话，跳过 Composer 真机状态回归")
        }
        sessionRows.firstMatch.tap()
        XCTAssertTrue(
            options.waitForExistence(timeout: 25),
            "打开样例会话后应进入 Composer"
        )
    }

    private func enterWorkbenchIfNeeded() throws {
        if workbenchSettingsEntry.waitForExistence(timeout: 3) {
            return
        }
        // iPad 的 NavigationSplitView 可能在启动后默认收起侧栏；先展开侧栏，
        // 才能访问侧栏底部的设置入口，避免把正常工作台误判为不可测试。
        if let showSidebar = firstExistingButton(
            labels: ["显示边栏", "Show Sidebar"],
            timeout: 2
        ), showSidebar.isHittable {
            showSidebar.tap()
            if workbenchSettingsEntry.waitForExistence(timeout: 8) {
                return
            }
        }
        if app.descendant(identifier: "composer.options").exists {
            let back = app.navigationBars.buttons.firstMatch
            if back.waitForExistence(timeout: 3), back.isHittable {
                back.tap()
                if workbenchSettingsEntry.waitForExistence(timeout: 8) {
                    return
                }
            }
        }
        let debugEntry = app.descendant(identifier: "settings.debugEnterWorkbench")
        guard scrollUntilHittable(debugEntry, maximumSwipes: 10) else {
            throw XCTSkip("当前页面既不是工作台，也没有 Debug 进入工作台入口")
        }
        debugEntry.tap()
        XCTAssertTrue(
            workbenchSettingsEntry.waitForExistence(timeout: 15),
            "Debug 入口应进入工作台"
        )
    }

    private func openSettings() throws {
        if app.descendant(identifier: "settings.connectionManagement").exists {
            return
        }
        if !workbenchSettingsEntry.exists,
           let showSidebar = firstExistingButton(
               labels: ["显示边栏", "Show Sidebar"],
               timeout: 2
           ),
           showSidebar.isHittable {
            showSidebar.tap()
            _ = workbenchSettingsEntry.waitForExistence(timeout: 8)
        }
        let settings = workbenchSettingsEntry
        guard settings.waitForExistence(timeout: 8) else {
            throw XCTSkip("工作台未展示设置入口")
        }
        settings.tap()
        XCTAssertTrue(
            app.descendant(identifier: "settings.connectionManagement").waitForExistence(timeout: 12),
            "设置页应正常打开"
        )
    }

    private func openWorkspaceAppearanceSettings() throws {
        try openSettings()
        let appearance = app.descendant(identifier: "settings.appearance")
        XCTAssertTrue(scrollUntilHittable(appearance), "设置页应提供外观入口")
        appearance.tap()
        XCTAssertTrue(
            app.descendant(identifier: "settings.workspaceIconStyle").waitForExistence(timeout: 8),
            "外观页应展示工作区图标风格选择器"
        )
    }

    private func relaunchDirectlyIntoWorkspaces() throws {
        app.terminate()
        if !app.launchArguments.contains("--debug-open-workspaces") {
            app.launchArguments.append("--debug-open-workspaces")
        }
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 25),
            "MimiRemote 应能重新进入工作区"
        )
        let iconButtons = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.card.icon."))
        XCTAssertTrue(
            iconButtons.firstMatch.waitForExistence(timeout: 15),
            "重新进入工作区后应展示可更换的图标"
        )
    }

    private func currentWorkspaceIconLabelContainsEmoji() -> Bool {
        let iconButtons = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.card.icon."))
        guard iconButtons.firstMatch.exists else { return false }
        let label = iconButtons.firstMatch.label
        let builtInEmoji = ["🐱", "🤖", "🦧", "🌻", "🍔", "⚾️", "🌍", "🌓", "🌈", "🚕", "🌋", "🍍", "📮"]
        return builtInEmoji.contains { label.contains($0) }
    }

    private func selectMode(identifier: String) throws {
        let options = app.descendant(identifier: "composer.options")
        XCTAssertTrue(options.waitForExistence(timeout: 8))
        options.tap()
        let mode = app.descendant(identifier: identifier)
        guard mode.waitForExistence(timeout: 5) else {
            throw XCTSkip("当前系统未向 UI Automation 暴露发送模式菜单项")
        }
        mode.tap()
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func assertModeSelected(expectedValues: Set<String>) {
        let options = app.descendant(identifier: "composer.options")
        XCTAssertTrue(options.waitForExistence(timeout: 10), "旋转后 Composer 工具栏不应消失")
        guard let value = options.value as? String else {
            XCTFail("旋转后发送模式入口应暴露当前模式")
            return
        }
        XCTAssertTrue(
            expectedValues.contains(value),
            "旋转后发送模式选择应保留，实际值：\(value)"
        )
    }

    private func rotate(to orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 8),
            "旋转后主窗口应继续存在"
        )
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        maximumSwipes: Int = 8
    ) -> Bool {
        if element.waitForExistence(timeout: 3), element.isHittable {
            return true
        }
        // 设置页使用 Form。手势只交给当前列表，避免在 iPad Sheet 边缘对整个
        // Application 滑动时被系统解释为模态交互手势。
        let settingsList = app.collectionViews.firstMatch
        for _ in 0..<maximumSwipes {
            if settingsList.exists {
                let start = settingsList.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.74)
                )
                let end = settingsList.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48)
                )
                start.press(forDuration: 0.05, thenDragTo: end)
            } else {
                app.swipeUp()
            }
            if element.exists, element.isHittable {
                return true
            }
        }
        return element.exists && element.isHittable
    }

    private func isSelected(_ element: XCUIElement) -> Bool {
        guard let value = element.value as? String else {
            return false
        }
        return selectedValues.contains(value)
    }

    private func waitUntilSelected(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                block: { object, _ in
                    guard let candidate = object as? XCUIElement else { return false }
                    return self.isSelected(candidate)
                }
            ),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 6) == .completed
    }

    private func waitUntilNotSelected(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                block: { object, _ in
                    guard let candidate = object as? XCUIElement else { return false }
                    return candidate.exists && !self.isSelected(candidate)
                }
            ),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 6) == .completed
    }

    private func waitUntilLabelContains(_ element: XCUIElement, text: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS[c] %@", text),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 6) == .completed
    }

    private func waitForFreshButtonHorizontalPosition(
        labels: [String],
        maxX expectedMaxX: CGFloat,
        accuracy: CGFloat,
        timeout: TimeInterval = 6
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                block: { _, _ in
                    // 每轮重新构造查询，避免 XCUIElement 句柄缓存动画前的 frame。
                    for label in labels {
                        let candidate = self.app.buttons[label]
                        if candidate.exists,
                           abs(candidate.frame.maxX - expectedMaxX) <= accuracy {
                            return true
                        }
                    }
                    return false
                }
            ),
            object: app
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForControlValue(
        _ element: XCUIElement,
        containing expectedValues: [String],
        timeout: TimeInterval = 6
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                block: { object, _ in
                    guard let candidate = object as? XCUIElement, candidate.exists else {
                        return false
                    }
                    let visibleValue = "\(candidate.value ?? "") \(candidate.label)"
                    return expectedValues.contains { visibleValue.contains($0) }
                }
            ),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func dismissPresentedMenuOrPopover() {
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.08))
            .tap()
    }

    private func firstExistingButton(
        labels: [String],
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let button = labels
                .map({ app.buttons[$0] })
                .first(where: \.exists) {
                return button
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    private var workbenchSettingsEntry: XCUIElement {
        let compact = app.descendant(identifier: "compactTab.me")
        if compact.exists {
            return compact
        }
        // 紧凑底栏首次恢复路由时，系统偶尔先发布 label、下一帧才发布 identifier。
        // 使用同一系统 Tab 的双语 label 兜底，避免把可见“我的”入口误判为缺失。
        let compactByLabel = app.tabBars.buttons.matching(
            NSPredicate(format: "label IN %@", ["我的", "Me"])
        ).firstMatch
        if compactByLabel.exists {
            return compactByLabel
        }
        return app.descendant(identifier: "sidebar.me")
    }
}

private extension XCUIApplication {
    func descendant(identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}
