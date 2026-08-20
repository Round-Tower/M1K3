package app.m1k3.ai.assistant.ui.components

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import app.m1k3.ai.assistant.design.haptics.rememberHapticFeedback
import app.m1k3.ai.assistant.design.tokens.MaColors

/**
 * ClearConversationDialog - Confirmation dialog for clearing chat history.
 *
 * Displays:
 * - Message count
 * - Destructive "Clear" button with haptic feedback
 * - "Cancel" button
 *
 * @param messageCount Number of messages that will be deleted
 * @param onConfirm Callback when user confirms clearing
 * @param onDismiss Callback when user cancels
 */
@Composable
fun ClearConversationDialog(
    messageCount: Int,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    val haptics = rememberHapticFeedback()

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Clear Conversation?") },
        text = {
            Text("This will permanently delete $messageCount messages.")
        },
        confirmButton = {
            Button(
                onClick = {
                    haptics.strong()
                    onConfirm()
                },
                colors =
                    ButtonDefaults.buttonColors(
                        containerColor = MaColors.Error,
                    ),
            ) {
                Text("Clear")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        },
    )
}
