package com.gaixianggeng.mimi.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import com.gaixianggeng.mimi.core.model.ConversationFileReferenceDetector
import org.commonmark.Extension
import org.commonmark.ext.gfm.strikethrough.Strikethrough
import org.commonmark.ext.gfm.strikethrough.StrikethroughExtension
import org.commonmark.ext.gfm.tables.TableBlock
import org.commonmark.ext.gfm.tables.TableBody
import org.commonmark.ext.gfm.tables.TableCell
import org.commonmark.ext.gfm.tables.TableHead
import org.commonmark.ext.gfm.tables.TableRow
import org.commonmark.ext.gfm.tables.TablesExtension
import org.commonmark.ext.task.list.items.TaskListItemMarker
import org.commonmark.ext.task.list.items.TaskListItemsExtension
import org.commonmark.node.BlockQuote
import org.commonmark.node.BulletList
import org.commonmark.node.Code
import org.commonmark.node.Emphasis
import org.commonmark.node.FencedCodeBlock
import org.commonmark.node.HardLineBreak
import org.commonmark.node.Heading
import org.commonmark.node.HtmlBlock
import org.commonmark.node.HtmlInline
import org.commonmark.node.Image
import org.commonmark.node.IndentedCodeBlock
import org.commonmark.node.Link
import org.commonmark.node.ListItem
import org.commonmark.node.Node
import org.commonmark.node.OrderedList
import org.commonmark.node.Paragraph
import org.commonmark.node.SoftLineBreak
import org.commonmark.node.StrongEmphasis
import org.commonmark.node.Text
import org.commonmark.node.ThematicBreak
import org.commonmark.parser.Parser
import org.commonmark.renderer.markdown.MarkdownRenderer

private object CommonMarkMessageEngine {
    val extensions: List<Extension> = listOf(
        TablesExtension.create(),
        StrikethroughExtension.create(),
        TaskListItemsExtension.create(),
    )
    val parser: Parser = Parser.builder().extensions(extensions).build()
    val renderer: MarkdownRenderer = MarkdownRenderer.builder().extensions(extensions).build()
}

internal fun parseMarkdown(source: String): List<MarkdownBlock> =
    parseProposedPlanWithCommonMark(source) ?: parseCommonMarkBlocks(source)

private fun parseProposedPlanWithCommonMark(source: String): List<MarkdownBlock>? {
    val normalized = source.replace("\r\n", "\n")
    val lines = normalized.lines()
    val openingIndex = lines.indexOfFirst { it.trim() == "<proposed_plan>" }
    if (openingIndex < 0) return null

    val closingIndex = ((openingIndex + 1) until lines.size)
        .firstOrNull { lines[it].trim() == "</proposed_plan>" }
    val innerEnd = closingIndex ?: lines.size
    val result = mutableListOf<MarkdownBlock>()

    lines.subList(0, openingIndex).joinToString("\n").takeIf(String::isNotBlank)
        ?.let { result += parseCommonMarkBlocks(it) }

    val inner = lines.subList(openingIndex + 1, innerEnd).joinToString("\n")
    result += MarkdownBlock.ProposedPlan(
        blocks = if (inner.isBlank()) listOf(MarkdownBlock.Paragraph("")) else parseCommonMarkBlocks(inner),
        isComplete = closingIndex != null,
    )

    if (closingIndex != null) {
        lines.subList(closingIndex + 1, lines.size).joinToString("\n").takeIf(String::isNotBlank)
            ?.let { result += parseCommonMarkBlocks(it) }
    }
    return result
}

private fun parseCommonMarkBlocks(source: String): List<MarkdownBlock> {
    val document = CommonMarkMessageEngine.parser.parse(source)
    return document.children()
        .mapNotNull(::markdownBlock)
        .toList()
        .ifEmpty { listOf(MarkdownBlock.Paragraph("")) }
}

private fun markdownBlock(node: Node): MarkdownBlock? = when (node) {
    is Paragraph -> standaloneImage(node) ?: MarkdownBlock.Paragraph(inlineSource(node))
    is Heading -> MarkdownBlock.Heading(node.level.coerceIn(1, 6), inlineSource(node))
    is BulletList -> MarkdownBlock.BulletList(listItems(node))
    is OrderedList -> MarkdownBlock.OrderedList(node.markerStartNumber ?: 1, listItems(node))
    is BlockQuote -> MarkdownBlock.Quote(node.children().mapNotNull(::markdownBlock).toList())
    is FencedCodeBlock -> MarkdownBlock.Code(
        language = node.info.trim().substringBefore(' ').takeIf(String::isNotEmpty),
        body = node.literal.removeSuffix("\n"),
    )
    is IndentedCodeBlock -> MarkdownBlock.Code(language = null, body = node.literal.removeSuffix("\n"))
    is TableBlock -> markdownTable(node)
    is ThematicBreak -> MarkdownBlock.Rule
    is HtmlBlock -> MarkdownBlock.Paragraph(node.literal)
    else -> null
}

private fun listItems(list: Node): List<MarkdownListItem> =
    list.children().filterIsInstance<ListItem>().map { item ->
        val marker = item.children().filterIsInstance<TaskListItemMarker>().firstOrNull()
        val blocks = item.children()
            .filterNot { it is TaskListItemMarker }
            .mapNotNull(::markdownBlock)
            .toList()
            .ifEmpty { listOf(MarkdownBlock.Paragraph("")) }
        MarkdownListItem(marker?.isChecked, blocks)
    }.toList()

