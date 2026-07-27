package com.gaixianggeng.mimi.ui

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownMessageTest {
    @Test
    fun `parses fenced code without losing language or newlines`() {
        val blocks = parseMarkdown("```kotlin\nval answer = 42\nprintln(answer)\n```")

        val code = blocks.single() as MarkdownBlock.Code
        assertEquals("kotlin", code.language)
        assertEquals("val answer = 42\nprintln(answer)", code.body)
    }

    @Test
    fun `parses gfm table and omits delimiter row`() {
        val table = parseMarkdown("""
            | Name | State |
            | --- | :---: |
            | QR | Ready |
        """.trimIndent()).single() as MarkdownBlock.Table

        assertEquals(2, table.rows.size)
        assertEquals(listOf("Name", "State"), table.rows.first())
        assertEquals(listOf(MarkdownColumnAlignment.Leading, MarkdownColumnAlignment.Center), table.alignments)
    }

    @Test
    fun `parses checked and unchecked task list`() {
        val tasks = (parseMarkdown("- [x] built\n- [ ] device test").single() as MarkdownBlock.BulletList).items

        assertTrue(tasks.first().checked == true)
        assertFalse(tasks.last().checked == true)
    }

    @Test
    fun `parses gateway history media image as an image block`() {
        val image = parseMarkdown("![generated chart](agentd-history-media://media-123)").single() as MarkdownBlock.Image

        assertEquals("generated chart", image.alt)
        assertEquals("agentd-history-media://media-123", image.source)
    }

    @Test
    fun `parses local image title and normalizes file uri for preview`() {
        val image = parseMarkdown("""![architecture](file:///Users/me/diagram.png "Current plan")""")
            .single() as MarkdownBlock.Image

        assertEquals("architecture", image.alt)
        assertEquals("file:///Users/me/diagram.png", image.source)
        assertEquals("Current plan", image.title)
        assertEquals("/Users/me/diagram.png", markdownLocalImagePath(image.source))
    }

    @Test
    fun `parses setext headings`() {
        val blocks = parseMarkdown("Primary\n=======\n\nSecondary\n---")

        assertEquals(1, (blocks[0] as MarkdownBlock.Heading).level)
        assertEquals("Primary", (blocks[0] as MarkdownBlock.Heading).text)
        assertEquals(2, (blocks[1] as MarkdownBlock.Heading).level)
        assertEquals("Secondary", (blocks[1] as MarkdownBlock.Heading).text)
    }

    @Test
    fun `parses ordered list markers`() {
        val list = parseMarkdown("1. first\n2. second").single() as MarkdownBlock.OrderedList

        assertEquals(1, list.start)
        assertEquals(
            listOf("first", "second"),
            list.items.map { (it.blocks.single() as MarkdownBlock.Paragraph).text },
        )
    }

    @Test
    fun `parses complete proposed plan and keeps following markdown`() {
        val blocks = parseMarkdown(
            """
            Before
            <proposed_plan>
            ## Fix plan

            1. Verify
            2. Test
            </proposed_plan>
            After **done**
            """.trimIndent(),
        )

        assertEquals("Before", (blocks[0] as MarkdownBlock.Paragraph).text)
        val plan = blocks[1] as MarkdownBlock.ProposedPlan
        assertTrue(plan.isComplete)
        assertEquals("Fix plan", (plan.blocks[0] as MarkdownBlock.Heading).text)
        assertEquals("After **done**", (blocks[2] as MarkdownBlock.Paragraph).text)
    }

    @Test
    fun `parses streaming proposed plan with open tail`() {
        val plan = parseMarkdown(
            """
            <proposed_plan>
            - first
            - second
            """.trimIndent(),
        ).single() as MarkdownBlock.ProposedPlan

        assertFalse(plan.isComplete)
        val list = plan.blocks.single() as MarkdownBlock.BulletList
        assertEquals(
            listOf("first", "second"),
            list.items.map { (it.blocks.single() as MarkdownBlock.Paragraph).text },
        )
    }

    @Test
    fun `does not treat inline proposed plan tags as a wrapper`() {
        val paragraph = parseMarkdown("Before <proposed_plan> plain </proposed_plan>").single() as MarkdownBlock.Paragraph

        assertEquals("Before <proposed_plan> plain </proposed_plan>", inlineMarkdown(paragraph.text, Color.Blue).text)
    }

    @Test
    fun `keeps nested list structure and mixed task state`() {
        val list = parseMarkdown(
            """
            - [x] completed
            - regular
              - [ ] nested
            """.trimIndent(),
        ).single() as MarkdownBlock.BulletList

        assertEquals(listOf(true, null), list.items.map(MarkdownListItem::checked))
        val nested = list.items[1].blocks[1] as MarkdownBlock.BulletList
        assertEquals(false, nested.items.single().checked)
        assertEquals(
            "nested",
            inlineMarkdown((nested.items.single().blocks.single() as MarkdownBlock.Paragraph).text, Color.Blue).text,
        )
    }

    @Test
    fun `parses multiline blockquote and indented code`() {
        val blocks = parseMarkdown(
            """
            > first line
            > second **bold** line

                indented()
            """.trimIndent(),
        )

        val quote = blocks[0] as MarkdownBlock.Quote
        val quoteText = (quote.blocks.single() as MarkdownBlock.Paragraph).text
        assertEquals("first line\nsecond bold line", inlineMarkdown(quoteText, Color.Blue).text)
        assertEquals("indented()", (blocks[1] as MarkdownBlock.Code).body)
    }

    @Test
    fun `supports nested inline formatting and escaped table pipes`() {
        val rich = inlineMarkdown("**bold *nested*** and ~~removed~~", Color.Blue)
        assertEquals("bold nested and removed", rich.text)
        assertTrue(rich.spanStyles.any { it.item.fontWeight != null })
        assertTrue(rich.spanStyles.any { it.item.fontStyle != null })
        assertTrue(rich.spanStyles.any { it.item.textDecoration != null })

        val table = parseMarkdown(
            """
            | Value |
            | --- |
            | a \| b |
            """.trimIndent(),
        ).single() as MarkdownBlock.Table
        assertEquals("a | b", inlineMarkdown(table.rows[1][0], Color.Blue).text)
    }
}
