# M1K3 AI Architecture
**Project Codename: M1K3 Vision (Ma Vision)**

> ## ⚠️ Historical Design Doc — Read With Care
>
> This document was written in Nov 2025 as a forward-looking design doc and
> has drifted significantly from the shipped implementation. It is retained
> for context and rationale on deep architectural choices (privacy model,
> RAG structure, eco metrics), but **do not trust specifics**.
>
> **For current truth, prefer in order:**
> 1. `.claude/project-memory.md` — session-by-session log of what actually changed.
> 2. `git log` and the code itself (especially `composeApp/src/androidMain/kotlin/app/m1k3/ai/assistant/ai/`).
> 3. `docs/adr/` — the ADRs are kept current.
>
> **Known drift (as of 2026-04-19):**
> - **Models**: "Gemma 3 270M / 4B" below is superseded. Current tiers are
>   Qwen3 0.6B (Mini) / 1.7B (Lil), Qwen3.5 0.8B / 2B (variants), Gemma 4 E2B
>   (Big). iOS adds System tier via Apple Foundation Models.
> - **Inference**: Llamatik was removed. We ship our own `Ma` JNI bridge to
>   llama.cpp (submodule at `composeApp/src/androidMain/cpp/llama.cpp`).
>   See ADR-0001.
> - **Privacy narrative**: "No INTERNET permission" is false. INTERNET is
>   granted for user-initiated network (model downloads + web-search tool).
>   See ADR-0006 ("Your device is the cloud").
> - **Tool calling**: Native GBNF grammar-constrained decoding shipped after
>   this doc was written — see commits around April 2026.
> - **Persona**: Theatrical villain + witty bartender personas retired
>   April 2026. Current ethos is dry/sharp — see `MaSystemPromptBuilder.kt`.
>
> **Addendum (2026-08):**
> - **Branding**: the product is now marketed and named **M1K3** everywhere
>   user-facing — the 間/"Ma AI" naming below is the doc's original Nov-2025
>   framing, retired. The internal `Ma*` class/file prefix (`MaTheme`,
>   `MaButton`, `MaBridge`, …) is a historical design-system prefix and is
>   NOT the product name; see `CLAUDE.md`.
> - **Model tiers**: superseded again. Current tiers (`M1K3Tier.kt`) are
>   Mini (Qwen3.5 0.8B, <4GB RAM), Lil (Qwen3.5 2B, 4–8GB RAM), Big
>   (Gemma 4 E2B, 8GB+ RAM).
> - **ML Kit GenAI / OnDeviceAi**: removed entirely (2026-08) — it was
>   never wired into the real chat flow. See ADR-0006's addendum.

## Philosophical Foundation

### The Concept of 間 (Ma)
間 (ma) represents negative space, pause, and the intervals between things in Japanese aesthetics. This philosophy permeates every architectural decision—from the space between AI interactions to the deliberate minimalism in feature scope. We embrace wabi-sabi: finding beauty in imperfection, transience, and simplicity.

### Core Principles

**1. Your Device Is the Cloud**
Privacy is architectural, not a policy promise. All **chat inference stays on
the device** — the model, the conversation, the memory. Network is granted
only for two narrow, user-initiated paths: HuggingFace model downloads and
the web-search tool (DuckDuckGo Instant Answer). `ManifestPrivacyTest`
enforces this at build time: no analytics SDKs, no Firebase, only the
allow-listed network callers. See ADR-0006 for the full contract.

> *(The original Nov-2025 formulation here was "no INTERNET permission at
> all"; that was retired April 2026 when user-initiated network was needed
> for model downloads. The privacy guarantee tightened — it's now enforced
> by tests, not just by absence.)*

**2. Environmental Sustainability**
Every architectural decision considers energy consumption. On-device processing eliminates:
- 2.5-5g CO₂ per query (vs. 0.2g local)
- 40% of data center energy spent on cooling
- Network transmission energy (0.06-1.8 kWh per GB)
- Continuous infrastructure power draw

**3. Computational Sufficiency**
We reject the "bigger is better" paradigm. The optimal model is the smallest one that achieves the task. M1K3 uses hardware-matched tiers: Mini (Qwen3.5-0.8B, 557MB), Lil (Qwen3.5-2B, 1.33GB), and Big (Gemma 4 E2B, 3.1GB) — selected at first launch based on device RAM. On iOS, Apple Foundation Models serve as a zero-download base tier. All models are natively multimodal as of March–April 2026.

**4. User Autonomy Through Ownership**
Users own their AI. No subscriptions to remote services that can disappear, change terms, or analyze usage patterns. The companion lives entirely within the user's control.

---