private fun markdownTable(table: TableBlock): MarkdownBlock.Table {
    val rows = table.children()
        .filter { it is TableHead || it is TableBody }
        .flatMap(Node::children)
        .filterIsInstance<TableRow>()
        .toList()
    val cells = rows.map { row ->
        row.children().filterIsInstance<TableCell>().toList()
    }
    val alignments = cells.firstOrNull().orEmpty().map { cell ->
        when (cell.alignment?.name) {
            "CENTER" -> MarkdownColumnAlignment.Center
            "RIGHT" -> MarkdownColumnAlignment.Trailing
            else -> MarkdownColumnAlignment.Leading
        }
    }
    return MarkdownBlock.Table(
        rows = cells.map { row -> row.map(::inlineSource) },
        alignments = alignments,
    )
}

private fun standaloneImage(paragraph: Paragraph): MarkdownBlock.Image? {
    val children = paragraph.children().toList()
    val image = children.singleOrNull() as? Image ?: return null
    return MarkdownBlock.Image(
        alt = plainText(image).trim(),
        source = image.destination.trim(),
        title = image.title?.trim()?.takeIf(String::isNotEmpty),
    )
}

private fun inlineSource(parent: Node): String = buildString {
    parent.children().forEach { append(CommonMarkMessageEngine.renderer.render(it)) }
}

private fun plainText(parent: Node): String = buildString {
    fun appendNode(node: Node) {
        when (node) {
            is Text -> append(node.literal)
            is Code -> append(node.literal)
            is SoftLineBreak, is HardLineBreak -> append('\n')
            is HtmlInline -> append(node.literal)
            else -> node.children().forEach(::appendNode)
        }
    }
    parent.children().forEach(::appendNode)
}

internal fun inlineMarkdown(
    value: String,
    linkColor: Color,
    codeFontFamily: FontFamily = FontFamily.Monospace,
): AnnotatedString {
    val document = CommonMarkMessageEngine.parser.parse(value)
    return buildAnnotatedString {
        document.children().forEachIndexed { index, block ->
            if (index > 0) append('\n')
            appendInlineChildren(block, InlineStyle(), linkColor, codeFontFamily)
        }
    }
}

private data class InlineStyle(
    val bold: Boolean = false,
    val italic: Boolean = false,
    val strike: Boolean = false,
    val code: Boolean = false,
)

private fun AnnotatedString.Builder.appendInlineChildren(
    parent: Node,
    style: InlineStyle,
    linkColor: Color,
    codeFontFamily: FontFamily,
) {
    parent.children().forEach { appendInlineNode(it, style, linkColor, codeFontFamily) }
}

private fun AnnotatedString.Builder.appendInlineNode(
    node: Node,
    style: InlineStyle,
    linkColor: Color,
    codeFontFamily: FontFamily,
) {
    when (node) {
        is Text -> appendStyled(node.literal, style, codeFontFamily)
        is Code -> appendStyled(node.literal, style.copy(code = true), codeFontFamily)
        is SoftLineBreak, is HardLineBreak -> append('\n')
        is StrongEmphasis -> appendInlineChildren(node, style.copy(bold = true), linkColor, codeFontFamily)
        is Emphasis -> appendInlineChildren(node, style.copy(italic = true), linkColor, codeFontFamily)
        is Strikethrough -> appendInlineChildren(node, style.copy(strike = true), linkColor, codeFontFamily)
        is Link -> {
            val destination = node.destination
            if (isAllowedMarkdownLink(destination)) {
                withLink(
                    LinkAnnotation.Url(
                        url = destination,
                        styles = TextLinkStyles(
                            style = SpanStyle(
                                color = linkColor,
                                textDecoration = TextDecoration.Underline,
                            ),
                        ),
                    ),
                ) {
                    appendInlineChildren(node, style, linkColor, codeFontFamily)
                }
            } else {
                appendInlineChildren(node, style, linkColor, codeFontFamily)
            }
        }
        is Image -> {
            val label = plainText(node).ifBlank { node.destination }
            appendStyled(label, style, codeFontFamily)
        }
        is HtmlInline -> appendStyled(node.literal, style, codeFontFamily)
        else -> appendInlineChildren(node, style, linkColor, codeFontFamily)
    }
}

private fun AnnotatedString.Builder.appendStyled(
    value: String,
    style: InlineStyle,
    codeFontFamily: FontFamily,
) {
    if (!style.bold && !style.italic && !style.strike && !style.code) {
        append(value)
        return
    }
    withStyle(
        SpanStyle(
            fontWeight = if (style.bold) FontWeight.Bold else null,
            fontStyle = if (style.italic) FontStyle.Italic else null,
            textDecoration = if (style.strike) TextDecoration.LineThrough else null,
            fontFamily = if (style.code) codeFontFamily else null,
        ),
    ) {
        append(value)
    }
}

private fun isAllowedMarkdownLink(value: String): Boolean =
    value.startsWith("https://", ignoreCase = true) ||
        value.startsWith("http://", ignoreCase = true) ||
        value.startsWith("mailto:", ignoreCase = true)

internal fun markdownLocalImagePath(source: String): String? =
    ConversationFileReferenceDetector.imageReferences(source, limit = 1).firstOrNull()?.path

internal fun isAllowedMarkdownImage(value: String): Boolean =
    value.startsWith("https://", true) ||
        value.startsWith("http://", true) ||
        value.startsWith("data:image/", true)

private fun Node.children(): Sequence<Node> = sequence {
    var child = firstChild
    while (child != null) {
        yield(child)
        child = child.next
    }
}
