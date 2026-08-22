package app.m1k3.ai.assistant

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import app.m1k3.ai.assistant.ai.BaseLlmEngine
import app.m1k3.ai.assistant.app.AppInitializationManager
import app.m1k3.ai.assistant.app.InitializationResult
import app.m1k3.ai.assistant.app.InitializationState
import app.m1k3.ai.assistant.app.InitializationViewModel
import app.m1k3.ai.assistant.app.LoggerAdapter
import app.m1k3.ai.assistant.avatar.LocalSharedAvatarVM
import app.m1k3.ai.assistant.avatar.rememberAvatarViewModel
import app.m1k3.ai.assistant.chat.ChatScreenViewModel
import app.m1k3.ai.assistant.chat.collectAsState
import app.m1k3.ai.assistant.database.MaDatabase
import app.m1k3.ai.assistant.design.theme.MaTheme
import app.m1k3.ai.assistant.di.allModules
import app.m1k3.ai.assistant.embedding.EmbeddingEngineManager
import app.m1k3.ai.assistant.navigation.Screen
import app.m1k3.ai.assistant.stt.AndroidSttEngine
import app.m1k3.ai.assistant.ui.ChatScreen
import app.m1k3.ai.assistant.ui.DocumentsScreen
import app.m1k3.ai.assistant.ui.HistoryScreen
import app.m1k3.ai.assistant.ui.LicensesScreen
import app.m1k3.ai.assistant.ui.MemoriesScreen
import app.m1k3.ai.assistant.ui.SettingsScreen
import app.m1k3.ai.assistant.ui.VoiceScreen
import app.m1k3.ai.assistant.utils.Logger
import app.m1k3.ai.assistant.voice.Speaker
import app.m1k3.ai.assistant.voice.VoiceLoopController
import app.m1k3.ai.assistant.voice.runVoiceTurn
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.koin.android.ext.android.inject
import org.koin.android.ext.koin.androidContext
import org.koin.androidx.compose.koinViewModel
import org.koin.compose.koinInject
import org.koin.core.context.startKoin
import org.koin.core.parameter.parametersOf

/**
 * M1K3 - MainActivity
 *
 * Chat is the app. One NavigationStack-equivalent back stack rooted on Chat;
 * Settings, Memories, Documents, Conversations, and Licenses are workspace
 * rooms pushed onto it. No drawer, no bottom nav — each destination owns its
 * own top bar (see macos/M1K3iOSApp/RootView.swift for the shape this mirrors).
 *
 * Minimalist demo showcasing:
 * - Privacy-first architecture (on-device chat; user-initiated network only — see ADR-0006)
 * - Encrypted database foundation
 * - Beautiful Material 3 design
 * - Full Koin DI with koinViewModel()
 */
class MainActivity : ComponentActivity() {
    companion object {
        private val _sharedText = MutableStateFlow<String?>(null)
        val sharedText: StateFlow<String?> = _sharedText.asStateFlow()

        fun consumeSharedText(): String? {
            val text = _sharedText.value
            _sharedText.value = null
            return text
        }
    }

    private val aiEngine: BaseLlmEngine by inject()
    private val embeddingManager: EmbeddingEngineManager by inject()
    private val logger = Logger.withTag("MainActivity")

    @OptIn(ExperimentalMaterial3Api::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Enable edge-to-edge with explicit dark system bar styles.
        //
        // SystemBarStyle.dark(Color.TRANSPARENT) means:
        //   - Status bar  : transparent, icons are always WHITE (light content)
        //   - Nav bar     : transparent, icons are always WHITE
        //
        // We do NOT use SystemBarStyle.auto() because that injects a translucent
        // dark scrim behind the nav bar on light-content screens, which breaks our
        // AMOLED black immersive design. Our background (#000000) already provides
        // sufficient contrast for gesture handles.
        //
        // enforceContrast = false suppresses the API 29+ automatic dark scrim that
        // the OS would otherwise draw over a fully transparent nav bar.
        //
        // MurphySig: https://murphysig.dev — API 21-36 confirmed approach.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )

        // Initialize Koin using AppInitializationManager
        val appInitManager =
            AppInitializationManager(
                logger = LoggerAdapter(logger),
                koinInitializer = {
                    startKoin {
                        androidContext(this@MainActivity)
                        modules(allModules)
                    }
                },
            )

        val koinResult = appInitManager.initializeKoin()
        if (koinResult !is InitializationResult.Success) {
            logger.e { "Koin initialization failed" }
        }

        // Initialize embedding engine for RAG/semantic search
        lifecycleScope.launch {
            embeddingManager
                .initialize()
                .onFailure { e ->
                    logger.e(e) { "Embedding engine initialization failed" }
                }.onSuccess {
                    logger.i { "Embedding engine loaded successfully" }
                }
        }

        // Handle share intent on cold start
        handleShareIntent(intent)

        setContent {
            MaApp()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShareIntent(intent)
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (!text.isNullOrBlank()) {
                logger.i { "Received shared text (${text.length} chars)" }
                _sharedText.value = text
            }
        }
    }