## System Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     USER INTERFACE LAYER                    │
│                  (Compose Multiplatform)                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────┐  ┌─────────────────────────────────┐ │
│  │   Chat Screen    │  │    Project Management           │ │
│  │                  │  │                                 │ │
│  │  • Text Input    │  │  • Project Browser              │ │
│  │  • Image Input   │  │  • Context Viewer               │ │
│  │  • Voice Input   │  │  • Memory Explorer              │ │
│  │  • Response      │  │  • Relationship Graph           │ │
│  │    Stream        │  │  • Privacy Dashboard            │ │
│  └──────────────────┘  └─────────────────────────────────┘ │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│                      DOMAIN LAYER                           │
│                   (Business Logic)                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌────────────────────────────────────────────────────────┐ │
│  │              CompanionEngine Core                      │ │
│  │                                                        │ │
│  │  • Message Processing Pipeline                        │ │
│  │  • Context Assembly & Management                      │ │
│  │  • Memory Formation & Retrieval                       │ │
│  │  • Importance Scoring                                 │ │
│  │  • Token Budget Management                            │ │
│  │  • Multimodal Content Handling                        │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│                   DATA & AI LAYER                           │
│              (Platform-Specific Implementations)            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │  Ma (JNI)   │  │    Vector    │  │   SQLDelight     │  │
│  │  llama.cpp  │  │   Database   │  │   (Metadata)     │  │
│  │             │  │              │  │                  │  │
│  │ • Qwen3     │  │ • Linear     │  │ • Projects       │  │
│  │ • Gemma 4   │  │   search     │  │ • Messages       │  │
│  │ • GBNF tool │  │ • 384-dim    │  │ • Memory Meta    │  │
│  │   calling   │  │ • MiniLM-L6  │  │ • Tool History   │  │
│  └─────────────┘  └──────────────┘  └──────────────────┘  │
│                                                             │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │  Sentence   │  │    Camera    │  │   File System    │  │
│  │  Embedder   │  │  Integration │  │                  │  │
│  │             │  │              │  │ • Local Storage  │  │
│  │ • MiniLM-L6 │  │ • CameraX    │  │ • No Cloud       │  │
│  │ • 384-dim   │  │ • Image      │  │ • Encrypted DB   │  │
│  │ • ONNX      │  │   Capture    │  │                  │  │
│  └─────────────┘  └──────────────┘  └──────────────────┘  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Layer-by-Layer Deep Dive

### 1. User Interface Layer

**Technology:** Compose Multiplatform (targeting Android, with future iOS/Desktop support)

**Design Philosophy:**
- **Liquid Glass Material System**: Glassmorphism with mathematical precision (22.2% corner radius ratios)
- **Pure Black Backgrounds**: Apple-inspired minimalism, optimized for OLED power efficiency
- **Accessibility-First**: 95%+ accessibility scores, full screen reader support
- **Digital Minimalism**: No dark patterns, no engagement optimization, no notification spam

**Key Components:**

#### Chat Screen
```kotlin
@Composable
fun ChatScreen(
    viewModel: ChatViewModel,
    projectId: String?
) {
    // Implements:
    // - Message list with vision support (text + images)
    // - Multi-modal input (text, camera, gallery)
    // - Project context awareness
    // - Real-time response streaming
    // - Gesture-based interactions
}
```

**Design Decisions:**
- Reverse layout for message list (natural chat pattern)
- Inline image previews sized contextually (60dp thumbnails, full-width in messages)
- Single-line input that expands on demand (respect screen real estate)
- No "typing indicators" (they create anxiety without adding value)

#### Project Browser
```kotlin
@Composable
fun ProjectBrowser(
    projects: List<Project>,
    onProjectSelect: (Project) -> Unit
) {
    // Implements:
    // - Visual project cards with metadata
    // - Last accessed sorting (recency bias)
    // - Quick search/filter
    // - Project creation flow
}
```

**Design Decisions:**
- Projects as first-class concept (not folders or tags)
- Visual distinction through color/icon system
- Quick-switch gesture (swipe between projects)

#### Memory Explorer
```kotlin
@Composable
fun MemoryExplorer(
    projectId: String?,
    viewModel: MemoryViewModel
) {
    // Implements:
    // - Vector space visualization
    // - Memory cluster view
    // - Importance scores
    // - Manual memory curation
}
```

**Design Decisions:**
- Users can see what the AI "remembers"
- Manual importance adjustment (user knows what matters)
- Delete specific memories (right to be forgotten)

---

### 2. Domain Layer

**Purpose:** Platform-agnostic business logic implementing the core AI companion functionality.

#### CompanionEngine Architecture

```kotlin
class CompanionEngine(
    private val gemmaEngine: GemmaVisionEngine,
    private val memoryManager: MemoryManager,
    private val contextAssembler: ContextAssembler,
    private val database: Database
) {
    suspend fun processMessage(
        userMessage: Message
    ): Flow<ResponseChunk> = flow {
        // 1. Store user message
        storeMessage(userMessage)
        
        // 2. Create memories from user input
        memoryManager.createMemoriesFromMessage(userMessage)
        
        // 3. Retrieve relevant context
        val context = contextAssembler.buildContext(
            query = userMessage.extractText(),
            projectId = userMessage.projectId,
            includeVision = userMessage.hasImages()
        )
        
        // 4. Generate response (streamed)
        val responseChunks = gemmaEngine.generateStreaming(
            messages = context.toMessageList(),
            maxTokens = calculateMaxTokens(context)
        )
        
        // 5. Emit chunks and accumulate full response
        var fullResponse = ""
        responseChunks.collect { chunk ->
            fullResponse += chunk.text
            emit(chunk)
        }
        
        // 6. Store assistant response and create memories
        val assistantMessage = Message(
            role = Message.Role.ASSISTANT,
            content = listOf(ContentPart.Text(fullResponse)),
            projectId = userMessage.projectId
        )
        storeMessage(assistantMessage)
        memoryManager.createMemoriesFromMessage(assistantMessage)
    }
}
```

