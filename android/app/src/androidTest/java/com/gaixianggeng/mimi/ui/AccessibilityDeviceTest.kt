package com.gaixianggeng.mimi.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assertIsNotFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import org.junit.Rule
import org.junit.Test

class AccessibilityDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun connectionFieldsExposeDeterministicImeFocusOrder() {
        var displayName by mutableStateOf("")
        var endpoint by mutableStateOf("")
        var token by mutableStateOf("")
        compose.setContent {
            MaterialTheme {
                ConnectionDetailsFields(
                    displayName = displayName,
                    endpoint = endpoint,
                    token = token,
                    onDisplayNameChange = { displayName = it },
                    onEndpointChange = { endpoint = it },
                    onTokenChange = { token = it },
                    modifier = Modifier.padding(16.dp),
                )
            }
        }

        compose.onNodeWithTag("connection_display_name").performClick().assertIsFocused()
        compose.onNodeWithTag("connection_display_name").performImeAction()
        compose.onNodeWithTag("connection_endpoint").assertIsFocused()
        compose.onNodeWithTag("connection_endpoint").performImeAction()
        compose.onNodeWithTag("connection_token").assertIsFocused()
        compose.onNodeWithTag("connection_token").performImeAction()
        compose.onNodeWithTag("connection_token").assertIsNotFocused()
    }

    @Test
    fun connectionFieldsRemainUsableAtTwoHundredPercentText() {
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(density.density, fontScale = 2f),
            ) {
                MaterialTheme {
                    ConnectionDetailsFields(
                        displayName = "Pixel 8",
                        endpoint = "192.168.31.163:8787",
                        token = "secret",
                        onDisplayNameChange = {},
                        onEndpointChange = {},
                        onTokenChange = {},
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
        }

        listOf("connection_display_name", "connection_endpoint", "connection_token").forEach { tag ->
            compose.onNodeWithTag(tag)
                .assertIsDisplayed()
                .assertHeightIsAtLeast(48.dp)
        }
    }
}
