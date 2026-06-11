package com.kiters.wear.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicSecureTextField
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.CircularProgressIndicator
import androidx.wear.compose.material.Text
import com.kiters.wear.R
import com.kiters.wear.auth.AuthError
import com.kiters.wear.auth.AuthRepository
import com.kiters.wear.auth.AuthSession
import com.kiters.wear.session.SessionManager
import com.kiters.wear.ui.components.ListScaffold
import com.kiters.wear.ui.theme.themeColor
import kotlinx.coroutines.launch

private sealed class AccountUiState {
    object SignedOut : AccountUiState()
    object Loading : AccountUiState()
    data class Error(val message: String) : AccountUiState()
    data class SignedIn(val email: String) : AccountUiState()
}

@Composable
fun AccountScreen(vm: SessionManager, nav: NavController) {
    val context = LocalContext.current
    val settings = vm.settingsStore
    val scope = rememberCoroutineScope()
    val authRepo = remember { AuthRepository() }
    val accent = themeColor(settings.appTheme)

    val initial: AccountUiState =
        if (settings.authEmail.isNotBlank()) AccountUiState.SignedIn(settings.authEmail)
        else AccountUiState.SignedOut

    var uiState by remember { mutableStateOf<AccountUiState>(initial) }
    var emailInput by remember { mutableStateOf("sanbata.tv@gmail.com") }
    var passwordInput by remember { mutableStateOf("123456") }

    ListScaffold { listState ->
        ScalingLazyColumn(modifier = Modifier.fillMaxWidth(), state = listState) {

            item { AccountSectionTitle(context.getString(R.string.account_section_title), big = true) }

            when (val state = uiState) {
                is AccountUiState.SignedOut -> {
                    item {
                        BasicTextField(
                            value = emailInput,
                            onValueChange = { emailInput = it },
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 8.dp)
                                .background(Color.White.copy(alpha = 0.1f), RoundedCornerShape(8.dp))
                                .padding(8.dp),
                            textStyle = TextStyle(
                                color = Color.White, fontSize = 13.sp,
                                textAlign = TextAlign.Center,
                            ),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                            singleLine = true,
                            decorationBox = { inner ->
                                if (emailInput.isEmpty()) {
                                    Text(
                                        context.getString(R.string.account_email_placeholder),
                                        color = Color.Gray, fontSize = 13.sp,
                                        textAlign = TextAlign.Center,
                                        modifier = Modifier.fillMaxWidth(),
                                    )
                                }
                                inner()
                            },
                        )
                    }
                    item {
                        BasicSecureTextField(
                            value = passwordInput,
                            onValueChange = { passwordInput = it },
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 8.dp)
                                .background(Color.White.copy(alpha = 0.1f), RoundedCornerShape(8.dp))
                                .padding(8.dp),
                            textStyle = TextStyle(
                                color = Color.White, fontSize = 13.sp,
                                textAlign = TextAlign.Center,
                            ),
                            decorator = { inner ->
                                if (passwordInput.isEmpty()) {
                                    Text(
                                        context.getString(R.string.account_password_placeholder),
                                        color = Color.Gray, fontSize = 13.sp,
                                        textAlign = TextAlign.Center,
                                        modifier = Modifier.fillMaxWidth(),
                                    )
                                }
                                inner()
                            },
                        )
                    }
                    item {
                        val canSignIn = emailInput.isNotBlank() && passwordInput.isNotEmpty()
                        AccountChipRow(
                            context.getString(R.string.account_sign_in),
                            if (canSignIn) ChipDefaults.primaryChipColors(backgroundColor = accent)
                            else ChipDefaults.secondaryChipColors(),
                        ) {
                            if (canSignIn) {
                                scope.launch {
                                    uiState = AccountUiState.Loading
                                    authRepo.signInWithEmail(emailInput.trim(), passwordInput)
                                        .onSuccess { session: AuthSession ->
                                            settings.authAccessToken = session.accessToken
                                            settings.authRefreshToken = session.refreshToken
                                            settings.authEmail = session.email
                                            settings.authUserId = session.userId
                                            settings.authExpiresAt = session.expiresAt
                                            uiState = AccountUiState.SignedIn(session.email)
                                        }
                                        .onFailure { err ->
                                            val msg = when (err) {
                                                is AuthError.ServerMessage -> err.msg
                                                is AuthError.InvalidCredentials -> context.getString(R.string.account_invalid_credentials)
                                                else -> err.message ?: context.getString(R.string.account_invalid_credentials)
                                            }
                                            uiState = AccountUiState.Error(msg)
                                        }
                                }
                            }
                        }
                    }
                    item {
                        Text(
                            context.getString(R.string.account_no_account_hint),
                            color = Color.Gray, fontSize = 10.sp, textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
                        )
                    }
                }

                is AccountUiState.SignedIn -> {
                    item {
                        Text(
                            "${context.getString(R.string.account_signed_in_as)}\n${state.email}",
                            color = Color.White, fontSize = 11.sp, textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                        )
                    }
                    item {
                        AccountChipRow(
                            context.getString(R.string.account_sign_out),
                            ChipDefaults.primaryChipColors(backgroundColor = Color.Red.copy(alpha = 0.7f)),
                        ) {
                            scope.launch {
                                val token = settings.authAccessToken
                                settings.authAccessToken = ""
                                settings.authRefreshToken = ""
                                settings.authEmail = ""
                                settings.authUserId = ""
                                settings.authExpiresAt = 0L
                                if (token.isNotBlank()) authRepo.signOut(token)
                                uiState = AccountUiState.SignedOut
                                emailInput = ""
                                passwordInput = ""
                            }
                        }
                    }
                }

                AccountUiState.Loading -> {
                    item {
                        CircularProgressIndicator(
                            modifier = Modifier.padding(16.dp),
                            strokeWidth = 2.dp,
                        )
                    }
                }

                is AccountUiState.Error -> {
                    item {
                        Text(
                            state.message, color = Color(0xFFFF9800), fontSize = 11.sp,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                        )
                    }
                    item {
                        AccountChipRow(
                            context.getString(R.string.account_try_again),
                            ChipDefaults.primaryChipColors(backgroundColor = accent),
                        ) {
                            uiState = AccountUiState.SignedOut
                            passwordInput = ""
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AccountSectionTitle(text: String, big: Boolean = false) {
    Text(
        text,
        color = if (big) Color.White else Color.Gray,
        fontSize = if (big) 18.sp else 11.sp,
        fontWeight = if (big) FontWeight.Bold else FontWeight.Normal,
        modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
        textAlign = TextAlign.Center,
    )
}

@Composable
private fun AccountChipRow(
    label: String,
    colors: androidx.wear.compose.material.ChipColors,
    onClick: () -> Unit,
) {
    Chip(
        onClick = onClick,
        colors = colors,
        modifier = Modifier.fillMaxWidth(),
        label = {
            Text(label, modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center, fontSize = 13.sp)
        },
    )
}
