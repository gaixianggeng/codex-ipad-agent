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

    func testVoiceProviderCopyAndSelectionSurviveRotation() throws {
        try enterWorkbenchIfNeeded()
        try openSettings()

        let codex = app.descendant(identifier: "settings.voiceInputProvider.codex")
        let apple = app.descendant(identifier: "settings.voiceInputProvider.apple")
        XCTAssertTrue(scrollUntilHittable(codex), "设置页应展示 Codex 语音输入选项")
        XCTAssertTrue(apple.waitForExistence(timeout: 4), "设置页应展示设备端语音输入选项")

        let originalProviderWasApple = isSelected(apple)
        codex.tap()
        XCTAssertTrue(waitUntilSelected(codex), "选择 Codex 后应立即保存设备级偏好")

        let description = app.descendant(identifier: "settings.voiceInputProvider.codex.description")
        XCTAssertTrue(description.waitForExistence(timeout: 4), "Codex 选项应展示录音结束后转写的说明")
        let descriptionLabel = description.label
        let hasEnglishExplanation =
            descriptionLabel.contains("Codex built-in voice") &&
            descriptionLabel.contains("Transcribes after recording")
        let hasChineseExplanation =
            descriptionLabel.contains("Codex 内置语音") &&
            descriptionLabel.contains("录音结束后转写")
        XCTAssertTrue(
            hasEnglishExplanation || hasChineseExplanation,
            "Codex 语音说明必须明确内置语音能力和录音结束后转写"
        )

        rotate(to: .landscapeLeft)
        XCTAssertTrue(
            scrollUntilHittable(app.descendant(identifier: "settings.voiceInputProvider.codex")),
            "横屏后应仍能找到 Codex 语音选项"
        )
        XCTAssertTrue(
            waitUntilSelected(app.descendant(identifier: "settings.voiceInputProvider.codex")),
            "横屏后 Codex 选择不应丢失"
        )
        rotate(to: .portrait)
        XCTAssertTrue(
            scrollUntilHittable(app.descendant(identifier: "settings.voiceInputProvider.codex")),
            "竖屏后应仍能找到 Codex 语音选项"
        )
        XCTAssertTrue(
            waitUntilSelected(app.descendant(identifier: "settings.voiceInputProvider.codex")),
            "竖屏后 Codex 选择不应丢失"
        )

        if originalProviderWasApple {
            let currentApple = app.descendant(identifier: "settings.voiceInputProvider.apple")
            XCTAssertTrue(scrollUntilHittable(currentApple), "旋转后设备端选项仍应可操作")
            currentApple.tap()
            XCTAssertTrue(waitUntilSelected(currentApple), "测试结束时应恢复原语音提供方")
        }
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

    private func presentQRScanner() throws {
        installCameraPermissionMonitor()

        // 扫码页关闭后会回到连接管理页。优先复用当前页面的入口，避免为了第二次
        // 拉起扫码器又退回工作台并重新进入设置，降低实体机导航差异带来的误报。
        let currentConnectionScan = app.descendant(identifier: "settings.connection.scanQRCode")
        let firstSetupScan = app.descendant(identifier: "settings.macInstaller.scan")
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
            let setupScan = app.descendant(identifier: "settings.macInstaller.scan")
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
        if app.descendant(identifier: "settings.voiceInputProvider.codex").exists {
            return
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
        for _ in 0..<maximumSwipes {
            app.swipeUp()
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
        let compact = app.descendant(identifier: "compactTab.settings")
        if compact.exists {
            return compact
        }
        return app.descendant(identifier: "sidebar.settings")
    }
}

private extension XCUIApplication {
    func descendant(identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}
