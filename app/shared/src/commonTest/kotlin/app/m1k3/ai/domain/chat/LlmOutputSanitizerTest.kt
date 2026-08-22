package app.m1k3.ai.domain.chat

import kotlin.test.Test
import kotlin.test.assertEquals

class LlmOutputSanitizerTest {
    @Test
    fun `passes plain text through unchanged`() {
        assertEquals(
            "Hello world",
            LlmOutputSanitizer.strip("Hello world"),
        )
    }

    @Test
    fun `drops complete think block with content`() {
        val raw = "Before <think>reasoning here</think> After"
        assertEquals("Before  After", LlmOutputSanitizer.strip(raw))
    }

    @Test
    fun `drops orphan closing think tag left by the model`() {
        // Seen in Qwen3.5 native-chat path: model emits a closer without an opener.
        val raw = "The user is asking for X. </think> Here is the answer."
        assertEquals("The user is asking for X.  Here is the answer.", LlmOutputSanitizer.strip(raw))
    }

    @Test
    fun `drops orphan opening think tag without a closer`() {
        val raw = "Answer text <think>and some trailing reasoning"
        assertEquals("Answer text", LlmOutputSanitizer.strip(raw))
    }

    @Test
    fun `drops complete tool_call xml block`() {
        val raw = "I should call the tool. <tool_call>{\"name\":\"web_search\"}</tool_call> Done."
        assertEquals("I should call the tool.  Done.", LlmOutputSanitizer.strip(raw))
    }

    @Test
    fun `drops stray tool_call and closing tag`() {
        val raw = "<tool_call>partial"
        assertEquals("partial", LlmOutputSanitizer.strip(raw))
    }

    @Test
    fun `handles qwen3_5 interleaved think and tool_call tags seen in native chat path`() {
        // Literal capture from logcat 2026-04-19 — Qwen3.5 0.8B emitted this:
        val raw =
            "</think>\n<tool_call>\n</think>\n<tool_call>\n</tool_call>\n<think>\n<think>\n</think>\n<tool_call>\n</tool_call>\nCork is the second-largest city."
        assertEquals("Cork is the second-largest city.", LlmOutputSanitizer.strip(raw).trim())
    }

    @Test
    fun `handles tokenizer space variants like slash space think`() {
        val raw = "Answer < / think > here"
        assertEquals("Answer  here", LlmOutputSanitizer.strip(raw))
    }

    @Test
    fun `collapses three or more consecutive blank lines left by stripped tags`() {
        val raw = "One\n\n\n\n\nTwo"
        assertEquals("One\n\nTwo", LlmOutputSanitizer.strip(raw))
    }

    @Test
    fun `handles empty input`() {
        assertEquals("", LlmOutputSanitizer.strip(""))
    }

    @Test
    fun `drops qwen bare function call xml without tool_call wrapper`() {
        // Captured on Pixel 9a 2026-04-19: Qwen3.5 sometimes emits the function
        // call XML directly without the <tool_call> envelope.
        val raw = "<function=web_search><parameter=query>how to cook a 5lb chicken</parameter></function>"
        assertEquals("", LlmOutputSanitizer.strip(raw))
    }

    @Test
    fun `drops qwen function call xml with surrounding prose`() {
        val raw =
            "Let me check. <function=web_search><parameter=query>cork city</parameter></function> Done."
        assertEquals("Let me check.  Done.", LlmOutputSanitizer.strip(raw))
    }

    @Test
    fun `drops stray parameter tags outside a function block`() {
        val raw = "<parameter=query>orphan</parameter> text"
        assertEquals("text", LlmOutputSanitizer.strip(raw).trim())
    }

    @Test
    fun `drops chatml im_start assistant prefix that leaks from common_chat_parse`() {
        // Captured on Pixel 9a 2026-04-20: Qwen3.5 0.8B native-chat path — common_chat_parse
        // returns msg.content with the assistant template prefix still attached when the PEG
        // parser's <|im_start|>assistant anchor slips against the raw accumulated stream.
        val raw = "<|im_start|>assistant\n<think>\nreasoning here\n</think>\nThe answer."
        assertEquals("The answer.", LlmOutputSanitizer.strip(raw).trim())
    }

    @Test
    fun `drops chatml im_end closing marker`() {
        val raw = "Final answer.<|im_end|>"
        assertEquals("Final answer.", LlmOutputSanitizer.strip(raw))
    }

    @Test
    fun `drops chatml im_start variants for any role`() {
        assertEquals("hi", LlmOutputSanitizer.strip("<|im_start|>user\nhi").trim())
        assertEquals("hi", LlmOutputSanitizer.strip("<|im_start|>system\nhi").trim())
        assertEquals("hi", LlmOutputSanitizer.strip("<|im_start|>tool\nhi").trim())
    }

    @Test
    fun `drops bare im_start with no role attached`() {
        // Defensive: if tokenizer split the role off, strip the marker alone
        val raw = "<|im_start|>hi"
        assertEquals("hi", LlmOutputSanitizer.strip(raw).trim())
    }

    @Test
    fun `drops im_start with whitespace before the role (the No dot system echo, F8b)`() {
        // The model answered "No.", then began a fresh system turn as
        // "<|im_start|>\nsystem ..." — a newline between the marker and the
        // role. The old regex put \s* AFTER the role group, so the role never
        // matched and the bare word "system" leaked to the UI (Pixel 9a
        // 2026-08-22, "No.system You are M1K3 —…"). \s* now precedes the role.
        assertEquals("hi", LlmOutputSanitizer.strip("<|im_start|>\nsystem\nhi").trim())
        assertEquals("No.", LlmOutputSanitizer.strip("No.<|im_start|>\nsystem\n").trim())
    }

    @Test
    fun `preserves plain text containing angle brackets unrelated to chat markers`() {
        val raw = "Use <code>foo()</code> to call the function."
        assertEquals(
            "Use <code>foo()</code> to call the function.",
            LlmOutputSanitizer.strip(raw),
        )
    }
}
