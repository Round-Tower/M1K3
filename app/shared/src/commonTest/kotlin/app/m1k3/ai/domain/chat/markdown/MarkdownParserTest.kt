package app.m1k3.ai.domain.chat.markdown

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * TDD Tests for MarkdownParser
 *
 * Tests pure Kotlin markdown-to-AST conversion.
 * No platform dependencies — runs on JVM, iOS, JS.
 */
class MarkdownParserTest {

    private val parser = MarkdownParser()

    // ===== Plain Text =====

    @Test
    fun `plain text returns single Text node`() {
        val nodes = parser.parse("Hello world")
        assertEquals(1, nodes.size)
        val paragraph = nodes[0] as MarkdownNode.Paragraph
        assertEquals(1, paragraph.children.size)
        assertEquals("Hello world", (paragraph.children[0] as MarkdownNode.Text).content)
    }

    @Test
    fun `empty string returns empty list`() {
        val nodes = parser.parse("")
        assertTrue(nodes.isEmpty())
    }

    @Test
    fun `whitespace only returns empty list`() {
        val nodes = parser.parse("   ")
        assertTrue(nodes.isEmpty())
    }

    // ===== Bold =====

    @Test
    fun `double asterisks produce bold node`() {
        val nodes = parser.parse("Hello **world**")
        val paragraph = nodes[0] as MarkdownNode.Paragraph
        assertEquals(2, paragraph.children.size)
        assertEquals("Hello ", (paragraph.children[0] as MarkdownNode.Text).content)
        val bold = paragraph.children[1] as MarkdownNode.Bold
        assertEquals("world", (bold.children[0] as MarkdownNode.Text).content)
    }

    @Test
    fun `double underscores produce bold node`() {
        val nodes = parser.parse("Hello __world__")
        val paragraph = nodes[0] as MarkdownNode.Paragraph
        val bold = paragraph.children[1] as MarkdownNode.Bold
        assertEquals("world", (bold.children[0] as MarkdownNode.Text).content)
    }

    // ===== Italic =====

    @Test
    fun `single asterisk produces italic node`() {
        val nodes = parser.parse("Hello *world*")
        val paragraph = nodes[0] as MarkdownNode.Paragraph
        assertEquals(2, paragraph.children.size)
        val italic = paragraph.children[1] as MarkdownNode.Italic
        assertEquals("world", (italic.children[0] as MarkdownNode.Text).content)
    }

    @Test
    fun `single underscore produces italic node`() {
        val nodes = parser.parse("Hello _world_")
        val paragraph = nodes[0] as MarkdownNode.Paragraph
        val italic = paragraph.children[1] as MarkdownNode.Italic
        assertEquals("world", (italic.children[0] as MarkdownNode.Text).content)
    }

    // ===== Underscore word-boundary (CommonMark left/right-flanking) =====

    @Test
    fun `intra-word underscores stay literal`() {
        // snake_case, file paths, dunders — the most common real corruption.
        val nodes = parser.parse("The file_name_here is fine")
        val paragraph = nodes[0] as MarkdownNode.Paragraph
        val text = paragraph.children.joinToString("") { (it as MarkdownNode.Text).content }
        assertEquals("The file_name_here is fine", text)
        assertTrue(paragraph.children.none { it is MarkdownNode.Italic || it is MarkdownNode.Bold })
    }

    @Test
    fun `snake_case identifier stays literal`() {
        // A single underscore flanked by word chars on BOTH sides never emphasizes.
        val nodes = parser.parse("set the max_tokens value")
        val paragraph = nodes[0] as MarkdownNode.Paragraph
        assertTrue(paragraph.children.none { it is MarkdownNode.Italic || it is MarkdownNode.Bold })
        val text = paragraph.children.joinToString("") { (it as MarkdownNode.Text).content }
        assertEquals("set the max_tokens value", text)
    }

    @Test
    fun `close underscore followed by word char does not emphasize`() {
        // "_b_c" — the closing underscore hugs a word char, so it is not a valid closer.
        val nodes = parser.parse("a _b_c d")
        val paragraph = nodes[0] as MarkdownNode.Paragraph
        assertTrue(paragraph.children.none { it is MarkdownNode.Italic })
    }