**Key Design Decisions:**

1. **Streaming Responses**: Users see output as it generates (reduces perceived latency)
2. **Automatic Memory Formation**: Every interaction creates searchable memories
3. **Project-Scoped Context**: Memories from other projects don't pollute current conversation
4. **Token Budget Management**: Dynamic allocation between context and response

---

### 3. Memory Management System

**Philosophy:** Human memory is imperfect, associative, and context-dependent. We model this computationally through vector similarity, recency weighting, and importance scoring.

#### Architecture

```
User Message
     │
     ├──> Semantic Chunking
     │    (Break into 100-300 token segments)
     │
     ├──> Embedding Generation
     │    (MiniLM-L6: 384-dimensional vectors)
     │
     ├──> Importance Scoring
     │    (0.0 - 1.0 based on heuristics)
     │
     └──> Storage
          │
          ├──> Vector Database (HNSW)
          │    • Fast similarity search
          │    • M=16 bi-directional links
          │    • efConstruction=200
          │
          └──> SQLDelight (Metadata)
               • Content text
               • Timestamps
               • Access counts
               • Project associations
```

#### Context Assembly Algorithm

```kotlin
suspend fun buildContext(
    currentQuery: String,
    projectId: String?,
    maxTokens: Int = 24000 // Leave 8K for response in 32K context
): ConversationContext {
    // 1. Get recent conversation (recency bias)
    val recentMessages = getRecentMessages(
        projectId = projectId,
        limit = 20
    )
    
    // 2. Vector similarity search
    val similarMemories = vectorStore.searchSimilar(
        query = currentQuery,
        projectId = projectId,
        k = 20 // Retrieve more, then rank
    )
    
    // 3. Composite ranking
    val rankedMemories = rankMemories(
        memories = similarMemories,
        currentQuery = currentQuery,
        recentMessages = recentMessages
    )
    
    // 4. Token budget allocation
    return assembleWithinBudget(
        recentMessages = recentMessages,
        memories = rankedMemories,
        systemPrompt = getPersonalityPrompt(),
        maxTokens = maxTokens
    )
}
```

**Ranking Formula:**
```kotlin
fun calculateMemoryScore(
    memory: Memory,
    queryEmbedding: List<Float>
): Float {
    val relevance = cosineSimilarity(queryEmbedding, memory.embedding)
    val recency = exp(-daysSince(memory.timestamp) / 30.0) // 30-day half-life
    val importance = memory.importance
    val access = log2(memory.accessCount + 1) / 10.0 // Logarithmic access boost
    
    return (relevance * 0.4) + 
           (recency * 0.2) + 
           (importance * 0.3) + 
           (access * 0.1)
}
```

**Design Rationale:**
- **40% Relevance**: Primary signal—what relates to current query
- **20% Recency**: Recent context is more likely relevant
- **30% Importance**: User-defined or heuristic-based priority
- **10% Access**: Frequently referenced memories are "core" knowledge

#### Importance Heuristics

