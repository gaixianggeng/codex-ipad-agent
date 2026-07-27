package com.gaixianggeng.mimi.ui

import android.content.Context

internal object BundledLegalAssets {
    const val ProjectLicense = "LICENSE"
    const val ThirdPartyNotices = "THIRD_PARTY_NOTICES.md"
    const val PrivacyPolicy = "docs/privacy-policy.md"
    const val TermsOfUse = "docs/terms-of-use.md"
    const val Support = "docs/support.md"

    private val allowedNames = setOf(
        ProjectLicense,
        ThirdPartyNotices,
        PrivacyPolicy,
        TermsOfUse,
        Support,
    )

    fun read(context: Context, name: String): String {
        require(name in allowedNames) { "Unknown bundled legal asset" }
        return context.assets.open(name).bufferedReader(Charsets.UTF_8).use { it.readText() }
    }
}