    @Test
    fun `underscore emphasis still works at word boundaries`() {
        val nodes = parser.parse("say _hi_ now")
        val paragraph = nodes[0] as MarkdownNode.Paragraph
        val italic = paragraph.children.firstOrNull { it is MarkdownNode.Italic } as? MarkdownNode.Italic
        assertTrue(italic != null, "boundary underscore should still italicize")
        assertEquals("hi", (italic.children[0] as MarkdownNode.Text).content)
    }

    // ===== Bold + Italic =====

    @Test
    fun `triple asterisks produce bold italic node`() {
        val nodes = parser.parse("Hello ***world***")
        val paragraph = nodes[0] as MarkdownNode.Paragraph
        val boldItalic = paragraph.children[1] as MarkdownNode.BoldItalic
        assertEquals("world", (boldItalic.children[0] as MarkdownNode.Text).content)
    }

    // ===== Inline Code =====

    @Test
    fun `backticks produce inline code node`() {
        val nodes = parser.parse("Use `println()` here")
        val paragraph = nodes[0] as MarkdownNode.Paragraph
        assertEquals(3, paragraph.children.size)
        assertEquals("Use ", (paragraph.children[0] as MarkdownNode.Text).content)
        assertEquals("println()", (paragraph.children[1] as MarkdownNode.InlineCode).code)
        assertEquals(" here", (paragraph.children[2] as MarkdownNode.Text).content)
    }

    @Test
    fun `inline code preserves asterisks literally`() {
        val nodes = parser.parse("Use `**not bold**` here")
        val paragraph = nodes[0] as MarkdownNode.Paragraph
        assertEquals("**not bold**", (paragraph.children[1] as MarkdownNode.InlineCode).code)
    }

    // ===== Code Blocks =====

    @Test
    fun `fenced code block with language`() {
        val input = """
Some text

```kotlin
fun main() {
    println("hello")
}
```
""".trimIndent()
        val nodes = parser.parse(input)
        assertEquals(2, nodes.size)
        assertTrue(nodes[0] is MarkdownNode.Paragraph)
        val codeBlock = nodes[1] as MarkdownNode.CodeBlock
        assertEquals("kotlin", codeBlock.language)
        assertTrue(codeBlock.code.contains("fun main()"))
        assertTrue(codeBlock.code.contains("println"))
    }

    @Test
    fun `fenced code block without language`() {
        val input = """
```
some code
```
""".trimIndent()
        val nodes = parser.parse(input)
        val codeBlock = nodes[0] as MarkdownNode.CodeBlock
        assertEquals(null, codeBlock.language)
        assertEquals("some code", codeBlock.code)
    }

    @Test
    fun `code block preserves internal blank lines`() {
        val input = """
```
line 1

line 3
```
""".trimIndent()
        val nodes = parser.parse(input)
        val codeBlock = nodes[0] as MarkdownNode.CodeBlock
        assertTrue(codeBlock.code.contains("\n\n"))
    }

    // ===== Headings =====

    @Test
    fun `h1 heading`() {
        val nodes = parser.parse("# Hello World")
        assertEquals(1, nodes.size)
        val heading = nodes[0] as MarkdownNode.Heading
        assertEquals(1, heading.level)
        assertEquals("Hello World", (heading.children[0] as MarkdownNode.Text).content)
    }

    @Test
    fun `h2 heading`() {
        val nodes = parser.parse("## Section")
        val heading = nodes[0] as MarkdownNode.Heading
        assertEquals(2, heading.level)
    }

    @Test
    fun `h3 heading`() {
        val nodes = parser.parse("### Sub-section")
        val heading = nodes[0] as MarkdownNode.Heading
        assertEquals(3, heading.level)
    }

    @Test
    fun `heading with inline formatting`() {
        val nodes = parser.parse("## Hello **bold** world")
        val heading = nodes[0] as MarkdownNode.Heading
        assertEquals(3, heading.children.size)
        assertTrue(heading.children[1] is MarkdownNode.Bold)
    }

    // ===== Unordered Lists =====

    @Test
    fun `unordered list with dash`() {
        val input = """
- First item
- Second item
- Third item
""".trimIndent()
        val nodes = parser.parse(input)
        assertEquals(3, nodes.size)
        nodes.forEachIndexed { index, node ->
            val item = node as MarkdownNode.ListItem
            assertEquals(false, item.ordered)
        }
        val first = (nodes[0] as MarkdownNode.ListItem).children[0] as MarkdownNode.Text
        assertEquals("First item", first.content)
    }

