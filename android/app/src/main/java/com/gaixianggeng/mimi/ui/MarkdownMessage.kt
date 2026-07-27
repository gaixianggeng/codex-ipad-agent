package com.gaixianggeng.mimi.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.gaixianggeng.mimi.R
import com.gaixianggeng.mimi.core.model.ConversationFileReferenceDetector
import com.gaixianggeng.mimi.ui.theme.LocalMimiCodeFontFamily

internal sealed interface MarkdownBlock {
    data class Paragraph(val text: String) : MarkdownBlock
    data class Heading(val level: Int, val text: String) : MarkdownBlock
    data class Quote(val blocks: List<MarkdownBlock>) : MarkdownBlock
    data class BulletList(val items: List<MarkdownListItem>) : MarkdownBlock
    data class OrderedList(val start: Int, val items: List<MarkdownListItem>) : MarkdownBlock
    data class LegacyQuote(val text: String) : MarkdownBlock
    data class LegacyBullet(val text: String, val checked: Boolean? = null) : MarkdownBlock
    data class LegacyOrdered(val number: Int, val text: String) : MarkdownBlock
    data class Code(val language: String?, val body: String) : MarkdownBlock
    data class ProposedPlan(val blocks: List<MarkdownBlock>, val isComplete: Boolean) : MarkdownBlock
    data class Table(val rows: List<List<String>>, val alignments: List<MarkdownColumnAlignment>) : MarkdownBlock
    data class Image(val alt: String, val source: String, val title: String? = null) : MarkdownBlock
    data object Rule : MarkdownBlock
}

internal data class MarkdownListItem(
    val checked: Boolean?,
    val blocks: List<MarkdownBlock>,
)

internal enum class MarkdownColumnAlignment {
    Leading,
    Center,
    Trailing,
}

@Composable
internal fun MarkdownMessageContent(
    text: String,
    modifier: Modifier = Modifier,
    onHistoryMedia: ((String) -> Unit)? = null,
    onLocalFile: ((String) -> Unit)? = null,
) {
    val blocks = remember(text) { parseMarkdown(text) }
    SelectionContainer(modifier) {
        MarkdownBlocks(blocks, onHistoryMedia, onLocalFile)
    }
}

@Composable
private fun MarkdownBlocks(
    blocks: List<MarkdownBlock>,
    onHistoryMedia: ((String) -> Unit)?,
    onLocalFile: ((String) -> Unit)?,
) {
    val codeFontFamily = LocalMimiCodeFontFamily.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        blocks.forEach { block ->
            when (block) {
                is MarkdownBlock.Paragraph -> Text(inlineMarkdown(block.text, MaterialTheme.colorScheme.primary, codeFontFamily), style = MaterialTheme.typography.bodyLarge)
                is MarkdownBlock.Heading -> Text(
                    inlineMarkdown(block.text, MaterialTheme.colorScheme.primary, codeFontFamily),
                    style = when (block.level) {
                        1 -> MaterialTheme.typography.headlineSmall
                        2 -> MaterialTheme.typography.titleLarge
                        else -> MaterialTheme.typography.titleMedium
                    },
                    fontWeight = FontWeight.SemiBold,
                )
                is MarkdownBlock.Quote -> Row(verticalAlignment = Alignment.Top) {
                    Text("│", color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.width(10.dp))
                    MarkdownBlocks(block.blocks, onHistoryMedia, onLocalFile)
                }
                is MarkdownBlock.BulletList -> MarkdownList(
                    items = block.items,
                    orderedStart = null,
                    onHistoryMedia = onHistoryMedia,
                    onLocalFile = onLocalFile,
                )
                is MarkdownBlock.OrderedList -> MarkdownList(
                    items = block.items,
                    orderedStart = block.start,
                    onHistoryMedia = onHistoryMedia,
                    onLocalFile = onLocalFile,
                )
                is MarkdownBlock.LegacyQuote -> Row {
                    Text("│", color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.width(10.dp))
                    Text(inlineMarkdown(block.text, MaterialTheme.colorScheme.primary, codeFontFamily))
                }
                is MarkdownBlock.LegacyBullet -> Row {
                    Text(block.checked?.let { if (it) "☑" else "☐" } ?: "•")
                    Spacer(Modifier.width(8.dp))
                    Text(inlineMarkdown(block.text, MaterialTheme.colorScheme.primary, codeFontFamily))
                }
                is MarkdownBlock.LegacyOrdered -> Row {
                    Text("${block.number}.")
                    Spacer(Modifier.width(8.dp))
                    Text(inlineMarkdown(block.text, MaterialTheme.colorScheme.primary, codeFontFamily))
                }
                is MarkdownBlock.Code -> CodeBlock(block)
                is MarkdownBlock.ProposedPlan -> ProposedPlanBlock(block, onHistoryMedia, onLocalFile)
                is MarkdownBlock.Table -> MarkdownTable(block.rows, block.alignments)
                is MarkdownBlock.Image -> {
                    val prefix = "agentd-history-media://"
                    val localPath = markdownLocalImagePath(block.source)
                    val displayText = block.alt.ifBlank {
                        block.title?.takeIf(String::isNotBlank)
                            ?: localPath?.substringAfterLast('/')
                            ?: stringResource(R.string.markdown_image)
                    }
                    when {
                        block.source.startsWith(prefix) && onHistoryMedia != null -> TextButton(onClick = { onHistoryMedia(block.source.removePrefix(prefix)) }) {
                            Text(block.alt.ifBlank { block.title?.takeIf(String::isNotBlank) ?: stringResource(R.string.history_media_load) })
                        }
                        localPath != null && onLocalFile != null -> OutlinedButton(onClick = { onLocalFile(localPath) }) {
                            Text(displayText)
                        }
                        isAllowedMarkdownImage(block.source) -> AsyncImage(
                            model = block.source,
                            contentDescription = displayText,
                            modifier = Modifier.fillMaxWidth().heightIn(max = 420.dp),
                        )
                        else -> Text(block.alt.ifBlank { block.title?.takeIf(String::isNotBlank) ?: stringResource(R.string.image_source_blocked) }, color = MaterialTheme.colorScheme.error)
                    }
                }
                MarkdownBlock.Rule -> HorizontalDivider()
            }
        }
    }
}

