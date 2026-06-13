package com.kiters.wear.auth

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant

data class AuthSession(
    val accessToken: String,
    val refreshToken: String,
    val email: String,
    val userId: String,
    val expiresAt: Long,
)

data class PairingRequest(
    val code: String,
    val qrPayload: String,
    val expiresAtEpochSeconds: Long,
)

sealed class PairingPoll {
    object Pending : PairingPoll()
    object Expired : PairingPoll()
    data class Approved(val session: AuthSession) : PairingPoll()
    data class Failed(val message: String) : PairingPoll()
}

sealed class AuthError : Exception() {
    object InvalidCredentials : AuthError()
    data class ServerMessage(val msg: String, val statusCode: Int) : AuthError()
    data class NetworkError(override val message: String) : AuthError()
}

class AuthRepository {
    private val anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2b3d2Y2R5bHp0c3FwemlmZHFjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU0MTc1NDcsImV4cCI6MjA5MDk5MzU0N30.jPBYr6f9fTABLHAD1rY_b1HP8xI0cDEQPJczxjCKsSY"
    private val baseUrl = "https://vvowvcdylztsqpzifdqc.supabase.co"

    suspend fun requestPairing(deviceName: String?, deviceModel: String?): Result<PairingRequest> =
        withContext(Dispatchers.IO) {
            runCatching {
                val conn = openJson("$baseUrl/functions/v1/watch-link", "POST")
                conn.outputStream.use { os ->
                    OutputStreamWriter(os).use {
                        it.write(JSONObject().apply {
                            put("action", "request")
                            if (!deviceName.isNullOrBlank()) put("deviceName", deviceName)
                            if (!deviceModel.isNullOrBlank()) put("deviceModel", deviceModel)
                        }.toString())
                    }
                }
                val status = conn.responseCode
                val body = responseBody(conn, status)
                conn.disconnect()
                if (status !in 200..299) throw mapError(body, status)

                val json = JSONObject(body)
                PairingRequest(
                    code = json.getString("code"),
                    qrPayload = stringValue(json, "qrPayload", "qr_payload")
                        ?: error("Missing QR payload"),
                    expiresAtEpochSeconds = parseExpiresAt(
                        stringValue(json, "expiresAt", "expires_at"),
                    ),
                )
            }
        }

    suspend fun pollPairing(code: String): PairingPoll =
        withContext(Dispatchers.IO) {
            runCatching {
                val conn = openJson("$baseUrl/functions/v1/watch-link", "POST")
                conn.outputStream.use { os ->
                    OutputStreamWriter(os).use {
                        it.write(JSONObject().apply {
                            put("action", "poll")
                            put("code", code)
                        }.toString())
                    }
                }
                val status = conn.responseCode
                val body = responseBody(conn, status)
                conn.disconnect()

                when {
                    status == 404 || status == 410 -> PairingPoll.Expired
                    status !in 200..299 -> PairingPoll.Failed(pairingErrorMessage(body, status))
                    else -> {
                        val json = JSONObject(body)
                        if (json.optString("status") != "approved") {
                            PairingPoll.Pending
                        } else {
                            PairingPoll.Approved(parsePairingSession(json))
                        }
                    }
                }
            }.getOrElse { PairingPoll.Pending }
        }

    suspend fun signInWithEmail(email: String, password: String): Result<AuthSession> =
        withContext(Dispatchers.IO) {
            runCatching {
                val conn = openJson("$baseUrl/auth/v1/token?grant_type=password", "POST")
                conn.outputStream.use { os ->
                    OutputStreamWriter(os).use {
                        it.write(JSONObject().apply {
                            put("email", email)
                            put("password", password)
                        }.toString())
                    }
                }
                val code = conn.responseCode
                if (code == 400 || code == 401) {
                    val errBody = conn.errorStream?.bufferedReader()?.readText() ?: ""
                    conn.disconnect()
                    throw mapError(errBody, code)
                }
                if (code !in 200..299) {
                    conn.disconnect()
                    throw AuthError.NetworkError("HTTP $code")
                }
                val body = conn.inputStream.bufferedReader().readText()
                conn.disconnect()
                parseSession(body, email)
            }
        }

    suspend fun refreshToken(refreshToken: String): Result<AuthSession> =
        withContext(Dispatchers.IO) {
            runCatching {
                val conn = openJson("$baseUrl/auth/v1/token?grant_type=refresh_token", "POST")
                conn.outputStream.use { os ->
                    OutputStreamWriter(os).use {
                        it.write(JSONObject().put("refresh_token", refreshToken).toString())
                    }
                }
                val code = conn.responseCode
                if (code == 401) {
                    conn.disconnect()
                    throw AuthError.InvalidCredentials
                }
                if (code !in 200..299) {
                    conn.disconnect()
                    throw AuthError.NetworkError("HTTP $code")
                }
                val body = conn.inputStream.bufferedReader().readText()
                conn.disconnect()
                parseSession(body, "")
            }
        }

