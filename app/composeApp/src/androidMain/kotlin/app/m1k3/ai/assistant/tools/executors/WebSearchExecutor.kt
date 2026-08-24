package app.m1k3.ai.assistant.tools.executors

import app.m1k3.ai.domain.tools.ToolCall
import app.m1k3.ai.domain.tools.ToolError
import app.m1k3.ai.domain.tools.ToolResult
import app.m1k3.ai.domain.tools.services.DuckDuckGoHtmlParser
import app.m1k3.ai.domain.tools.services.ToolExecutor
import co.touchlab.kermit.Logger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * Web Search Executor — DuckDuckGo Instant Answer API.
 *
 * No API key, no tracking. JSON, free, no auth:
 * https://api.duckduckgo.com/?q=query&format=json&no_html=1
 *
 * Returns: abstract, answer, related topics.
 * Falls back to DuckDuckGo HTML lite for broader results.
 */
class WebSearchExecutor : ToolExecutor {
    private val logger = Logger.withTag("WebSearchExecutor")

    override val toolId = "web_search"

    override suspend fun isAvailable(): Boolean = true

    override suspend fun execute(call: ToolCall): ToolResult =
        withContext(Dispatchers.IO) {
            val startTime = System.currentTimeMillis()
            val query =
                call.arguments["query"]
                    ?: return@withContext ToolResult.Failure(
                        toolId = toolId,
                        error = ToolError.InvalidArguments("'query' parameter required"),
                        executionTimeMs = System.currentTimeMillis() - startTime,
                    )

            try {
                val encoded = URLEncoder.encode(query, "UTF-8")
                val url = URL("https://api.duckduckgo.com/?q=$encoded&format=json&no_html=1&skip_disambig=1")

                val connection = url.openConnection() as HttpURLConnection
                connection.requestMethod = "GET"
                connection.connectTimeout = 5000
                connection.readTimeout = 5000
                connection.setRequestProperty("User-Agent", "M1K3/1.0 (Private AI Assistant)")

                val responseCode = connection.responseCode
                if (responseCode != 200) {
                    return@withContext ToolResult.Failure(
                        toolId = toolId,
                        error = ToolError.ExecutionFailed(Exception("HTTP $responseCode")),
                        executionTimeMs = System.currentTimeMillis() - startTime,
                    )
                }

                val body = connection.inputStream.bufferedReader().readText()
                connection.disconnect()

                // Parse DuckDuckGo JSON response (simple extraction, no JSON library needed)
                val abstract = extractJsonString(body, "AbstractText")
                val answer = extractJsonString(body, "Answer")
                val heading = extractJsonString(body, "Heading")
                val abstractSource = extractJsonString(body, "AbstractSource")
                val abstractUrl = extractJsonString(body, "AbstractURL")

                // Extract related topics (first 5)
                val relatedTopics = extractRelatedTopics(body, maxTopics = 5)

                val instantAnswerEmpty =
                    answer.isBlank() && abstract.isBlank() && relatedTopics.isEmpty()

                // DDG Instant Answer only covers knowledge-graph queries (Wikipedia
                // entities). Weather, news, current events fall through here — hit
                // the HTML endpoint for real organic results.
                val htmlFallback =
                    if (instantAnswerEmpty) fetchHtmlFallback(encoded) else null

                val output =
                    buildString {
                        if (answer.isNotBlank()) {
                            appendLine("Answer: $answer")
                        }
                        if (abstract.isNotBlank()) {
                            if (heading.isNotBlank()) appendLine("**$heading**")
                            appendLine(abstract)
                            if (abstractSource.isNotBlank()) appendLine("Source: $abstractSource")
                        }
                        if (relatedTopics.isNotEmpty() && abstract.isBlank() && answer.isBlank()) {
                            appendLine("Related results for \"$query\":")
                            relatedTopics.forEach { appendLine("• $it") }
                        }
                        if (htmlFallback != null && htmlFallback.results.isNotEmpty()) {
                            append(DuckDuckGoHtmlParser.format(htmlFallback.results, query))
                        }
                        if (isEmpty()) {
                            append("No results found for \"$query\". Try asking more specifically.")
                        }
                    }.trim()

                val data =
                    mutableMapOf<String, Any>(
                        "query" to query,
                    )
                if (abstract.isNotBlank()) data["abstract"] = abstract
                if (answer.isNotBlank()) data["answer"] = answer
                if (heading.isNotBlank()) data["heading"] = heading
                if (abstractUrl.isNotBlank()) data["url"] = abstractUrl
                if (relatedTopics.isNotEmpty()) data["related"] = relatedTopics
                if (htmlFallback != null && htmlFallback.results.isNotEmpty()) {
                    data["results"] =
                        htmlFallback.results.map {
                            mapOf("title" to it.title, "url" to it.url, "snippet" to it.snippet)
                        }
                }

                ToolResult.Success(
                    toolId = toolId,
                    output = output,
                    data = data,
                    executionTimeMs = System.currentTimeMillis() - startTime,
                )
            } catch (e: Exception) {
                println("DEBUG(WebSearch) FAILED: ${e::class.simpleName}: ${e.message}")
                e.printStackTrace()
                ToolResult.Failure(
                    toolId = toolId,
                    error = ToolError.ExecutionFailed(e),
                    executionTimeMs = System.currentTimeMillis() - startTime,
                )
            }
        }

