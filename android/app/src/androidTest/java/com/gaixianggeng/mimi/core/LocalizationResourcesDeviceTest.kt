package com.gaixianggeng.mimi.core

import android.content.Context
import android.content.res.Configuration
import android.os.LocaleList
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.gaixianggeng.mimi.R
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LocalizationResourcesDeviceTest {
    private val appContext = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun criticalSessionAndApprovalStringsResolveInChinese() {
        val context = localizedContext("zh-CN")

        assertEquals("重命名会话", context.getString(R.string.rename_session))
        assertEquals("新建 Codex 会话", context.getString(R.string.new_runtime_session, "Codex"))
        assertEquals("引导当前回复", context.getString(R.string.guide_current_reply))
        assertEquals("需要审批", context.getString(R.string.approval_required))
        assertEquals("完整访问", context.getString(R.string.permission_full_access))
        assertEquals("动态配色", context.getString(R.string.dynamic_color))
        assertEquals("设备端", context.getString(R.string.voice_on_device))
        assertEquals("法律与支持", context.getString(R.string.legal_and_support))
        assertEquals("开源许可", context.getString(R.string.open_source_licenses))
        assertEquals(
            "VPN 开启时私网 Mac 地址连接失败（HTTP 503）。VPN 可能拦截了局域网流量；请在 VPN 中允许 LAN/私网绕过，或改用可通过该 VPN 访问的地址。",
            context.getString(R.string.private_endpoint_vpn_failure, "HTTP 503"),
        )
        assertEquals("打开工作区", context.getString(R.string.open_workspace))
        assertEquals("丢弃此代码块？", context.getString(R.string.discard_hunk_question))
        assertEquals("拉取请求", context.getString(R.string.pull_request))
        assertEquals("尚未检查", context.getString(R.string.doctor_not_checked))
        assertEquals("所有检查均已通过", context.getString(R.string.doctor_all_checks_passed))
        assertEquals("需要处理", context.getString(R.string.doctor_attention_needed))
        assertEquals("Tailscale 直连", context.getString(R.string.tailscale_direct))
        assertEquals("Codex 需要批准", context.getString(R.string.notification_needs_approval))
        assertEquals("会话提醒", context.getString(R.string.session_reminder_title))
        assertEquals("需要权限", context.getString(R.string.permission_recovery_title))
        assertEquals("打开应用设置", context.getString(R.string.open_app_settings))
        assertEquals("目标内容不能为空", context.getString(R.string.goal_objective_required))
        assertEquals(
            "连接在“加载项目”阶段失败：HTTP 503",
            context.getString(R.string.connection_failed_with_detail, context.getString(R.string.connection_stage_load_projects), "HTTP 503"),
        )
        assertEquals(
            "重试排队消息前需要确认：连接中断",
            context.getString(R.string.queued_message_confirmation_required, "连接中断"),
        )
        assertEquals(
            "网关：2 个活跃 / 5 个总连接 · 1 次拨号失败 · 0 个策略错误",
            context.getString(R.string.gateway_diagnostic_summary, 2, 5, 1, 0),
        )
    }

    @Test
    fun criticalSessionAndApprovalStringsRetainEnglishFallback() {
        val context = localizedContext("en-US")

        assertEquals("Rename session", context.getString(R.string.rename_session))
        assertEquals("New Claude session", context.getString(R.string.new_runtime_session, "Claude"))
        assertEquals("Queue next turn", context.getString(R.string.queue_next_turn))
        assertEquals("Approval required", context.getString(R.string.approval_required))
        assertEquals("Read only", context.getString(R.string.permission_read_only))
        assertEquals("Appearance", context.getString(R.string.appearance))
        assertEquals("AI usage", context.getString(R.string.ai_usage))
        assertEquals("Capabilities", context.getString(R.string.capabilities))
        assertEquals("Agent diagnostics", context.getString(R.string.agent_diagnostics))
        assertEquals(
            "The saved Mac did not respond within 10 seconds.",
            context.getString(R.string.saved_mac_timeout),
        )
        assertEquals("Delete worktree?", context.getString(R.string.delete_worktree_question))
        assertEquals("Export log", context.getString(R.string.export_log))
        assertEquals("Not checked", context.getString(R.string.doctor_not_checked))
        assertEquals("All checks passed", context.getString(R.string.doctor_all_checks_passed))
        assertEquals("Tailscale direct", context.getString(R.string.tailscale_direct))
        assertEquals("Codex needs approval", context.getString(R.string.notification_needs_approval))
        assertEquals("Session reminder", context.getString(R.string.session_reminder_title))
        assertEquals("Permission required", context.getString(R.string.permission_recovery_title))
        assertEquals("Open app settings", context.getString(R.string.open_app_settings))
        assertEquals("Goal objective cannot be empty", context.getString(R.string.goal_objective_required))
        assertEquals(
            "Connection failed while loading projects: HTTP 503",
            context.getString(R.string.connection_failed_with_detail, context.getString(R.string.connection_stage_load_projects), "HTTP 503"),
        )
        assertEquals(
            "Gateway: 2 active / 5 total · 1 dial failures · 0 policy errors",
            context.getString(R.string.gateway_diagnostic_summary, 2, 5, 1, 0),
        )
    }

    private fun localizedContext(languageTag: String): Context {
        val configuration = Configuration(appContext.resources.configuration).apply {
            setLocales(LocaleList(Locale.forLanguageTag(languageTag)))
        }
        return appContext.createConfigurationContext(configuration)
    }
}