@Composable
private fun MarkdownList(
    items: List<MarkdownListItem>,
    orderedStart: Int?,
    onHistoryMedia: ((String) -> Unit)?,
    onLocalFile: ((String) -> Unit)?,
) {
    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
        items.forEachIndexed { index, item ->
            Row(verticalAlignment = Alignment.Top) {
                Text(
                    text = item.checked?.let { if (it) "☑" else "☐" }
                        ?: orderedStart?.let { "${it + index}." }
                        ?: "•",
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.width(if (orderedStart != null) 30.dp else 22.dp),
                    textAlign = TextAlign.End,
                )
                Spacer(Modifier.width(8.dp))
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    MarkdownBlocks(item.blocks, onHistoryMedia, onLocalFile)
                }
            }
        }
    }
}

@Composable
private fun ProposedPlanBlock(
    block: MarkdownBlock.ProposedPlan,
    onHistoryMedia: ((String) -> Unit)?,
    onLocalFile: ((String) -> Unit)?,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        shape = MaterialTheme.shapes.medium,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.Filled.Checklist, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                Text(
                    stringResource(R.string.plan_label),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (!block.isComplete) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp),
                        strokeWidth = 2.dp,
                    )
                }
            }
            MarkdownBlocks(block.blocks, onHistoryMedia, onLocalFile)
        }
    }
}