    suspend fun signOut(accessToken: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val conn = (URL("$baseUrl/auth/v1/logout").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                setRequestProperty("apikey", anonKey)
                setRequestProperty("Authorization", "Bearer $accessToken")
                connectTimeout = 10_000
                readTimeout = 10_000
            }
            conn.responseCode
            conn.disconnect()
        }
    }

    private fun mapError(body: String, status: Int): AuthError {
        val json = try { JSONObject(body) } catch (e: Exception) { JSONObject() }
        val serverMsg = json.optString("msg").takeIf { it.isNotBlank() }
            ?: json.optString("message").takeIf { it.isNotBlank() }
            ?: json.optString("error_description").takeIf { it.isNotBlank() }
        val hint = json.optString("hint").takeIf { it.isNotBlank() }
        val errorCode = json.optString("error_code")
        if (errorCode == "email_not_confirmed") return AuthError.ServerMessage("[$status] Email not confirmed", status)
        if (serverMsg != null) {
            val full = if (hint != null) "$serverMsg — $hint" else serverMsg
            return AuthError.ServerMessage("[$status] $full", status)
        }
        return AuthError.InvalidCredentials
    }

    private fun parseSession(body: String, fallbackEmail: String): AuthSession {
        val json = JSONObject(body)
        val access = json.getString("access_token")
        val refresh = json.getString("refresh_token")
        val expiresAt = json.optLong("expires_at", 0L)
        val user = json.optJSONObject("user")
        val userId = user?.optString("id").orEmpty()
        val email = user?.optString("email")?.takeIf { it.isNotBlank() } ?: fallbackEmail
        return AuthSession(
            accessToken = access,
            refreshToken = refresh,
            email = email,
            userId = userId,
            expiresAt = expiresAt,
        )
    }

    private fun parsePairingSession(json: JSONObject): AuthSession {
        val access = stringValue(json, "accessToken", "access_token")
            ?: error("Missing access token")
        val refresh = stringValue(json, "refreshToken", "refresh_token")
            ?: error("Missing refresh token")
        val userId = stringValue(json, "uid", "userId", "user_id")
            ?: error("Missing user id")
        val expiresAt = longValue(json, "expiresAt", "expires_at")
            ?: (System.currentTimeMillis() / 1000L + 3600L)
        val email = stringValue(json, "email").orEmpty()
        return AuthSession(
            accessToken = access,
            refreshToken = refresh,
            email = email,
            userId = userId,
            expiresAt = expiresAt,
        )
    }

    private fun responseBody(conn: HttpURLConnection, status: Int): String =
        if (status in 200..299) {
            conn.inputStream.bufferedReader().readText()
        } else {
            conn.errorStream?.bufferedReader()?.readText().orEmpty()
        }

    private fun pairingErrorMessage(body: String, status: Int): String {
        val json = try { JSONObject(body) } catch (e: Exception) { JSONObject() }
        val msg = json.optString("error").takeIf { it.isNotBlank() }
            ?: json.optString("msg").takeIf { it.isNotBlank() }
            ?: json.optString("message").takeIf { it.isNotBlank() }
            ?: json.optString("error_description").takeIf { it.isNotBlank() }
        return msg?.let { "[$status] $it" } ?: "[$status] Pairing failed"
    }

    private fun stringValue(json: JSONObject, vararg keys: String): String? {
        keys.forEach { key ->
            json.optString(key).takeIf { it.isNotBlank() }?.let { return it }
        }
        return null
    }

    private fun longValue(json: JSONObject, vararg keys: String): Long? {
        keys.forEach { key ->
            if (json.has(key)) {
                val value = json.opt(key)
                when (value) {
                    is Number -> return value.toLong()
                    is String -> value.toLongOrNull()?.let { return it }
                }
            }
        }
        return null
    }

    private fun parseExpiresAt(value: String?): Long =
        runCatching { value?.let { Instant.parse(it).epochSecond } }.getOrNull()
            ?: (System.currentTimeMillis() / 1000L + 300L)

    private fun openJson(urlStr: String, method: String): HttpURLConnection =
        (URL(urlStr).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("apikey", anonKey)
            doOutput = true
            connectTimeout = 10_000
            readTimeout = 10_000
        }
}
