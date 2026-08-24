package app.m1k3.ai.domain.chat.markdown

/**
 * Markdown AST nodes.
 *
 * Pure Kotlin sealed hierarchy — no platform dependencies.
 * Designed for rendering by Compose, SwiftUI, or any UI framework.
 */
sealed class MarkdownNode {
    data class Text(
        val content: String,
    ) : MarkdownNode()

    data class Bold(
        val children: List<MarkdownNode>,
    ) : MarkdownNode()

    data class Italic(
        val children: List<MarkdownNode>,
    ) : MarkdownNode()

    data class BoldItalic(
        val children: List<MarkdownNode>,
    ) : MarkdownNode()

    data class InlineCode(
        val code: String,
    ) : MarkdownNode()

    data class CodeBlock(
        val code: String,
        val language: String?,
    ) : MarkdownNode()

    data class Heading(
        val level: Int,
        val children: List<MarkdownNode>,
    ) : MarkdownNode()

    data class ListItem(
        val children: List<MarkdownNode>,
        val ordered: Boolean,
        val index: Int? = null,
    ) : MarkdownNode()

    data class Paragraph(
        val children: List<MarkdownNode>,
    ) : MarkdownNode()

    object LineBreak : MarkdownNode()
}

/**
 * Markdown text → AST parser.
 *
 * Converts markdown-formatted strings into a list of [MarkdownNode]s.
 * Supports: bold, italic, bold+italic, inline code, fenced code blocks,
 * headings (h1-h3), ordered/unordered lists, paragraphs.
 *
 * Pure Kotlin — no regex where avoidable, no platform deps.
 */
class MarkdownParser {
    fun parse(text: String): List<MarkdownNode> {
        if (text.isBlank()) return emptyList()
        val blocks = splitBlocks(text)
        return blocks.mapNotNull { parseBlock(it) }
    }

    // ===== Block-Level Parsing =====

    private fun splitBlocks(text: String): List<BlockRaw> {
        val blocks = mutableListOf<BlockRaw>()
        val lines = text.lines()
        var i = 0

        while (i < lines.size) {
            val line = lines[i]

            // Fenced code block
            if (line.trimStart().startsWith("```")) {
                val fence = line.trimStart()
                val lang = fence.removePrefix("```").trim().ifEmpty { null }
                val codeLines = mutableListOf<String>()
                i++
                var closed = false
                while (i < lines.size) {
                    if (lines[i].trimStart().startsWith("```")) {
                        closed = true
                        i++
                        break
                    }
                    codeLines.add(lines[i])
                    i++
                }
                blocks.add(BlockRaw.Code(codeLines.joinToString("\n"), lang))
                continue
            }

            // Skip blank lines (they separate blocks)
            if (line.isBlank()) {
                i++
                continue
            }

            // Heading: # with space
            if (line.matches(Regex("^#{1,6} .+"))) {
                blocks.add(BlockRaw.HeadingLine(line))
                i++
                continue
            }

            // Unordered list item: - or *
            if (line.matches(Regex("^[-*] .+"))) {
                blocks.add(BlockRaw.UnorderedListLine(line))
                i++
                continue
            }

            // Ordered list item: 1. 2. etc.
            if (line.matches(Regex("^\\d+\\. .+"))) {
                blocks.add(BlockRaw.OrderedListLine(line))
                i++
                continue
            }

            // Paragraph: collect consecutive non-blank, non-special lines
            val paragraphLines = mutableListOf<String>()
            while (i < lines.size && lines[i].isNotBlank() &&
                !lines[i].matches(Regex("^#{1,6} .+")) &&
                !lines[i].matches(Regex("^[-*] .+")) &&
                !lines[i].matches(Regex("^\\d+\\. .+")) &&
                !lines[i].trimStart().startsWith("```")
            ) {
                paragraphLines.add(lines[i])
                i++
            }
            if (paragraphLines.isNotEmpty()) {
                blocks.add(BlockRaw.ParagraphLines(paragraphLines.joinToString(" ")))
            }
        }

        return blocks
    }

    private fun parseBlock(block: BlockRaw): MarkdownNode? =
        when (block) {
            is BlockRaw.Code -> {
                MarkdownNode.CodeBlock(block.code, block.language)
            }

            is BlockRaw.HeadingLine -> {
                val level = block.line.takeWhile { it == '#' }.length
                val content = block.line.drop(level).trimStart()
                MarkdownNode.Heading(level, parseInline(content))
            }

            is BlockRaw.UnorderedListLine -> {
                val content = block.line.drop(2) // "- " or "* "
                MarkdownNode.ListItem(parseInline(content), ordered = false)
            }

            is BlockRaw.OrderedListLine -> {
                val dotIndex = block.line.indexOf(". ")
                val index = block.line.substring(0, dotIndex).toIntOrNull()
                val content = block.line.substring(dotIndex + 2)
                MarkdownNode.ListItem(parseInline(content), ordered = true, index = index)
            }

            is BlockRaw.ParagraphLines -> {
                val children = parseInline(block.text)
                if (children.isEmpty()) {
                    null
                } else {
                    MarkdownNode.Paragraph(children)
                }
            }
        }