    private data class HtmlFallback(
        val results: List<DuckDuckGoHtmlParser.SearchResult>,
    )

    /**
     * Hit html.duckduckgo.com when Instant Answer comes back empty. Swallows
     * network errors — a failed fallback just leaves the "No results" message,
     * it must not turn a partial success into a full failure.
     */
    private fun fetchHtmlFallback(encodedQuery: String): HtmlFallback? {
        return try {
            val url = URL("https://html.duckduckgo.com/html/?q=$encodedQuery")
            val connection = url.openConnection() as HttpURLConnection
            connection.requestMethod = "GET"
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            connection.setRequestProperty(
                "User-Agent",
                "Mozilla/5.0 (Linux; Android; M1K3/1.0 Private AI Assistant)",
            )

            if (connection.responseCode != 200) {
                logger.d { "HTML fallback non-200: ${connection.responseCode}" }
                connection.disconnect()
                return null
            }
            val body = connection.inputStream.bufferedReader().readText()
            connection.disconnect()

            HtmlFallback(
                results = DuckDuckGoHtmlParser.parse(body, maxResults = 5),
            )
        } catch (e: Exception) {
            logger.w(e) { "HTML fallback failed (non-fatal)" }
            null
        }
    }

    override fun validateArguments(arguments: Map<String, String>): Result<Unit> =
        if (arguments.containsKey("query") && arguments["query"]?.isNotBlank() == true) {
            Result.success(Unit)
        } else {
            Result.failure(IllegalArgumentException("'query' is required"))
        }

    /** Simple JSON string extraction without a JSON library */
    private fun extractJsonString(
        json: String,
        key: String,
    ): String {
        val pattern = "\"$key\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"".toRegex()
        return pattern
            .find(json)
            ?.groupValues
            ?.get(1)
            ?.replace("\\\"", "\"")
            ?.replace("\\n", "\n")
            ?.replace("\\\\", "\\")
            ?.trim()
            ?: ""
    }

    /** Extract related topic texts from DuckDuckGo JSON */
    private fun extractRelatedTopics(
        json: String,
        maxTopics: Int,
    ): List<String> {
        val topics = mutableListOf<String>()
        val pattern = "\"Text\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"".toRegex()
        pattern.findAll(json).take(maxTopics).forEach { match ->
            val text =
                match.groupValues[1]
                    .replace("\\\"", "\"")
                    .replace("\\n", "\n")
                    .trim()
            if (text.isNotBlank() && text.length > 10) {
                topics += text
            }
        }
        return topics
    }
}