```kotlin
fun calculateImportance(content: String, message: Message): Float {
    var score = 0.5f // Baseline
    
    // Questions indicate information-seeking (likely important)
    if (content.contains("?")) score += 0.1f
    
    // User messages weighted higher (their needs > AI verbosity)
    if (message.role == Message.Role.USER) score += 0.1f
    
    // Length proxy for detail/specificity
    if (content.length > 200) score += 0.15f
    
    // Explicit importance markers
    val importanceKeywords = listOf(
        "important", "remember", "don't forget", 
        "key", "critical", "always", "never"
    )
    if (importanceKeywords.any { content.contains(it, ignoreCase = true) }) {
        score += 0.15f
    }
    
    // Code blocks (specific, reusable knowledge)
    if (content.contains("```")) score += 0.1f
    
    return score.coerceIn(0f, 1f)
}
```

---

### 4. AI Models Layer

#### Primary Model: Gemma 3 4B Vision (MVP) / 270M (Production Target)

**Why Gemma 3?**
1. **Optimal Size/Performance Trade-off**: 
   - 270M model: 120MB quantized (4-bit)
   - 4B model: ~2GB quantized (MVP scope)
   - Superior instruction following (51.2 IFEval score)

2. **Native Vision Support**: 
   - 896×896 image encoding
   - Integrated vision-language architecture
   - No separate vision encoder needed

3. **Licensing**: 
   - Apache 2.0 (commercial use permitted)
   - No attribution requirements
   - Model weights openly available

4. **Mobile Optimization**:
   - ONNX Runtime support
   - Neural Engine acceleration (iOS)
   - NPU support (Android)

**Architecture Integration:**

```kotlin
class GemmaVisionEngine(
    context: Context,
    modelPath: String = "gemma-3-4b-vision-q4.onnx"
) {
    // ONNX Runtime session
    private val session: OrtSession
    
    // Custom tokenizer for Gemma's vocabulary
    private val tokenizer: GemmaTokenizer
    
    suspend fun generate(
        messages: List<Message>,
        maxTokens: Int = 512,
        temperature: Float = 0.7f
    ): String {
        // 1. Format conversation with vision tokens
        val prompt = formatMessagesWithVision(messages)
        
        // 2. Tokenize (handle special tokens: <image>, <start_of_turn>, etc.)
        val inputIds = tokenizer.encode(prompt)
        
        // 3. Run inference with ONNX Runtime
        val outputs = session.run(
            mapOf("input_ids" to OnnxTensor.createTensor(session.ortEnvironment, inputIds))
        )
        
        // 4. Sample from logits (temperature + top-k)
        val generatedIds = sampleTokens(outputs[0].value, temperature, maxTokens)
        
        // 5. Decode to text
        return tokenizer.decode(generatedIds)
    }
}
```

**Vision Encoding:**
```kotlin
private fun formatMessagesWithVision(messages: List<Message>): String {
    val formatted = StringBuilder()
    
    messages.forEach { message ->
        // Add role token
        formatted.append(
            when (message.role) {
                Role.USER -> "<start_of_turn>user\n"
                Role.ASSISTANT -> "<start_of_turn>model\n"
                Role.SYSTEM -> "<start_of_turn>system\n"
            }
        )
        
        // Process content parts
        message.content.forEach { part ->
            when (part) {
                is ContentPart.Text -> 
                    formatted.append(part.text)
                    
                is ContentPart.Image -> {
                    // Gemma 3's vision encoding:
                    // 1. Resize to 896×896
                    // 2. Normalize RGB values
                    // 3. Encode as 256-token sequence
                    formatted.append("<image>")
                    formatted.append(encodeImageToTokens(part.imageData))
                }
            }
        }
        
        formatted.append("<end_of_turn>\n")
    }
    
    // Prompt for model response
    formatted.append("<start_of_turn>model\n")
    return formatted.toString()
}
```

#### Secondary Model: Sentence Embedder (MiniLM-L6)

**Purpose:** Generate 384-dimensional embeddings for semantic search

**Why MiniLM-L6?**
- Small: 22.7M parameters (~90MB quantized)
- Fast: <50ms inference on mobile
- Effective: 0.83 cosine similarity with larger models
- Multi-lingual: Decent support for non-English

**Architecture:**
```kotlin
class SentenceEmbedder(context: Context) {
    private val session: OrtSession // Load MiniLM-L6 ONNX model
    private val tokenizer: BertTokenizer
    
    suspend fun embed(text: String): List<Float> {
        // 1. Tokenize with BERT wordpiece
        val tokens = tokenizer.encode(text, maxLength = 128)
        
        // 2. Run through transformer
        val outputs = session.run(
            mapOf(
                "input_ids" to tokens.ids,
                "attention_mask" to tokens.mask
            )
        )
        
        // 3. Mean pooling over sequence (not just [CLS] token)
        val embeddings = outputs["last_hidden_state"]
        return meanPooling(embeddings, tokens.mask)
    }
    
    private fun meanPooling(
        embeddings: FloatArray,
        attentionMask: IntArray
    ): List<Float> {
        // Average token embeddings, weighted by attention mask
        // Results in 384-dimensional vector
    }
}
```

---

### 5. Storage Layer

#### Vector Database: HNSW (Hierarchical Navigable Small World)

**Why HNSW?**
- **Speed**: O(log N) search complexity
- **Memory Efficient**: ~10 bytes per vector (384-dim, M=16)
- **Quality**: 95%+ recall@10 vs. brute force
- **Mobile-Optimized**: No server dependency

**Architecture:**
```kotlin
class VectorMemoryStore(
    context: Context,
    dimension: Int = 384
) {
    private val index: HnswIndex = HnswIndex.newBuilder(dimension, DistanceFunction.INNER_PRODUCT)
        .withM(16)           // Bi-directional links per node
        .withEfConstruction(200)  // Candidate list size during build
        .build()
    
    suspend fun addMemory(memory: Memory) {
        // Add to index with memory ID
        index.add(Item(memory.id, memory.embedding.toFloatArray()))
        
        // Persist to disk (incremental save)
        saveIndex()
    }
    
    suspend fun searchSimilar(
        query: String,
        projectId: String?,
        k: Int = 10
    ): List<Memory> {
        // Embed query
        val queryEmbedding = embedder.embed(query)
        
        // Search index (k * 2 for post-filtering)
        val results = index.findNearest(
            queryEmbedding.toFloatArray(),
            k * 2
        )
        
        // Filter by project and return top k
        return results
            .map { getMemoryMetadata(it.item().id()) }
            .filter { projectId == null || it.projectId == projectId }
            .take(k)
    }
}
```

**Index Persistence:**
```kotlin
private fun saveIndex() {
    val file = File(context.filesDir, "vector_index.bin")
    
    // Serialize index structure
    index.save(file)
    
    // Index file size: ~10MB for 10K memories
}
```

#### Relational Database: SQLDelight

**Why SQLDelight?**
- **Type-Safe**: Generated Kotlin APIs
- **Multi-Platform**: Shared schema across Android/iOS
- **Performant**: Direct SQLite access
- **Migrations**: Schema versioning built-in

**Schema:**
```sql
-- Projects: First-class organizational units
CREATE TABLE Project (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    createdAt INTEGER NOT NULL,
    lastAccessedAt INTEGER NOT NULL,
    tags TEXT NOT NULL,  -- JSON array
    
    -- Indexes for common queries
    INDEX idx_lastAccessed ON Project(lastAccessedAt DESC)
);

