package com.kiters.wear.auth

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

data class AuthSession(
    val accessToken: String,
    val refreshToken: String,
    val email: String,
    val userId: String,
    val expiresAt: Long,
)

sealed class AuthError : Exception() {
    object InvalidCredentials : AuthError()
    data class NetworkError(override val message: String) : AuthError()
}

class AuthRepository {
    private val anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2b3d2Y2R5bHp0c3FwemlmZHFjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU0MTc1NDcsImV4cCI6MjA5MDk5MzU0N30.jPBYr6f9fTABLHAD1rY_b1HP8xI0cDEQPJczxjCKsSY"
    private val baseUrl = "https://vvowvcdylztsqpzifdqc.supabase.co"

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
                    conn.disconnect()
                    throw AuthError.InvalidCredentials
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