    // ===== Inline Parsing =====

    /**
     * Parse inline markdown: bold, italic, bold+italic, inline code.
     *
     * Strategy: scan character by character, match markers greedily.
     * Inline code (backtick) takes priority — content inside is literal.
     */
    fun parseInline(text: String): List<MarkdownNode> {
        val nodes = mutableListOf<MarkdownNode>()
        val buffer = StringBuilder()
        var i = 0

        fun flushBuffer() {
            if (buffer.isNotEmpty()) {
                nodes.add(MarkdownNode.Text(buffer.toString()))
                buffer.clear()
            }
        }

        while (i < text.length) {
            val c = text[i]

            // Inline code: highest priority
            if (c == '`') {
                val closeIdx = text.indexOf('`', i + 1)
                if (closeIdx != -1) {
                    flushBuffer()
                    nodes.add(MarkdownNode.InlineCode(text.substring(i + 1, closeIdx)))
                    i = closeIdx + 1
                    continue
                }
                // Unclosed backtick — treat as literal
                buffer.append(c)
                i++
                continue
            }

            // Bold/Italic markers: *** ** *  or ___ __ _
            if (c == '*' || c == '_') {
                val marker = c

                // CommonMark intraword rule for `_`: an underscore run can only
                // OPEN emphasis at a left word-boundary. A `_` hugging a letter
                // or digit on its left (snake_case, file_name_here, max_tokens)
                // is a word-joiner, not a delimiter — emit it literally.
                if (marker == '_' && i > 0 && text[i - 1].isLetterOrDigit()) {
                    buffer.append(c)
                    i++
                    continue
                }

                var markerLen = 0
                var j = i
                while (j < text.length && text[j] == marker) {
                    markerLen++
                    j++
                }

                // Try triple (bold+italic)
                if (markerLen >= 3) {
                    val closeIdx = findClosingMarker(text, j, marker.toString().repeat(3))
                    if (closeIdx != -1) {
                        flushBuffer()
                        val inner = text.substring(j, closeIdx)
                        nodes.add(MarkdownNode.BoldItalic(parseInline(inner)))
                        i = closeIdx + 3
                        continue
                    }
                }

                // Try double (bold)
                if (markerLen >= 2) {
                    val closeIdx = findClosingMarker(text, i + 2, marker.toString().repeat(2))
                    if (closeIdx != -1) {
                        flushBuffer()
                        val inner = text.substring(i + 2, closeIdx)
                        nodes.add(MarkdownNode.Bold(parseInline(inner)))
                        i = closeIdx + 2
                        continue
                    }
                }

                // Try single (italic)
                if (markerLen >= 1) {
                    val closeIdx = findClosingMarker(text, i + 1, marker.toString())
                    if (closeIdx != -1) {
                        flushBuffer()
                        val inner = text.substring(i + 1, closeIdx)
                        nodes.add(MarkdownNode.Italic(parseInline(inner)))
                        i = closeIdx + 1
                        continue
                    }
                }

                // No closing marker found — treat as literal
                buffer.append(c)
                i++
                continue
            }

            buffer.append(c)
            i++
        }

        flushBuffer()
        return nodes
    }

    private fun findClosingMarker(
        text: String,
        startFrom: Int,
        marker: String,
    ): Int {
        val isUnderscore = marker[0] == '_'
        var idx = startFrom
        while (idx <= text.length - marker.length) {
            if (text.substring(idx, idx + marker.length) == marker) {
                // CommonMark intraword rule for `_`: a closer hugging a letter
                // or digit on its right (e.g. "_b_c") is not a valid closer.
                val after = idx + marker.length
                if (!(isUnderscore && after < text.length && text[after].isLetterOrDigit())) {
                    return idx
                }
            }
            // Skip backtick spans (inline code takes priority)
            if (text[idx] == '`') {
                val closeBacktick = text.indexOf('`', idx + 1)
                if (closeBacktick != -1) {
                    idx = closeBacktick + 1
                    continue
                }
            }
            idx++
        }
        return -1
    }

    // ===== Internal Block Types =====

    private sealed class BlockRaw {
        data class Code(
            val code: String,
            val language: String?,
        ) : BlockRaw()

        data class HeadingLine(
            val line: String,
        ) : BlockRaw()

        data class UnorderedListLine(
            val line: String,
        ) : BlockRaw()

        data class OrderedListLine(
            val line: String,
        ) : BlockRaw()

        data class ParagraphLines(
            val text: String,
        ) : BlockRaw()
    }
}