    override fun onDestroy() {
        // Cleanup resources synchronously with timeout to prevent ANR
        // Note: lifecycleScope is cancelled before onDestroy(), so we use runBlocking
        try {
            kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.IO) {
                kotlinx.coroutines.withTimeout(5000) {
                    // 5 second timeout
                    try {
                        // Close AI engine (ONNX cleanup on IO thread)
                        aiEngine.close()
                    } catch (e: Exception) {
                        logger.w(e) { "Error during cleanup" }
                    }
                }
            }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            logger.w { "Cleanup timeout - forcing shutdown" }
        }
        super.onDestroy()
    }
}

/**
 * MaApp - Main application composable with initialization management
 *
 * Uses InitializationViewModel to handle database and knowledge base setup.
 * Shows loading, success, or error states based on initialization progress.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MaApp() {
    // One theme decision, made once, at the true root — every branch below
    // (onboarding, loading, error, the real app) used to reach for its own
    // MaTheme, or none at all, and the composables in between (this Box) had
    // no Surface to paint on, so they fell through to the native window
    // background instead of M1K3's dark scheme (finding: "no theme
    // decision" — macos/docs/DESIGN_DOCTRINE.md principle 4).
    MaTheme {
        androidx.compose.material3.Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background,
        ) {
            MaAppBody()
        }
    }
}

@Composable
private fun MaAppBody() {
    val prefs = koinInject<app.m1k3.ai.assistant.platform.PreferencesStoreInterface>()
    var onboardingComplete by remember {
        mutableStateOf(
            prefs.getBoolean(app.m1k3.ai.assistant.platform.PreferenceKeys.ONBOARDING_COMPLETE, false),
        )
    }

    if (!onboardingComplete) {
        app.m1k3.ai.assistant.ui.OnboardingScreen(
            onComplete = { onboardingComplete = true },
        )
        return
    }

    val initViewModel = koinViewModel<InitializationViewModel>()
    // collectAsStateWithLifecycle stops collection when the app is backgrounded,
    // preventing wasted work during the init flow while the screen is off.
    val initState by initViewModel.state.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) {
        initViewModel.initialize()
    }

    when (val state = initState) {
        is InitializationState.NotStarted -> {
            // Show nothing or splash
        }

        is InitializationState.Loading -> {
            // TODO: Create proper loading screen
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(state.message, style = MaterialTheme.typography.bodyLarge)
            }
        }

        is InitializationState.Success -> {
            MaAppContent()
        }

        is InitializationState.Error -> {
            // TODO: Create proper error screen with retry
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Initialization failed: ${state.message}")
                    TextButton(onClick = { initViewModel.retry() }) {
                        Text("Retry")
                    }
                }
            }
        }
    }
}

/**
 * MaAppContent - Main app UI after successful initialization.
 *
 * One NavigationStack-equivalent back stack rooted on Chat. No app-level
 * Scaffold/drawer — every destination owns its own top bar.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MaAppContent() {
    val database = koinInject<MaDatabase>()

    MaTheme {
        val navController = rememberNavController()
        val appAvatarVM = rememberAvatarViewModel()

        CompositionLocalProvider(LocalSharedAvatarVM provides appAvatarVM) {
            NavHost(
                navController = navController,
                startDestination = Screen.Chat.route,
            ) {
                composable(Screen.Chat.route) {
                    ChatScreen(
                        onNavigateToSettings = { navController.navigate(Screen.Settings.route) },
                        onNavigateToVoiceMode = { navController.navigate(Screen.VoiceMode.route) },
                        projectId = "default",
                    )
                }

                composable(Screen.VoiceMode.route) {
                    // Same ChatScreenViewModel instance Chat is using — a voice
                    // turn runs through the exact path typed chat uses
                    // (runVoiceTurn), no second turn mechanism.
                    val chatViewModel =
                        koinViewModel<ChatScreenViewModel>(
                            viewModelStoreOwner = navController.getBackStackEntry(Screen.Chat.route),
                        ) { parametersOf("default") }
                    val context = LocalContext.current
                    val speaker = koinInject<Speaker>()
                    val scope = rememberCoroutineScope()
                    val sttEngine = remember { AndroidSttEngine(context) }
                    val controller =
                        remember {
                            VoiceLoopController(
                                stt = sttEngine,
                                speaker = speaker,
                                runTurn = { question ->
                                    runVoiceTurn(
                                        question = question,
                                        uiState = chatViewModel.uiState,
                                        updateInputText = chatViewModel::updateInputText,
                                        sendMessage = chatViewModel::sendMessage,
                                    )
                                },
                                scope = scope,
                            )
                        }
                    DisposableEffect(Unit) {
                        onDispose { sttEngine.release() }
                    }
                    VoiceScreen(
                        controller = controller,
                        onExit = { navController.navigateUp() },
                    )
                }

                composable(Screen.Settings.route) {
                    // Same ChatScreenViewModel instance Chat is using (Chat's back
                    // stack entry never pops while Settings is pushed on top), so
                    // picking a brain here calls the exact mechanism the in-chat
                    // model picker uses — no second source of truth.
                    val chatViewModel =
                        koinViewModel<ChatScreenViewModel>(
                            viewModelStoreOwner = navController.getBackStackEntry(Screen.Chat.route),
                        ) { parametersOf("default") }
                    val chatUiState by chatViewModel.collectAsState()
                    SettingsScreen(
                        currentModel = chatUiState.currentModel,
                        onSelectBrain = { model -> chatViewModel.switchModel(model) },
                        onNavigateToMemories = { navController.navigate(Screen.Memories.route) },
                        onNavigateToDocuments = { navController.navigate(Screen.Documents.route) },
                        onNavigateToConversations = { navController.navigate(Screen.History.route) },
                        onNavigateToLicenses = { navController.navigate(Screen.Licenses.route) },
                    )
                }

                composable(Screen.Memories.route) {
                    MemoriesScreen(onBack = { navController.navigateUp() })
                }

                composable(Screen.Documents.route) {
                    DocumentsScreen(onBack = { navController.navigateUp() })
                }

                composable(Screen.History.route) {
                    HistoryScreen(
                        database = database,
                        projectId = "default",
                        onBackClick = { navController.navigateUp() },
                        onConversationClick = { conversationId ->
                            navController.navigate("conversation/$conversationId")
                        },
                    )
                }

                composable(Screen.Licenses.route) {
                    LicensesScreen(onBack = { navController.navigateUp() })
                }

                // Conversation Detail Screen
                composable(
                    route = Screen.ConversationDetail.route,
                    arguments =
                        listOf(
                            navArgument(Screen.ConversationDetail.argConversationId) {
                                type = NavType.LongType
                            },
                        ),
                ) { backStackEntry ->
                    val conversationId =
                        backStackEntry.arguments?.getLong(
                            Screen.ConversationDetail.argConversationId,
                        ) ?: 0L

                    // TODO: Create ConversationDetailScreen in Phase 3
                    Box(
                        modifier = Modifier.fillMaxSize(),
                        contentAlignment = Alignment.Center,
                    ) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(16.dp),
                        ) {
                            Text(
                                "Conversation Detail",
                                style = MaterialTheme.typography.headlineMedium,
                            )
                            Text("ID: $conversationId")
                            TextButton(onClick = { navController.navigateUp() }) {
                                Text("← Back")
                            }
                        }
                    }
                }
            }
        }
    }
}