-- Messages: Conversation history
CREATE TABLE Message (
    id TEXT PRIMARY KEY NOT NULL,
    role TEXT NOT NULL,  -- USER | ASSISTANT | SYSTEM
    content TEXT NOT NULL,  -- JSON serialized ContentPart[]
    timestamp INTEGER NOT NULL,
    projectId TEXT,
    
    FOREIGN KEY (projectId) REFERENCES Project(id) ON DELETE CASCADE,
    INDEX idx_project_time ON Message(projectId, timestamp DESC)
);

-- MemoryMetadata: Searchable memory metadata
CREATE TABLE MemoryMetadata (
    id TEXT PRIMARY KEY NOT NULL,
    content TEXT NOT NULL,  -- Actual text (embeddings in HNSW)
    projectId TEXT,
    messageId TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    importance REAL NOT NULL DEFAULT 0.5,
    accessCount INTEGER NOT NULL DEFAULT 0,
    
    FOREIGN KEY (projectId) REFERENCES Project(id) ON DELETE CASCADE,
    FOREIGN KEY (messageId) REFERENCES Message(id) ON DELETE CASCADE,
    INDEX idx_project ON MemoryMetadata(projectId),
    INDEX idx_importance ON MemoryMetadata(importance DESC)
);

-- Settings: User preferences
CREATE TABLE Settings (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
);
```

**Query APIs (Auto-Generated):**
```kotlin
interface MessageQueries {
    fun selectByProject(projectId: String, limit: Long): Query<Message>
    fun selectRecent(limit: Long): Query<Message>
    fun insert(message: Message)
    fun deleteByProject(projectId: String)
}

interface MemoryMetadataQueries {
    fun selectByProject(projectId: String): Query<MemoryMetadata>
    fun incrementAccessCount(id: String)
    fun updateImportance(id: String, importance: Float)
}
```

---

## Data Flow & Lifecycle

### Typical User Interaction Flow

```
1. User opens app
   ├─> Load recent project (or default)
   ├─> Load last 20 messages from SQLDelight
   └─> Display chat UI

2. User types message + attaches image
   ├─> Create Message object
   │   └─> ContentPart.Text("Describe this flower")
   │   └─> ContentPart.Image(imageData, dimensions)
   │
   ├─> Save to SQLDelight
   │
   ├─> Create memories
   │   ├─> Chunk text ("Describe this flower")
   │   ├─> Generate embedding (384-dim vector)
   │   ├─> Calculate importance (0.6 - has question)
   │   └─> Store in HNSW + SQLDelight
   │
   └─> Trigger AI response

3. Context Assembly
   ├─> Retrieve recent messages (last 20)
   │
   ├─> Semantic search for relevant memories
   │   ├─> Embed query: "Describe this flower"
   │   ├─> HNSW search (top 20 similar)
   │   └─> Rank by composite score
   │
   ├─> Assemble within token budget
   │   ├─> System prompt: ~200 tokens
   │   ├─> Recent messages: ~5,000 tokens
   │   ├─> Relevant memories: ~10,000 tokens
   │   ├─> Current query + image: ~2,000 tokens
   │   └─> Total: ~17,200 tokens (leaves 14,800 for response)
   │
   └─> Format for Gemma

4. AI Generation
   ├─> ONNX Runtime inference
   │   ├─> Load model (if not cached)
   │   ├─> Encode image (896×896 → 256 tokens)
   │   ├─> Tokenize full prompt (~17K tokens)
   │   └─> Generate response (stream tokens)
   │
   ├─> Stream to UI (real-time display)
   │
   └─> Accumulate full response

5. Post-Generation
   ├─> Save assistant message to SQLDelight
   │
   ├─> Create memories from response
   │   ├─> Chunk response (semantic boundaries)
   │   ├─> Generate embeddings
   │   ├─> Calculate importance (0.4 - assistant message)
   │   └─> Store in HNSW + SQLDelight
   │
   └─> Update UI (response complete)
