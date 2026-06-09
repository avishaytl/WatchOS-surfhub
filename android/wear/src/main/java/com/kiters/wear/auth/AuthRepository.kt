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
)

class AuthRepository {

    // Replace with the value from Supabase Dashboard → Settings → API → "anon public".
    private val anonKey = "YOUR_SUPABASE_ANON_KEY_HERE"
    private val baseUrl = "https://vvowvcdylztsqpzifdqc.supabase.co"

    suspend fun sendOTP(email: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val conn = openJson("$baseUrl/auth/v1/otp", "POST")
            conn.outputStream.use { os ->
                OutputStreamWriter(os).use { it.write("""{"email":"$email","create_user":true}""") }
            }
            val code = conn.responseCode
            conn.disconnect()
            if (code !in 200..299) error("Failed to send code (HTTP $code)")
        }
    }

    suspend fun verifyOTP(email: String, token: String): Result<AuthSession> = withContext(Dispatchers.IO) {
        runCatching {
            val conn = openJson("$baseUrl/auth/v1/verify", "POST")
            conn.outputStream.use { os ->
                OutputStreamWriter(os).use {
                    it.write("""{"type":"email","email":"$email","token":"$token"}""")
                }
            }
            val code = conn.responseCode
            if (code !in 200..299) {
                conn.disconnect()
                error("Invalid code (HTTP $code)")
            }
            val body = conn.inputStream.bufferedReader().readText()
            conn.disconnect()
            val json = JSONObject(body)
            val access = json.getString("access_token")
            val refresh = json.getString("refresh_token")
            val userEmail = json.optJSONObject("user")?.optString("email") ?: email
            AuthSession(accessToken = access, refreshToken = refresh, email = userEmail)
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