@Composable
private fun CodeBlock(block: MarkdownBlock.Code) {
    val clipboard = LocalClipboardManager.current
    val codeFontFamily = LocalMimiCodeFontFamily.current
    val isDiff = block.language?.lowercase() in setOf("diff", "patch")
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHighest,
        shape = MaterialTheme.shapes.medium,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column {
            Row(
                Modifier.fillMaxWidth().padding(start = 12.dp, end = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(block.language ?: stringResource(R.string.code_label), style = MaterialTheme.typography.labelSmall, modifier = Modifier.weight(1f))
                TextButton(onClick = { clipboard.setText(AnnotatedString(block.body)) }) { Text(stringResource(R.string.copy_code)) }
            }
            Column(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 8.dp)) {
                block.body.lines().forEach { line ->
                    val lineColor = when {
                        !isDiff -> Color.Transparent
                        line.startsWith("+") && !line.startsWith("+++") -> MaterialTheme.colorScheme.primaryContainer
                        line.startsWith("-") && !line.startsWith("---") -> MaterialTheme.colorScheme.errorContainer
                        else -> Color.Transparent
                    }
                    Text(
                        if (isDiff) AnnotatedString(line.ifEmpty { " " }) else highlightedCodeLine(
                            line.ifEmpty { " " },
                            block.language,
                            MaterialTheme.colorScheme.primary,
                            MaterialTheme.colorScheme.tertiary,
                            MaterialTheme.colorScheme.onSurfaceVariant,
                        ),
                        fontFamily = codeFontFamily,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.background(lineColor).fillMaxWidth().padding(horizontal = 4.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun MarkdownTable(rows: List<List<String>>, alignments: List<MarkdownColumnAlignment>) {
    val columnCount = rows.maxOfOrNull(List<String>::size) ?: return
    val codeFontFamily = LocalMimiCodeFontFamily.current
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        shape = MaterialTheme.shapes.small,
        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
    ) {
        Column(Modifier.padding(8.dp).width((columnCount * 132).dp)) {
            rows.forEachIndexed { rowIndex, row ->
                Row(Modifier.fillMaxWidth()) {
                    repeat(columnCount) { column ->
                        Text(
                            inlineMarkdown(row.getOrElse(column) { "" }, MaterialTheme.colorScheme.primary, codeFontFamily),
                            modifier = Modifier.weight(1f).padding(6.dp),
                            fontWeight = if (rowIndex == 0) FontWeight.SemiBold else FontWeight.Normal,
                            style = MaterialTheme.typography.bodySmall,
                            textAlign = when (alignments.getOrNull(column)) {
                                MarkdownColumnAlignment.Center -> TextAlign.Center
                                MarkdownColumnAlignment.Trailing -> TextAlign.End
                                else -> TextAlign.Start
                            },
                        )
                    }
                }
                if (rowIndex == 0) HorizontalDivider()
            }
        }
    }
}

private fun legacyInlineMarkdown(value: String, linkColor: Color): AnnotatedString = buildAnnotatedString {
    var cursor = 0
    val token = Regex("(\\*\\*[^*]+\\*\\*|~~[^~]+~~|(?<!\\*)\\*[^*\\r\\n]+\\*(?!\\*)|`[^`]+`|\\[[^]\\r\\n]+]\\([^()\\s]+\\))")
    token.findAll(value).forEach { match ->
        append(value.substring(cursor, match.range.first))
        val raw = match.value
        if (raw.startsWith("[") && raw.contains("](")) {
            val split = raw.indexOf("](")
            val label = raw.substring(1, split)
            val url = raw.substring(split + 2, raw.length - 1)
            if (isAllowedMarkdownLink(url)) {
                withLink(LinkAnnotation.Url(
                    url = url,
                    styles = TextLinkStyles(style = SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)),
                )) { append(label) }
            } else append(label)
        } else if (raw.startsWith("**")) {
            withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(raw.removePrefix("**").removeSuffix("**")) }
        } else if (raw.startsWith("~~")) {
            withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) { append(raw.removePrefix("~~").removeSuffix("~~")) }
        } else if (raw.startsWith("*")) {
            withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(raw.removePrefix("*").removeSuffix("*")) }
        } else {
            withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) { append(raw.removePrefix("`").removeSuffix("`")) }
        }
        cursor = match.range.last + 1
    }
    append(value.substring(cursor))
}

private fun isAllowedMarkdownLink(value: String): Boolean =
    value.startsWith("https://", ignoreCase = true) ||
        value.startsWith("http://", ignoreCase = true) ||
        value.startsWith("mailto:", ignoreCase = true)

private fun parseLegacyMarkdown(source: String): List<MarkdownBlock> =
    parseProposedPlan(source) ?: parseMarkdownBlocks(source)