    @Test
    fun `unordered list with asterisk`() {
        val nodes = parser.parse("* Item one")
        val item = nodes[0] as MarkdownNode.ListItem
        assertEquals(false, item.ordered)
        assertEquals("Item one", (item.children[0] as MarkdownNode.Text).content)
    }

    // ===== Ordered Lists =====

    @Test
    fun `ordered list`() {
        val input = """
1. First
2. Second
3. Third
""".trimIndent()
        val nodes = parser.parse(input)
        assertEquals(3, nodes.size)
        val first = nodes[0] as MarkdownNode.ListItem
        assertEquals(true, first.ordered)
        assertEquals(1, first.index)
        val third = nodes[2] as MarkdownNode.ListItem
        assertEquals(3, third.index)
    }

    // ===== Multiple Paragraphs =====

    @Test
    fun `blank line separates paragraphs`() {
        val input = """
First paragraph.

Second paragraph.
""".trimIndent()
        val nodes = parser.parse(input)
        assertEquals(2, nodes.size)
        assertTrue(nodes[0] is MarkdownNode.Paragraph)
        assertTrue(nodes[1] is MarkdownNode.Paragraph)
    }

    // ===== Mixed Content =====

    @Test
    fun `heading then paragraph then code block`() {
        val input = """
## Title

Some explanation here.

```kotlin
val x = 42
```
""".trimIndent()
        val nodes = parser.parse(input)
        assertEquals(3, nodes.size)
        assertTrue(nodes[0] is MarkdownNode.Heading)
        assertTrue(nodes[1] is MarkdownNode.Paragraph)
        assertTrue(nodes[2] is MarkdownNode.CodeBlock)
    }

    @Test
    fun `list items with inline formatting`() {
        val nodes = parser.parse("- Use **bold** for emphasis")
        val item = nodes[0] as MarkdownNode.ListItem
        assertEquals(3, item.children.size)
        assertEquals("Use ", (item.children[0] as MarkdownNode.Text).content)
        assertTrue(item.children[1] is MarkdownNode.Bold)
        assertEquals(" for emphasis", (item.children[2] as MarkdownNode.Text).content)
    }

    // ===== Edge Cases =====

    @Test
    fun `unclosed bold marker treated as plain text`() {
        val nodes = parser.parse("Hello **world")
        val paragraph = nodes[0] as MarkdownNode.Paragraph
        // Should not crash, treat as plain text
        assertTrue(paragraph.children.isNotEmpty())
    }

    @Test
    fun `unclosed inline code treated as plain text`() {
        val nodes = parser.parse("Use `println here")
        val paragraph = nodes[0] as MarkdownNode.Paragraph
        assertTrue(paragraph.children.isNotEmpty())
    }

    @Test
    fun `unclosed code block consumes rest of input`() {
        val input = """
```kotlin
val x = 42
no closing fence
""".trimIndent()
        val nodes = parser.parse(input)
        // Should still produce a code block with available content
        assertTrue(nodes.any { it is MarkdownNode.CodeBlock })
    }

    @Test
    fun `hash without space is not a heading`() {
        val nodes = parser.parse("#hashtag is not a heading")
        assertTrue(nodes[0] is MarkdownNode.Paragraph)
    }

    @Test
    fun `multiple inline styles in one line`() {
        val nodes = parser.parse("Hello **bold** and *italic* and `code`")
        val paragraph = nodes[0] as MarkdownNode.Paragraph
        // "Hello ", Bold, " and ", Italic, " and ", InlineCode
        assertEquals(6, paragraph.children.size)
        assertTrue(paragraph.children[1] is MarkdownNode.Bold)
        assertTrue(paragraph.children[3] is MarkdownNode.Italic)
        assertTrue(paragraph.children[5] is MarkdownNode.InlineCode)
    }

    @Test
    fun `adjacent lines without blank line form single paragraph`() {
        val input = """
Line one
Line two
Line three
""".trimIndent()
        val nodes = parser.parse(input)
        assertEquals(1, nodes.size)
        assertTrue(nodes[0] is MarkdownNode.Paragraph)
    }
}