```

### Memory Lifecycle

```
Creation:
  Message arrives
    → Semantic chunking (100-300 tokens)
    → Embedding generation (MiniLM-L6)
    → Importance scoring (heuristics)
    → Store in HNSW + SQLDelight

Retrieval:
  Query arrives
    → Embed query (MiniLM-L6)
    → HNSW search (top K similar)
    → Rank by composite score
    → Filter by project (if applicable)
    → Return relevant memories

Access:
  Memory used in context
    → Increment accessCount in SQLDelight
    → Boost future relevance (logarithmic)

Curation:
  User manual intervention
    → Update importance (UI slider)
    → Delete memory (HNSW + SQLDelight)
    → Tag/annotate (future feature)

Archival:
  Project deleted
    → CASCADE DELETE in SQLDelight
    → Remove from HNSW index
    → Compact index file
```

---

## Performance Characteristics

### Model Inference

| Model | Size | Load Time | Inference Speed | Power Draw |
|-------|------|-----------|-----------------|------------|
| Gemma 3 270M (4-bit) | 120MB | 2-4s | 50 tokens/s | 1.2W |
| Gemma 3 4B (4-bit) | 2.0GB | 8-12s | 15-20 tokens/s | 3.5W |
| MiniLM-L6 (8-bit) | 90MB | 0.5s | 20ms/embedding | 0.3W |

**Hardware Targets:**
- **Flagship (2024)**: iPhone 15 Pro, Snapdragon 8 Gen 3
  - 35+ TOPS neural engine
  - 8GB+ RAM
  - Full 4B model support

- **Mid-Range (2023)**: iPhone 13, Snapdragon 8 Gen 1
  - 15-20 TOPS neural engine
  - 6GB RAM
  - 270M model optimal

- **Budget (2022)**: iPhone SE, Snapdragon 778G
  - CPU inference fallback
  - 4GB RAM
  - 270M model minimum

### Memory System

| Operation | Latency | Throughput |
|-----------|---------|------------|
| Add single memory | 50-80ms | ~15/sec |
| Batch add (100) | 3-5s | ~25/sec |
| Similarity search (k=10) | 20-50ms | ~30 searches/sec |
| Context assembly | 100-200ms | ~7/sec |

**Storage Growth:**
- Vector index: ~10KB per memory (384-dim + HNSW overhead)
- SQLDelight: ~1KB per memory (text + metadata)
- **Total**: ~11KB per memory

**Capacity Example:**
- 10,000 memories: ~110MB
- 100,000 memories: ~1.1GB

### Battery Impact

| Activity | Power Draw | Battery Life Impact |
|----------|------------|---------------------|
| Idle | <10mW | <0.1%/hour |
| Typing/browsing | 50-100mW | 0.5%/hour |
| AI inference (270M) | 1.2W | 5-8%/hour active |
| AI inference (4B) | 3.5W | 15-20%/hour active |

**Optimization Strategies:**
1. **Lazy Model Loading**: Load only when needed, unload after 5min idle
2. **Neural Engine Priority**: Use dedicated AI accelerators (50-107% more efficient)
3. **Quantization**: 4-bit models (75% size reduction, 10-15% quality loss)
4. **Batching**: Process multiple embeddings together

---

## Privacy Architecture

### Zero Network Guarantee

**Android Manifest:**
```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- EXPLICIT ABSENCE of internet permission -->
    <!-- No INTERNET permission = no network access possible -->
    
    <!-- Only local permissions -->
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
    
    <!-- ... -->
</manifest>
```

**Implications:**
- Impossible to send data to external servers (OS enforced)
- No analytics, no telemetry, no crash reporting to cloud
- No ad networks, no tracking SDKs
- No "phone home" for model updates (updates via app store)

### Data Sovereignty

**All data stored locally:**
```
/data/data/com.roundtower.maai/
├── databases/
│   └── maai.db               (SQLDelight - encrypted with SQLCipher)
├── files/
│   ├── vector_index.bin      (HNSW index)
│   ├── gemma-3-270m-q4.onnx (AI model)
│   └── minilm-l6.onnx       (Embedding model)
└── cache/
    └── image_cache/          (Temporary image processing)
