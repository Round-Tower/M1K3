package app.m1k3.ai.assistant

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBars
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import app.cash.sqldelight.db.SqlDriver
import app.m1k3.ai.assistant.ai.BaseLlmEngine
import app.m1k3.ai.assistant.ai.LlamaCppEngine
import app.m1k3.ai.assistant.app.AndroidDatabaseInitializer
import app.m1k3.ai.assistant.app.AppInitializationManager
import app.m1k3.ai.assistant.app.DatabaseInitResult
import app.m1k3.ai.assistant.app.ILogger
import app.m1k3.ai.assistant.app.InitializationResult
import app.m1k3.ai.assistant.app.InitializationState
import app.m1k3.ai.assistant.app.InitializationViewModel
import app.m1k3.ai.assistant.app.LoggerAdapter
import app.m1k3.ai.assistant.avatar.LocalSharedAvatarVM
import app.m1k3.ai.assistant.avatar.collectAsState
import app.m1k3.ai.assistant.avatar.rememberAvatarViewModel
import app.m1k3.ai.assistant.chat.ChatScreenViewModel
import app.m1k3.ai.assistant.database.MaDatabase
import app.m1k3.ai.assistant.design.theme.MaTheme
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.di.allModules
import app.m1k3.ai.assistant.embedding.EmbeddingEngine
import app.m1k3.ai.assistant.embedding.EmbeddingEngineManager
import app.m1k3.ai.assistant.navigation.Screen
import app.m1k3.ai.assistant.navigation.navigateToBottomNav
import app.m1k3.ai.assistant.ui.AboutScreen
import app.m1k3.ai.assistant.ui.ChatScreen
import app.m1k3.ai.assistant.ui.ExportScreen
import app.m1k3.ai.assistant.ui.FeedbackScreen
import app.m1k3.ai.assistant.ui.HelpScreen
import app.m1k3.ai.assistant.ui.HistoryScreen
import app.m1k3.ai.assistant.ui.LicensesScreen
import app.m1k3.ai.assistant.ui.PrivacyScreen
import app.m1k3.ai.assistant.ui.components.Toolbar
import app.m1k3.ai.assistant.ui.drawer.DrawerContent
import app.m1k3.ai.assistant.utils.Logger
import kotlinx.coroutines.CoroutineScope
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
import co.touchlab.kermit.Logger as KermitLogger

