package com.gaixianggeng.mimi.ui

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File

internal fun artifactViewIntent(
    context: Context,
    localPath: String,
    contentType: String,
): Intent {
    val file = File(localPath)
    require(file.isFile) { "Preview file is unavailable" }
    val uri = FileProvider.getUriForFile(
        context,
        "${context.packageName}.files",
        file,
    )
    return Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(uri, contentType.ifBlank { "application/octet-stream" })
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
}