```

**Encryption:**
```kotlin
// SQLCipher integration
val driver: SqlDriver = AndroidSqliteDriver(
    schema = Database.Schema,
    context = context,
    name = "maai.db",
    callback = object : AndroidSqliteDriver.Callback(Database.Schema) {
        override fun onOpen(db: SupportSQLiteDatabase) {
            db.execSQL("PRAGMA key = '${getUserKey()}'")
        }
    }
)
```

**User Key Derivation:**
```kotlin
fun getUserKey(): String {
    // Derive from Android Keystore
    // Unique per device, never leaves device
    // Backed by hardware TEE (Trusted Execution Environment)
    return AndroidKeyStore.deriveKey("maai_db_key")
}
```

### Privacy Dashboard

**Transparent Metrics:**
```kotlin
@Composable
fun PrivacyDashboard() {
    Column(modifier = Modifier.padding(16.dp)) {
        StatCard(
            label = "Network Requests",
            value = "0",
            subtitle = "Always zero (no internet permission)"
        )
        
        StatCard(
            label = "Data Transmitted",
            value = "0 bytes",
            subtitle = "Ever, to anywhere"
        )
        
        StatCard(
            label = "Messages Stored",
            value = messageCount.toString(),
            subtitle = "Locally, encrypted"
        )
        
        StatCard(
            label = "Embeddings Generated",
            value = embeddingCount.toString(),
            subtitle = "On-device (MiniLM-L6)"
        )
        
        StatCard(
            label = "Storage Used",
            value = formatBytes(storageUsed),
            subtitle = "${storageLocation} (tap to view)"
        )
    }
}
```

---

## Scalability & Future Architecture

### Current Limitations (MVP)

1. **Model Size**: 4B parameters requires 2GB RAM overhead
2. **Context Window**: 32K tokens (Gemma 3 limit)
3. **Single Device**: No sync between devices
4. **Android Only**: KMP ready, but iOS implementation pending

### Evolution Path

#### Phase 1: MVP (Current)
- Gemma 3 4B vision
- Single project support
- 10K memory capacity
- Android only

#### Phase 2: Optimization (Q1 2026)
- Migrate to Gemma 3 270M (120MB)
- Multi-project support
- 100K memory capacity
- Battery optimization (target <2%/hour)

#### Phase 3: Multi-Platform (Q2 2026)
- iOS implementation (KMP native)
- Desktop companion (macOS, Windows, Linux)
- Web fallback (WASM?)
- Shared codebase (90%+)

#### Phase 4: Advanced Features (Q3 2026)
- Voice integration (Piper TTS + Whisper STT)
- Personality systems (selectable philosophies)
- Tamagotchi-style visual avatars
- Proactive suggestions (not notifications!)

#### Phase 5: Community (Q4 2026)
- Local model fine-tuning (LoRA)
- User-contributed personality packs
- Federated learning (optional, privacy-preserving)
- Open-source core components

---

## Alternative Architectures Considered

### 1. Cloud-Hybrid Model (REJECTED)

**Proposal:**
- Small on-device model (270M) for simple queries
- Route complex queries to cloud (GPT-4, Claude)

**Why Rejected:**
- Violates core privacy principle (data leaves device)
- Requires internet permission (removes architecture guarantee)
- Creates dependency on external services (not owned)
- Introduces latency and cost (per-query pricing)

### 2. Server-Required Setup (REJECTED)

**Proposal:**
- User runs local server (Ollama, LM Studio)
- App connects to localhost

**Why Rejected:**
- Terrible UX (setup friction)
- Excludes 99% of mobile users
- Still requires internet permission (localhost socket)
- Defeats "runs everywhere" goal

### 3. Blockchain-Based Memory (CONSIDERED, DEFERRED)

**Proposal:**
- Store memories on IPFS/Arweave
- Decentralized, permanent, user-owned

**Why Deferred:**
- Adds complexity without MVP value
- Requires network access (conflicts with privacy)
- Retrieval latency unacceptable for real-time chat
- Possible future addition for memory export/backup

### 4. Federated Learning (CONSIDERED, FUTURE)

**Proposal:**
- Users opt-in to share model improvements
- Local training → encrypted gradient upload
- Aggregate improvements → model update

**Why Future:**
- Requires opt-in (privacy preserved)
- Enables community-driven fine-tuning
- Complex implementation (privacy-preserving aggregation)
- Wait for proven demand

---

## Technical Debt & Known Issues

### Current Technical Debt

1. **Memory Chunking**: Simple token-count splitting (should use semantic boundaries)
2. **Image Encoding**: Placeholder (needs actual 896×896 normalization)
3. **Token Budget**: Fixed allocation (should be dynamic based on query complexity)
4. **Error Handling**: Minimal (needs comprehensive crash recovery)
5. **Testing**: Unit tests only (needs integration + UI tests)

### Known Limitations

1. **Context Window**: 32K tokens limits long conversations (mitigation: aggressive memory summarization)
2. **No Sync**: Single-device only (future: encrypted P2P sync?)
3. **Model Update**: Requires app update (future: dynamic model delivery)
4. **Vision Quality**: 4B model necessary for good vision (270M vision unclear)

### Performance Bottlenecks

1. **Model Loading**: 8-12s first load (mitigation: background pre-load on app start)
2. **Embedding Batch**: 3-5s for 100 embeddings (mitigation: background job)
3. **SQLDelight Queries**: Not profiled (needs EXPLAIN QUERY PLAN analysis)
4. **HNSW Build**: Slow for >100K memories (mitigation: incremental saves)

---

## Testing Strategy

### Unit Tests (Domain Layer)

```kotlin
class MemoryManagerTest {
    @Test
    fun `importance scoring - questions weighted higher`() {
        val questionMemory = createMemory("What is the capital of France?")
        val statementMemory = createMemory("The capital of France is Paris.")
        
        assert(questionMemory.importance > statementMemory.importance)
    }
    
