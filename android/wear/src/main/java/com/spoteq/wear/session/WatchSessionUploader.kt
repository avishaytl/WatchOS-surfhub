package com.spoteq.wear.session

import com.spoteq.wear.auth.AuthRepository
import com.spoteq.wear.auth.AuthSession
import com.spoteq.wear.storage.SettingsStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

data class StartResponse(val sessId: Int, val spot: String, val poiKind: String)
data class RecordResponse(val broken: List<String>)
data class EndResponse(val broken: List<String>)

sealed class UploaderError(message: String) : Exception(message) {
    object NotAuthenticated : UploaderError("Not signed in — please log in again.")
    data class ServerError(val status: Int, val body: String) : UploaderError("Server error $status: $body")
    data class NetworkError(override val message: String) : UploaderError(message)
}

/**
 * HTTP client for the four watch-ingest lifecycle calls.
 * Reads the current JWT from SettingsStore, refreshing via AuthRepository if needed.
 */
class WatchSessionUploader(
    private val settings: SettingsStore,
    private val authRepo: AuthRepository = AuthRepository(),
) {
    private val ingestUrl = "https://vvowvcdylztsqpzifdqc.supabase.co/functions/v1/watch-ingest"
    private val anonKey   = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2b3d2Y2R5bHp0c3FwemlmZHFjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU0MTc1NDcsImV4cCI6MjA5MDk5MzU0N30.jPBYr6f9fTABLHAD1rY_b1HP8xI0cDEQPJczxjCKsSY"

    // MARK: - start

    suspend fun start(lat: Double, lng: Double, startedAt: Date = Date()): Result<StartResponse> =
        withContext(Dispatchers.IO) {
            runCatching {
                val iso = isoDate(startedAt)
                val body = JSONObject().apply {
                    put("type", "start"); put("lat", lat); put("lng", lng); put("startedAt", iso)
                }
                val json = post(body)
                StartResponse(
                    sessId  = json.getInt("sessId"),
                    spot    = json.optString("spot", ""),
                    poiKind = json.optString("poiKind", ""),
                )
            }
        }

    // MARK: - ping

    suspend fun ping(sessId: Int, lat: Double, lng: Double,
                     jmax: Double? = null, jcnt: Int? = null): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                val body = JSONObject().apply {
                    put("type", "ping"); put("sessId", sessId); put("lat", lat); put("lng", lng)
                    jmax?.let { put("jmax", it) }
                    jcnt?.let { put("jcnt", it) }
                }
                post(body)
                Unit
            }
        }

    // MARK: - record

    suspend fun record(sessId: Int, jumpM: Double? = null, airS: Double? = null,
                       speedKmh: Double? = null, distKm: Double? = null): Result<RecordResponse> =
        withContext(Dispatchers.IO) {
            runCatching {
                val body = JSONObject().apply {
                    put("type", "record"); put("sessId", sessId)
                    jumpM?.let    { put("jumpM", it)    }
                    airS?.let     { put("airS", it)     }
                    speedKmh?.let { put("speedKmh", it) }
                    distKm?.let   { put("distKm", it)   }
                }
                val json = post(body)
                RecordResponse(broken = jsonArrayToList(json.optJSONArray("broken")))
            }
        }

    // MARK: - end

    suspend fun end(
        sessId: Int,
        durMin: Int, jmax: Double, jcnt: Int, airS: Double,
        spdKmh: Int, distKm: Double,
        windKts: Int? = null, dir: String? = null, avgKmh: Double? = null,
        stars: Int = 3,
        track: List<List<Int>>,
        jData: List<Map<String, Int>>,
    ): Result<EndResponse> = withContext(Dispatchers.IO) {
        runCatching {
            val trackArr = JSONArray().apply { track.forEach { pt -> add(JSONArray().apply { pt.forEach { add(it) } }) } }
            val jDataArr = JSONArray().apply { jData.forEach { j -> add(JSONObject(j as Map<*, *>)) } }
            val body = JSONObject().apply {
                put("type", "end"); put("sessId", sessId)
                put("durMin", durMin); put("jmax", jmax); put("jcnt", jcnt)
                put("airS", airS); put("spdKmh", spdKmh); put("distKm", distKm)
                put("stars", stars); put("track", trackArr); put("jData", jDataArr)
                windKts?.let { put("windKts", it) }
                dir?.let     { put("dir", it)     }
                avgKmh?.let  { put("avgKmh", it)  }
            }
            val json = post(body)
            EndResponse(broken = jsonArrayToList(json.optJSONArray("broken")))
        }
    }

    // MARK: - Private

    private suspend fun accessToken(): String {
        val token    = settings.authAccessToken
        val expires  = settings.authExpiresAt
        val refresh  = settings.authRefreshToken
        if (token.isBlank()) throw UploaderError.NotAuthenticated
        val nowSec = System.currentTimeMillis() / 1000L
        if (expires - nowSec < 120 && refresh.isNotBlank()) {
            authRepo.refreshToken(refresh).getOrNull()?.let { session: AuthSession ->
                settings.authAccessToken  = session.accessToken
                settings.authRefreshToken = session.refreshToken
                settings.authExpiresAt    = session.expiresAt
                return session.accessToken
            }
        }
        return token
    }

    private suspend fun post(body: JSONObject): JSONObject {
        val jwt = accessToken()
        val conn = (URL(ingestUrl).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            setRequestProperty("Content-Type",  "application/octet-stream")
            setRequestProperty("apikey",        anonKey)
            setRequestProperty("Authorization", "Bearer $jwt")
            doOutput     = true
            connectTimeout = 15_000
            readTimeout    = 15_000
        }
        conn.outputStream.use { os ->
            os.write(BinaryLogEnvelope.encode(body))
        }
        val status = conn.responseCode
        if (status == 401) {
            settings.authAccessToken = ""
            conn.disconnect()
            throw UploaderError.NotAuthenticated
        }
        val responseBody = if (status in 200..299)
            conn.inputStream.bufferedReader().readText()
        else
            conn.errorStream?.bufferedReader()?.readText() ?: ""
        conn.disconnect()
        if (status !in 200..299) throw UploaderError.ServerError(status, responseBody)
        return if (responseBody.isNotBlank()) JSONObject(responseBody) else JSONObject()
    }

    private fun jsonArrayToList(arr: JSONArray?): List<String> {
        if (arr == null) return emptyList()
        return (0 until arr.length()).map { arr.getString(it) }
    }

    private fun isoDate(date: Date): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        return fmt.format(date)
    }

    private fun JSONArray.add(value: Any) = put(value)
}
