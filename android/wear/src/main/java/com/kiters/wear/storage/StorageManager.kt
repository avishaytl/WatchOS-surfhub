package com.kiters.wear.storage

import android.content.Context
import android.util.Log
import com.kiters.wear.model.Session
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Manages local session storage as JSON files in filesDir/sessions/.
 * Faithful port of the watchOS StorageManager (which writes one JSON file
 * per session in the Documents directory).
 */
class StorageManager(context: Context) {

    private val appContext = context.applicationContext
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val prefs = appContext.getSharedPreferences("kiters_uploads", Context.MODE_PRIVATE)

    private val sessionsDir: File by lazy {
        File(appContext.filesDir, "sessions").apply { if (!exists()) mkdirs() }
    }

    fun saveSession(session: Session) {
        try {
            val file = File(sessionsDir, "${session.id}.json")
            file.writeText(json.encodeToString(Session.serializer(), session))
            Log.d(TAG, "Session saved: ${file.name}")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save session", e)
        }
    }

    fun loadSession(id: String): Session? = try {
        val file = File(sessionsDir, "$id.json")
        json.decodeFromString(Session.serializer(), file.readText())
    } catch (e: Exception) {
        Log.e(TAG, "Failed to load session $id", e)
        null
    }

    /** All sessions, newest first. */
    fun loadAllSessions(): List<Session> = try {
        (sessionsDir.listFiles { f -> f.extension == "json" } ?: emptyArray())
            .mapNotNull { f ->
                try {
                    json.decodeFromString(Session.serializer(), f.readText())
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to load session from ${f.name}")
                    null
                }
            }
            .sortedByDescending { it.startTimeMs }
    } catch (e: Exception) {
        Log.e(TAG, "Failed to load sessions", e)
        emptyList()
    }

    fun deleteSession(id: String) {
        try {
            File(sessionsDir, "$id.json").delete()
            clearPendingCloudUpload(id)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to delete session $id", e)
        }
    }

    fun markPendingCloudUpload(sessionId: String) {
        val ids = pendingCloudUploadSessionIds().toMutableSet()
        if (ids.add(sessionId)) {
            prefs.edit().putStringSet(PENDING_CLOUD_UPLOAD_IDS, ids).apply()
        }
    }

    fun clearPendingCloudUpload(sessionId: String) {
        val ids = pendingCloudUploadSessionIds().toMutableSet()
        if (ids.remove(sessionId)) {
            prefs.edit().putStringSet(PENDING_CLOUD_UPLOAD_IDS, ids).apply()
        }
    }

    fun loadMostRecentPendingCloudSession(): Session? {
        val ids = pendingCloudUploadSessionIds()
        if (ids.isEmpty()) return null
        return loadAllSessions().firstOrNull { ids.contains(it.id) }
    }

    fun clearAllSessions() {
        sessionsDir.listFiles()?.forEach { it.delete() }
        prefs.edit().remove(PENDING_CLOUD_UPLOAD_IDS).apply()
    }

    companion object {
        private const val TAG = "StorageManager"
        private const val PENDING_CLOUD_UPLOAD_IDS = "pendingCloudUploadSessionIds"
    }

    private fun pendingCloudUploadSessionIds(): Set<String> =
        prefs.getStringSet(PENDING_CLOUD_UPLOAD_IDS, emptySet()).orEmpty()
}