    @Test
    fun `context assembly - stays within token budget`() {
        val context = memoryManager.buildContext(
            query = "Tell me about Paris",
            projectId = null,
            maxTokens = 10000
        )
        
        assert(context.totalTokens <= 10000)
    }
}
```

### Integration Tests (Data Layer)

```kotlin
class VectorStoreIntegrationTest {
    @Test
    fun `add and retrieve memory - semantic similarity`() = runBlocking {
        val memory = Memory(
            content = "The Eiffel Tower is in Paris",
            embedding = embedder.embed("The Eiffel Tower is in Paris")
        )
        
        vectorStore.addMemory(memory)
        
        val results = vectorStore.searchSimilar(
            query = "Where is the Eiffel Tower?",
            k = 1
        )
        
        assert(results.first().id == memory.id)
    }
}
```

### UI Tests (Compose)

```kotlin
class ChatScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()
    
    @Test
    fun `send text message - appears in list`() {
        composeTestRule.setContent {
            ChatScreen(viewModel = mockViewModel)
        }
        
        composeTestRule
            .onNodeWithTag("message_input")
            .performTextInput("Hello")
        
        composeTestRule
            .onNodeWithTag("send_button")
            .performClick()
        
        composeTestRule
            .onNodeWithText("Hello")
            .assertIsDisplayed()
    }
}
```

### Performance Tests

```kotlin
class PerformanceBenchmark {
    @Test
    fun `model inference - target 15+ tokens/sec`() = runBlocking {
        val start = System.currentTimeMillis()
        
        val response = gemmaEngine.generate(
            messages = sampleMessages,
            maxTokens = 100
        )
        
        val duration = System.currentTimeMillis() - start
        val tokensPerSec = 100.0 / (duration / 1000.0)
        
        assert(tokensPerSec >= 15.0) { "Too slow: $tokensPerSec tokens/sec" }
    }
}
```

---

## Deployment & Distribution

### Build Configuration

```gradle
android {
    defaultConfig {
        minSdk = 26  // Android 8.0 (97% of devices)
        targetSdk = 34  // Latest
        
        ndk {
            abiFilters += listOf("arm64-v8a")  // 64-bit ARM only (99% of modern devices)
        }
    }
    
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            
            // Sign with upload key
            signingConfig = signingConfigs.getByName("release")
        }
    }
    
    splits {
        // No APK splits - single universal binary
        // (Model size makes splits pointless)
    }
}
```

### App Size Breakdown

```
Total APK Size: ~280MB

Components:
├── Code (DEX files): 8MB
├── Resources (UI assets): 12MB
├── Gemma 3 4B (quantized): 2.0GB → split APK
├── MiniLM-L6 (quantized): 90MB
├── Native libs (ONNX Runtime): 40MB
└── Misc (assets, manifest): 5MB

Optimization Strategies:
1. Ship 270M model for broader reach (120MB total)
2. Offer 4B as optional download (in-app)
3. R8 code shrinking (reduces DEX 30%)
4. Asset compression (PNG → WebP)
```

### Distribution Strategy

**Free Tier:**
- Gemma 3 270M model (120MB)
- Unlimited messages
- 5 projects
- 10K memory capacity

**Pro Tier ($4.99/month or $39.99/year):**
- Gemma 3 4B model upgrade (better vision + reasoning)
- Unlimited projects
- 100K memory capacity
- Voice integration (Piper TTS)
- Priority feature access

**Monetization Philosophy:**
- Free tier fully functional (not crippled)
- Pro tier adds capability, not removes frustration
- No ads, no tracking, no dark patterns
- One-time payment option ($99.99 lifetime)

---

## Conclusion: Architecture as Philosophy

This architecture embodies our core beliefs:

1. **Privacy is a technical constraint**, not a policy. By removing network permissions, we make data exfiltration impossible.

2. **Sustainability through efficiency**. Every architectural decision optimizes for minimal resource consumption—from model size to memory management.

3. **Ownership over rental**. Users own their AI. No cloud dependency, no subscription to basic functionality.

4. **Documentation as first-class**. This architecture document is maintained with the same rigor as code, because understanding the "why" is as important as the "how".

5. **Wabi-sabi in technology**. Embracing constraints (small models, local processing) as sources of beauty and innovation rather than limitations.

The result is a system that respects users, the environment, and the principles of thoughtful design. It's not the biggest AI, the fastest AI, or the most feature-rich AI—it's the AI you own, that runs anywhere, that respects your privacy, and that will still work in 10 years regardless of what happens to any tech company.

---

**Document Version:** 1.0  
**Last Updated:** November 2025  
**Status:** Living document (updated with implementation)  
**Maintainer:** Round Tower Architecture Team