private fun parseProposedPlan(source: String): List<MarkdownBlock>? {
    val normalized = source.replace("\r\n", "\n")
    val lines = normalized.lines()
    val openingIndex = lines.indexOfFirst { it.trim() == "<proposed_plan>" }
    if (openingIndex < 0) return null

    val closingIndex = ((openingIndex + 1) until lines.size)
        .firstOrNull { lines[it].trim() == "</proposed_plan>" }
    val innerEnd = closingIndex ?: lines.size
    val result = mutableListOf<MarkdownBlock>()

    lines.subList(0, openingIndex).joinToString("\n").takeIf { it.isNotBlank() }
        ?.let { result += parseMarkdownBlocks(it) }

    val inner = lines.subList(openingIndex + 1, innerEnd).joinToString("\n")
    val innerBlocks = if (inner.isBlank()) {
        listOf(MarkdownBlock.Paragraph(""))
    } else {
        parseMarkdownBlocks(inner)
    }
    result += MarkdownBlock.ProposedPlan(innerBlocks, closingIndex != null)

    if (closingIndex != null) {
        lines.subList(closingIndex + 1, lines.size).joinToString("\n").takeIf { it.isNotBlank() }
            ?.let { result += parseMarkdownBlocks(it) }
    }
    return result
}

private fun parseMarkdownBlocks(source: String): List<MarkdownBlock> {
    val lines = source.replace("\r\n", "\n").lines()
    val blocks = mutableListOf<MarkdownBlock>()
    var index = 0
    while (index < lines.size) {
        val line = lines[index]
        when {
            line.isBlank() -> index++
            standaloneMarkdownImage(line.trim()) != null -> {
                blocks += standaloneMarkdownImage(line.trim())!!
                index++
            }
            line.trimStart().startsWith("```") -> {
                val language = line.trimStart().removePrefix("```").trim().takeIf(String::isNotEmpty)
                val body = mutableListOf<String>()
                index++
                while (index < lines.size && !lines[index].trimStart().startsWith("```")) body += lines[index++]
                if (index < lines.size) index++
                blocks += MarkdownBlock.Code(language, body.joinToString("\n"))
            }
            line.matches(Regex("#{1,6}\\s+.*")) -> {
                val marker = line.takeWhile { it == '#' }
                blocks += MarkdownBlock.Heading(marker.length, line.drop(marker.length).trim())
                index++
            }
            index + 1 < lines.size && line.isNotBlank() && lines[index + 1].trim().matches(Regex("(=+|-+)")) -> {
                blocks += MarkdownBlock.Heading(
                    level = if (lines[index + 1].trim().startsWith('=')) 1 else 2,
                    text = line.trim(),
                )
                index += 2
            }
            line.trim() in setOf("---", "***", "___") -> {
                blocks += MarkdownBlock.Rule
                index++
            }
            index + 1 < lines.size && line.contains('|') && isTableDivider(lines[index + 1]) -> {
                val rows = mutableListOf(splitTableRow(line))
                val alignments = splitTableRow(lines[index + 1]).map(::tableAlignment)
                index += 2
                while (index < lines.size && lines[index].contains('|') && lines[index].isNotBlank()) {
                    rows += splitTableRow(lines[index++])
                }
                blocks += MarkdownBlock.Table(rows, alignments)
            }
            line.startsWith(">") -> {
                blocks += MarkdownBlock.LegacyQuote(line.removePrefix(">").trim())
                index++
            }
            Regex("^\\s*[-*+] \\[([ xX])].*").matches(line) -> {
                val match = Regex("^\\s*[-*+] \\[([ xX])]\\s*(.*)").find(line)!!
                blocks += MarkdownBlock.LegacyBullet(match.groupValues[2], match.groupValues[1].equals("x", ignoreCase = true))
                index++
            }
            Regex("^\\s*[-*+]\\s+.*").matches(line) -> {
                blocks += MarkdownBlock.LegacyBullet(line.replaceFirst(Regex("^\\s*[-*+]\\s+"), ""))
                index++
            }
            Regex("^\\s*\\d+[.)]\\s+.*").matches(line) -> {
                val match = Regex("^\\s*(\\d+)[.)]\\s+(.*)").find(line)!!
                blocks += MarkdownBlock.LegacyOrdered(match.groupValues[1].toIntOrNull() ?: 1, match.groupValues[2])
                index++
            }
            else -> {
                val paragraph = mutableListOf(line.trim())
                index++
                while (index < lines.size && lines[index].isNotBlank() && !startsMarkdownBlock(lines, index)) {
                    paragraph += lines[index++].trim()
                }
                blocks += MarkdownBlock.Paragraph(paragraph.joinToString("\n"))
            }
        }
    }
    return blocks.ifEmpty { listOf(MarkdownBlock.Paragraph("")) }
}

