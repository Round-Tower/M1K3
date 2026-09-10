//
//  ChatTemplateTraitsTests.swift
//  M1K3MLXTests
//
//  The reasoning traits read off template TEXT (#264): snippets are the real
//  generation-prompt blocks of the templates on disk, 2026-09-10.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-10, Confidence 0.85, Prior: Unknown.
//

import Foundation
@testable import M1K3MLX
import Testing

struct ChatTemplateTraitsTests {
    private let qwen35Style = """
    {%- endfor %}
    {%- if add_generation_prompt %}
        {{- '<|im_start|>assistant\\n' }}
        {%- if enable_thinking is defined and enable_thinking is false %}
            {{- '<think>\\n\\n</think>\\n\\n' }}
        {%- else %}
            {{- '<think>\\n' }}
        {%- endif %}
    {%- endif %}
    """

    private let lfm26Style = """
    {%- endfor -%}
    {%- if add_generation_prompt -%}
        {{- "<|im_start|>assistant\\n<think>" -}}
    {%- endif -%}
    """

    private let qwen2507Style = """
    {%- endfor %}
    {%- if add_generation_prompt %}
        {{- '<|im_start|>assistant\\n' }}
    {%- endif %}
    """

    private let gemma4Style = """
    {%- if add_generation_prompt -%}
        {{- '<|turn>model\\n' -}}
        {%- if not enable_thinking -%}
            {{- '<|channel>thought\\n<channel|>' -}}
        {%- endif -%}
    {%- endif -%}
    """

    @Test("Qwen3.5 / Qwen3.8 / Ornith: pre-opens <think> and reads enable_thinking")
    func qwen35PreOpensWithToggle() {
        #expect(ChatTemplateTraits(template: qwen35Style)
            == ChatTemplateTraits(preOpensThink: true, supportsThinkingToggle: true))
    }

    @Test("LFM2.5-2.6B: pre-opens <think> inside the assistant literal, no toggle")
    func lfmPreOpensNoToggle() {
        #expect(ChatTemplateTraits(template: lfm26Style)
            == ChatTemplateTraits(preOpensThink: true, supportsThinkingToggle: false))
    }

    @Test("Qwen3-2507: no think tags, no toggle")
    func qwen2507Plain() {
        #expect(ChatTemplateTraits(template: qwen2507Style)
            == ChatTemplateTraits(preOpensThink: false, supportsThinkingToggle: false))
    }

    @Test("gemma-4: reads enable_thinking but never emits <think> — no pre-open")
    func gemma4ToggleNoPreOpen() {
        #expect(ChatTemplateTraits(template: gemma4Style)
            == ChatTemplateTraits(preOpensThink: false, supportsThinkingToggle: true))
    }

    @Test("a closed pair earlier in the template does not count; only the generation block is read")
    func onlyTheGenerationBlockCounts() {
        // A think pair emitted for HISTORY turns, then a plain generation prompt.
        let history = """
        {%- if message.reasoning %}{{- '<think>\\n' + message.reasoning + '\\n</think>\\n' }}{%- endif %}
        """ + qwen2507Style
        #expect(ChatTemplateTraits(template: history)?.preOpensThink == false)
    }

    @Test("no generation-prompt block at all: not a chat template we can read")
    func notATemplate() {
        #expect(ChatTemplateTraits(template: "") == nil)
        #expect(ChatTemplateTraits(template: "{{ bos_token }}{{ messages[0].content }}") == nil)
    }
}
