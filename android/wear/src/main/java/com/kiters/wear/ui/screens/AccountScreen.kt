package com.kiters.wear.ui.screens

import android.graphics.Bitmap
import android.os.Build
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipColors
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.CircularProgressIndicator
import androidx.wear.compose.material.Text
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.kiters.wear.R
import com.kiters.wear.auth.AuthRepository
import com.kiters.wear.auth.AuthSession
import com.kiters.wear.auth.PairingPoll
import com.kiters.wear.auth.PairingRequest
import com.kiters.wear.session.SessionManager
import com.kiters.wear.ui.components.ListScaffold
import com.kiters.wear.ui.theme.themeColor
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

private sealed class AccountUiState {
    object SignedOut : AccountUiState()
    object Loading : AccountUiState()
    data class Pairing(val request: PairingRequest) : AccountUiState()
    data class Error(val message: String) : AccountUiState()
    data class SignedIn(val label: String) : AccountUiState()
}

@Composable
fun AccountScreen(vm: SessionManager, nav: NavController) {
    val context = LocalContext.current
    val settings = vm.settingsStore
    val scope = rememberCoroutineScope()
    val authRepo = remember { AuthRepository() }
    val accent = themeColor(settings.appTheme)

    val initialLabel = settings.authEmail.ifBlank {
        if (settings.authAccessToken.isNotBlank()) context.getString(R.string.account_connected_title) else ""
    }
    val initial: AccountUiState =
        if (initialLabel.isNotBlank() && settings.authAccessToken.isNotBlank()) {
            AccountUiState.SignedIn(initialLabel)
        } else {
            AccountUiState.SignedOut
        }

    var uiState by remember { mutableStateOf<AccountUiState>(initial) }
    var pairingStartNonce by remember { mutableStateOf(0) }

    fun sessionLabel(session: AuthSession): String =
        session.email.ifBlank { context.getString(R.string.account_connected_title) }

    fun applySession(session: AuthSession) {
        settings.authAccessToken = session.accessToken
        settings.authRefreshToken = session.refreshToken
        settings.authEmail = session.email
        settings.authUserId = session.userId
        settings.authExpiresAt = session.expiresAt
        uiState = AccountUiState.SignedIn(sessionLabel(session))
    }

    suspend fun startPairing() {
        uiState = AccountUiState.Loading
        runCatching {
            withTimeout(15_000) {
                authRepo.requestPairing(
                    deviceName = Build.MANUFACTURER,
                    deviceModel = Build.MODEL,
                ).getOrThrow()
            }
        }.onSuccess { request ->
            uiState = AccountUiState.Pairing(request)
        }.onFailure { err ->
            uiState = AccountUiState.Error(
                if (err is TimeoutCancellationException) {
                    context.getString(R.string.account_pair_start_failed)
                } else {
                    err.message ?: context.getString(R.string.account_pair_start_failed)
                },
            )
        }
    }

    LaunchedEffect(pairingStartNonce) {
        if (uiState !is AccountUiState.SignedIn) {
            startPairing()
        }
    }

    val pairingState = uiState as? AccountUiState.Pairing
    LaunchedEffect(pairingState?.request?.code) {
        val request = pairingState?.request ?: return@LaunchedEffect
        while (true) {
            val nowSeconds = System.currentTimeMillis() / 1000L
            if (nowSeconds >= request.expiresAtEpochSeconds) {
                uiState = AccountUiState.Error(context.getString(R.string.account_pair_expired))
                return@LaunchedEffect
            }

            when (val poll = authRepo.pollPairing(request.code)) {
                is PairingPoll.Approved -> {
                    applySession(poll.session)
                    return@LaunchedEffect
                }
                PairingPoll.Expired -> {
                    uiState = AccountUiState.Error(context.getString(R.string.account_pair_expired))
                    return@LaunchedEffect
                }
                is PairingPoll.Failed -> {
                    uiState = AccountUiState.Error(poll.message)
                    return@LaunchedEffect
                }
                PairingPoll.Pending -> delay(2_000)
            }
        }
    }

    ListScaffold { listState ->
        ScalingLazyColumn(modifier = Modifier.fillMaxWidth(), state = listState) {
            item { AccountSectionTitle(context.getString(R.string.account_section_title), big = true) }

            when (val state = uiState) {
                AccountUiState.SignedOut,
                AccountUiState.Loading -> {
                    item {
                        CircularProgressIndicator(
                            modifier = Modifier.padding(16.dp),
                            strokeWidth = 2.dp,
                        )
                    }
                    item {
                        Text(
                            context.getString(R.string.account_pair_preparing),
                            color = Color.Gray,
                            fontSize = 11.sp,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                        )
                    }
                }

                is AccountUiState.Pairing -> {
                    item {
                        Text(
                            context.getString(R.string.account_pair_scan_title),
                            color = Color.White,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Bold,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                        )
                    }
                    item {
                        PairingQrImage(state.request.qrPayload)
                    }
                    item {
                        Text(
                            context.getString(R.string.account_pair_scan_hint),
                            color = Color.Gray,
                            fontSize = 10.sp,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                        )
                    }
                    item {
                        Text(
                            context.getString(R.string.account_pair_waiting),
                            color = Color.Gray,
                            fontSize = 10.sp,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
                        )
                    }
                }

                is AccountUiState.SignedIn -> {
                    item {
                        Text(
                            "${context.getString(R.string.account_signed_in_as)}\n${state.label}",
                            color = Color.White,
                            fontSize = 11.sp,
                            textAlign = TextAlign.Center,
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
                                pairingStartNonce += 1
                            }
                        }
                    }
                }

                is AccountUiState.Error -> {
                    item {
                        Text(
                            state.message,
                            color = Color(0xFFFF9800),
                            fontSize = 11.sp,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                        )
                    }
                    item {
                        AccountChipRow(
                            context.getString(R.string.account_pair_new_code),
                            ChipDefaults.primaryChipColors(backgroundColor = accent),
                        ) {
                            pairingStartNonce += 1
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PairingQrImage(payload: String) {
    val bitmap = remember(payload) { makeQrBitmap(payload, 152) }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            bitmap = bitmap.asImageBitmap(),
            contentDescription = null,
            modifier = Modifier
                .size(136.dp)
                .background(Color.White, RoundedCornerShape(8.dp))
                .padding(6.dp),
        )
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
    colors: ChipColors,
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

private fun makeQrBitmap(payload: String, size: Int): Bitmap {
    val hints = mapOf(
        EncodeHintType.CHARACTER_SET to "UTF-8",
        EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M,
        EncodeHintType.MARGIN to 1,
    )
    val matrix = QRCodeWriter().encode(payload, BarcodeFormat.QR_CODE, size, size, hints)
    val bitmap = Bitmap.createBitmap(matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
    for (y in 0 until matrix.height) {
        for (x in 0 until matrix.width) {
            bitmap.setPixel(x, y, if (matrix[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
        }
    }
    return bitmap
}