/**
 * M1K3 AI - MainActivity
 *
 * Minimalist demo showcasing:
 * - Privacy-first architecture (on-device chat; user-initiated network only — see ADR-0006)
 * - Encrypted database foundation
 * - Beautiful Material 3 design
 * - "Negative space" philosophy
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
    val prefs = koinInject<app.m1k3.ai.assistant.platform.PreferencesStoreInterface>()
    var onboardingComplete by remember {
        mutableStateOf(
            prefs.getBoolean(app.m1k3.ai.assistant.platform.PreferenceKeys.ONBOARDING_COMPLETE, false),
        )
    }

    if (!onboardingComplete) {
        app.m1k3.ai.assistant.design.theme.MaTheme {
            app.m1k3.ai.assistant.ui.OnboardingScreen(
                onComplete = { onboardingComplete = true },
            )
        }
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
 * MaAppContent - Main app UI after successful initialization
 *
 * Contains navigation, drawer, and all app screens.
 * Database is available via Koin injection.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MaAppContent() {
    // Get database from Koin for screens that need it directly
    val database = koinInject<MaDatabase>()

    MaTheme {
        val navController = rememberNavController()
        val appAvatarVM = rememberAvatarViewModel()
        val appAvatarState by appAvatarVM.collectAsState()

        // Shared mutable state so the current screen can publish
        // Toolbar actions (e.g. "New chat") without prop-drilling
        // through the Scaffold. ChatScreen writes to this on entry
        // and clears it on dispose.
        val toolbarActionsState =
            remember {
                mutableStateOf(
                    app.m1k3.ai.assistant.ui.components
                        .ToolbarActions(),
                )
            }

        var drawerOpen by remember { mutableStateOf(false) }

        val drawerState = rememberDrawerState(DrawerValue.Closed)

        LaunchedEffect(drawerOpen) {
            if (drawerOpen) {
                drawerState.open()
            } else {
                drawerState.close()
            }
        }

        LaunchedEffect(drawerState.currentValue) {
            drawerOpen = drawerState.currentValue == DrawerValue.Open
        }

        val haptics = LocalHapticFeedback.current
        val isDarkMode = isSystemInDarkTheme()

        // Animate content offset based on drawer state
        val contentOffset by animateDpAsState(
            targetValue = if (drawerOpen) 280.dp else 0.dp,
            animationSpec = tween(durationMillis = 300),
        )

        ModalNavigationDrawer(
            drawerContent = {
                DrawerContent(
                    currentRoute =
                        navController
                            .currentBackStackEntryAsState()
                            .value
                            ?.destination
                            ?.route,
                    isDarkMode = isDarkMode,
                    onItemClick = { route ->
                        // Primary nav uses navigateToBottomNav for proper back stack
                        val primaryRoutes =
                            setOf(
                                Screen.Chat.route,
                                Screen.History.route,
                                Screen.Settings.route,
                            )
                        if (route in primaryRoutes) {
                            val screen =
                                when (route) {
                                    Screen.Chat.route -> Screen.Chat
                                    Screen.History.route -> Screen.History
                                    Screen.Settings.route -> Screen.Settings
                                    else -> Screen.Chat
                                }
                            navController.navigateToBottomNav(screen)
                        } else {
                            navController.navigate(route)
                        }
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    },
                    onMenuClose = { drawerOpen = false },
                )
            },
            scrimColor = if (isDarkMode) MaColors.ScrimMedium else MaColors.ScrimMediumLight,
            drawerState = drawerState,
        ) {
            Box(
                modifier =
                    Modifier
                        .fillMaxSize()
                        .offset(x = contentOffset),
            ) {
                // Lift the shared avatar state above the Scaffold so the
                // Toolbar slot can consume it too.
                CompositionLocalProvider(
                    LocalSharedAvatarVM provides appAvatarVM,
                    app.m1k3.ai.assistant.ui.components.LocalToolbarActions provides toolbarActionsState,
                ) {
                    Scaffold(
                        topBar = {
                            Toolbar(
                                screenName =
                                    getScreenName(
                                        navController
                                            .currentBackStackEntryAsState()
                                            .value
                                            ?.destination
                                            ?.route,
                                    ),
                                engineInitialized = true,
                                avatarState = appAvatarState,
                                onMenuClick = { drawerOpen = !drawerOpen },
                                modifier = Modifier.fillMaxWidth(),
                            )
                        },
                        // Zero out Scaffold's automatic inset padding so content can
                        // extend to true screen edges (chat background behind status/nav bars).
                        // Individual screens call windowInsetsPadding where they need it.
                        // The Toolbar sits in topBar and Compose positions it below the
                        // status bar automatically via the slot's own inset handling.
                        contentWindowInsets = WindowInsets(0, 0, 0, 0),
                    ) { paddingValues ->
                        NavHost(
                            navController = navController,
                            startDestination = Screen.Chat.route,
                            // Only top padding from the Toolbar slot — bottom/sides
                            // are screen-owned so the background bleeds to all edges.
                            modifier = Modifier.padding(top = paddingValues.calculateTopPadding()),
                        ) {
                            // Chat Screen
                            composable(Screen.Chat.route) {
                                ChatScreen(
                                    projectId = "default",
                                )
                            }

                            // History Screen
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

                            // Settings Screen
                            composable(Screen.Settings.route) {
                                app.m1k3.ai.assistant.ui.SettingsScreen(
                                    onNavigateToLicenses = {
                                        navController.navigate(Screen.Licenses.route)
                                    },
                                    onNavigateToDocuments = {
                                        navController.navigate(Screen.Documents.route)
                                    },
                                )
                            }

                            // Documents (personal knowledge)
                            composable(Screen.Documents.route) {
                                app.m1k3.ai.assistant.ui.DocumentsScreen(
                                    onBack = { navController.navigateUp() },
                                )
                            }

                            // Meta Screens (Drawer actions)
                            composable(Screen.About.route) {
                                AboutScreen(
                                    onLicensesClick = { navController.navigate(Screen.Licenses.route) },
                                )
                            }

                            composable(Screen.Licenses.route) {
                                LicensesScreen()
                            }

                            composable(Screen.Help.route) {
                                HelpScreen()
                            }

                            composable(Screen.Feedback.route) {
                                FeedbackScreen()
                            }

                            composable(Screen.Privacy.route) {
                                PrivacyScreen()
                            }

                            composable(Screen.Export.route) {
                                ExportScreen()
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
        }
    }
}

/**
 * Helper to get screen name from route for UnifiedToolbar
 */
private fun getScreenName(route: String?): String =
    when (route) {
        Screen.Chat.route -> "Chat"
        Screen.History.route -> "History"
        Screen.Settings.route -> "Settings"
        else -> "M1K3"
    }
