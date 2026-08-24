package app.m1k3.ai.assistant.avatar

import app.m1k3.ai.domain.tools.ToolCategory
import kotlin.test.Test
import kotlin.test.assertEquals

class ToolEmotionMapTest {
    @Test
    fun `flashlight toggle is EXCITED on success`() {
        val emotion = ToolEmotionMap.emotionFor("toggle_flashlight", ToolCategory.SYSTEM, success = true)
        assertEquals(AvatarEmotion.EXCITED, emotion)
    }

    @Test
    fun `web search is THINKING on success`() {
        val emotion = ToolEmotionMap.emotionFor("web_search", ToolCategory.KNOWLEDGE, success = true)
        assertEquals(AvatarEmotion.THINKING, emotion)
    }

    @Test
    fun `app launcher is HAPPY on success`() {
        val emotion = ToolEmotionMap.emotionFor("open_camera", ToolCategory.APPS, success = true)
        assertEquals(AvatarEmotion.HAPPY, emotion)
    }

    @Test
    fun `timer and alarm are EXCITED on success`() {
        assertEquals(AvatarEmotion.EXCITED, ToolEmotionMap.emotionFor("set_timer", ToolCategory.SYSTEM, success = true))
        assertEquals(AvatarEmotion.EXCITED, ToolEmotionMap.emotionFor("set_alarm", ToolCategory.SYSTEM, success = true))
    }

    @Test
    fun `any failure is SAD`() {
        val emotion = ToolEmotionMap.emotionFor("toggle_flashlight", ToolCategory.SYSTEM, success = false)
        assertEquals(AvatarEmotion.SAD, emotion)
    }

    @Test
    fun `unknown tool in KNOWLEDGE falls back to THINKING`() {
        val emotion = ToolEmotionMap.emotionFor("deep_research_42", ToolCategory.KNOWLEDGE, success = true)
        assertEquals(AvatarEmotion.THINKING, emotion)
    }

    @Test
    fun `unknown tool in SYSTEM falls back to HAPPY`() {
        val emotion = ToolEmotionMap.emotionFor("do_something", ToolCategory.SYSTEM, success = true)
        assertEquals(AvatarEmotion.HAPPY, emotion)
    }

    @Test
    fun `unknown tool with no category is NEUTRAL`() {
        val emotion = ToolEmotionMap.emotionFor("unknown", null, success = true)
        assertEquals(AvatarEmotion.NEUTRAL, emotion)
    }
}