private fun startsMarkdownBlock(lines: List<String>, index: Int): Boolean {
    val line = lines[index]
    return line.trimStart().startsWith("```") || standaloneMarkdownImage(line.trim()) != null || line.startsWith("#") || line.startsWith(">") ||
        line.trim() in setOf("---", "***", "___") || Regex("^\\s*[-*+]\\s+.*").matches(line) ||
        Regex("^\\s*\\d+[.)]\\s+.*").matches(line) ||
        (index + 1 < lines.size && line.isNotBlank() && lines[index + 1].trim().matches(Regex("(=+|-+)"))) ||
        (index + 1 < lines.size && line.contains('|') && isTableDivider(lines[index + 1]))
}

private fun isTableDivider(line: String): Boolean = splitTableRow(line).isNotEmpty() &&
    splitTableRow(line).all { it.matches(Regex(":?-{3,}:?")) }

private fun splitTableRow(line: String): List<String> = line.trim().trim('|').split('|').map(String::trim)

private fun tableAlignment(divider: String): MarkdownColumnAlignment = when {
    divider.startsWith(':') && divider.endsWith(':') -> MarkdownColumnAlignment.Center
    divider.endsWith(':') -> MarkdownColumnAlignment.Trailing
    else -> MarkdownColumnAlignment.Leading
}

private fun standaloneMarkdownImage(line: String): MarkdownBlock.Image? {
    val match = Regex("""^!\[([^]\r\n]*)]\((<[^>]+>|\S+?)(?:\s+(?:"([^"]*)"|'([^']*)'))?\)$""")
        .matchEntire(line)
        ?: return null
    val title = match.groupValues.drop(3).firstOrNull(String::isNotEmpty)
    return MarkdownBlock.Image(
        alt = match.groupValues[1],
        source = match.groupValues[2].removeSurrounding("<", ">"),
        title = title,
    )
}

private fun legacyMarkdownLocalImagePath(source: String): String? =
    ConversationFileReferenceDetector.imageReferences(source, limit = 1).firstOrNull()?.path

private fun legacyIsAllowedMarkdownImage(value: String): Boolean =
    value.startsWith("https://", true) || value.startsWith("http://", true) || value.startsWith("data:image/", true)

private fun highlightedCodeLine(
    line: String,
    language: String?,
    keywordColor: Color,
    literalColor: Color,
    commentColor: Color,
): AnnotatedString = buildAnnotatedString {
    val keywords = when (language?.lowercase()) {
        "kotlin", "kt" -> "fun|val|var|class|object|interface|when|if|else|for|while|return|suspend|data|sealed|private|public|internal|override|import|package|is|in|null|true|false"
        "swift" -> "func|let|var|class|struct|enum|protocol|if|else|for|while|return|async|await|actor|private|public|internal|import|nil|true|false|guard|switch|case"
        "python", "py" -> "def|class|if|else|elif|for|while|return|async|await|import|from|as|try|except|finally|with|None|True|False|lambda|yield"
        "javascript", "js", "typescript", "ts", "tsx", "jsx" -> "function|const|let|var|class|if|else|for|while|return|async|await|import|export|from|new|null|true|false|interface|type|extends"
        "json" -> "true|false|null"
        "bash", "sh", "shell" -> "if|then|else|fi|for|do|done|case|esac|function|in"
        else -> ""
    }
    val keywordPattern = if (keywords.isBlank()) "(?!)" else "\\b(?:$keywords)\\b"
    val tokenRegex = Regex("(//.*$|#.*$|\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|$keywordPattern|\\b\\d+(?:\\.\\d+)?\\b)")
    var cursor = 0
    tokenRegex.findAll(line).forEach { match ->
        append(line.substring(cursor, match.range.first))
        val value = match.value
        val style = when {
            value.startsWith("//") || value.startsWith("#") -> SpanStyle(color = commentColor, fontStyle = FontStyle.Italic)
            value.startsWith("\"") || value.startsWith("'") || value.firstOrNull()?.isDigit() == true -> SpanStyle(color = literalColor)
            else -> SpanStyle(color = keywordColor, fontWeight = FontWeight.SemiBold)
        }
        withStyle(style) { append(value) }
        cursor = match.range.last + 1
    }
    append(line.substring(cursor))
}
