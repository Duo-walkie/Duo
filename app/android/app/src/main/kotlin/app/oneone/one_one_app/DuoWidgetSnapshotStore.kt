package app.oneone.one_one_app

import android.content.Context
import android.graphics.Color
import org.json.JSONArray
import org.json.JSONObject

object DuoWidgetSyncContract {
    const val flutterChannel = "app.oneone/duo_widget"
}

data class DuoWidgetMember(
    val userId: String,
    val displayName: String,
    val photoUrl: String?,
    val online: Boolean,
)

data class DuoWidgetGroup(
    val groupId: String,
    val name: String,
    val members: List<DuoWidgetMember>,
)

/**
 * Native-side cache of the data the home-screen widget needs to render
 * without waking Flutter: last-active group, the group roster, and which
 * group each individual widget instance is currently showing (a user can
 * cycle a specific widget to a different group via the next-group control).
 */
object DuoWidgetSnapshotStore {
    private const val prefsName = "one_one_duo_widget"
    private const val keyApiBaseUrl = "api_base_url"
    private const val keyUserId = "user_id"
    private const val keyAccentKey = "accent_key"
    private const val keyLastActiveGroupId = "last_active_group_id"
    private const val keyGroupsJson = "groups_json"
    private const val keySelectedIndexByWidget = "selected_index_by_widget"

    private const val defaultApiBaseUrl = "https://one-one-xw00.onrender.com"

    private val accentMap: Map<String, Int> = mapOf(
        "coral" to Color.parseColor("#FF5A5F"),
        "lime" to Color.parseColor("#9BDC28"),
        "sky" to Color.parseColor("#25A9FF"),
        "violet" to Color.parseColor("#8B5CF6"),
        "amber" to Color.parseColor("#FFB020"),
        "pink" to Color.parseColor("#EC4899"),
        "teal" to Color.parseColor("#00B8A9"),
        "indigo" to Color.parseColor("#6366F1"),
        "orange" to Color.parseColor("#FF7A3D"),
        "mint" to Color.parseColor("#34D399"),
        "yellow" to Color.parseColor("#EAB308"),
        "cyan" to Color.parseColor("#22D3EE"),
    )

    fun accentColorInt(accentKey: String?): Int =
        accentMap[accentKey] ?: accentMap.getValue("coral")

    private fun prefs(context: Context) =
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)

    fun saveSnapshot(
        context: Context,
        userId: String?,
        apiBaseUrl: String?,
        accentKey: String?,
        lastActiveGroupId: String?,
        groups: List<DuoWidgetGroup>,
    ) {
        val groupsArray = JSONArray()
        for (group in groups) {
            val membersArray = JSONArray()
            for (member in group.members) {
                membersArray.put(
                    JSONObject().apply {
                        put("userId", member.userId)
                        put("displayName", member.displayName)
                        if (!member.photoUrl.isNullOrBlank()) put("photoUrl", member.photoUrl)
                        put("online", member.online)
                    },
                )
            }
            groupsArray.put(
                JSONObject().apply {
                    put("groupId", group.groupId)
                    put("name", group.name)
                    put("members", membersArray)
                },
            )
        }
        prefs(context).edit()
            .putString(keyUserId, userId)
            .putString(keyApiBaseUrl, apiBaseUrl?.takeIf { it.isNotBlank() } ?: defaultApiBaseUrl)
            .putString(keyAccentKey, accentKey ?: "coral")
            .putString(keyLastActiveGroupId, lastActiveGroupId)
            .putString(keyGroupsJson, groupsArray.toString())
            .apply()
        DuoWidgetLog.i(
            "S-01",
            "snapshot saved groups=${groups.size} " +
                "lastActive=${lastActiveGroupId?.takeLast(6) ?: "none"} " +
                "userId=${userId?.takeLast(6) ?: "none"} " +
                "accent=${accentKey ?: "coral"} " +
                "names=${groups.joinToString { it.name }}",
        )
    }

    fun apiBaseUrl(context: Context): String =
        prefs(context).getString(keyApiBaseUrl, defaultApiBaseUrl)
            ?.takeIf { it.isNotBlank() } ?: defaultApiBaseUrl

    fun accentKey(context: Context): String =
        prefs(context).getString(keyAccentKey, "coral") ?: "coral"

    fun userId(context: Context): String? = prefs(context).getString(keyUserId, null)

    fun lastActiveGroupId(context: Context): String? =
        prefs(context).getString(keyLastActiveGroupId, null)

    fun readGroups(context: Context): List<DuoWidgetGroup> {
        val raw = prefs(context).getString(keyGroupsJson, null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            val groups = ArrayList<DuoWidgetGroup>(array.length())
            for (i in 0 until array.length()) {
                val groupObject = array.optJSONObject(i) ?: continue
                val membersArray = groupObject.optJSONArray("members") ?: JSONArray()
                val members = ArrayList<DuoWidgetMember>(membersArray.length())
                for (j in 0 until membersArray.length()) {
                    val memberObject = membersArray.optJSONObject(j) ?: continue
                    members.add(
                        DuoWidgetMember(
                            userId = memberObject.optString("userId", ""),
                            displayName = memberObject.optString("displayName", "Friend"),
                            photoUrl = memberObject.optString("photoUrl", "")
                                .takeIf { it.isNotBlank() },
                            online = memberObject.optBoolean("online", false),
                        ),
                    )
                }
                groups.add(
                    DuoWidgetGroup(
                        groupId = groupObject.optString("groupId", ""),
                        name = groupObject.optString("name", "Friends"),
                        members = members,
                    ),
                )
            }
            groups.filter { it.groupId.isNotBlank() }
        } catch (error: Exception) {
            DuoWidgetLog.e("S-02", "readGroups JSON parse failed", error)
            emptyList()
        }
    }

    private fun readSelectedIndexMap(context: Context): JSONObject {
        val raw = prefs(context).getString(keySelectedIndexByWidget, null)
        return if (raw.isNullOrBlank()) JSONObject() else try {
            JSONObject(raw)
        } catch (_: Exception) {
            JSONObject()
        }
    }

    private fun writeSelectedIndexMap(context: Context, map: JSONObject) {
        prefs(context).edit().putString(keySelectedIndexByWidget, map.toString()).apply()
    }

    /** Resolves which group a specific widget instance should currently show. */
    fun groupForWidget(context: Context, appWidgetId: Int): DuoWidgetGroup? {
        val groups = readGroups(context)
        if (groups.isEmpty()) {
            DuoWidgetLog.d("S-10", "groupForWidget id=$appWidgetId — empty roster")
            return null
        }
        val indexMap = readSelectedIndexMap(context)
        val overrideIndex = if (indexMap.has(appWidgetId.toString())) {
            indexMap.optInt(appWidgetId.toString(), -1)
        } else {
            -1
        }
        if (overrideIndex in groups.indices) {
            DuoWidgetLog.d(
                "S-11",
                "groupForWidget id=$appWidgetId overrideIndex=$overrideIndex " +
                    "-> ${groups[overrideIndex].name}",
            )
            return groups[overrideIndex]
        }
        val lastActive = lastActiveGroupId(context)
        val lastActiveIndex = groups.indexOfFirst { it.groupId == lastActive }
        val picked = groups[if (lastActiveIndex >= 0) lastActiveIndex else 0]
        DuoWidgetLog.d(
            "S-12",
            "groupForWidget id=$appWidgetId lastActiveIndex=$lastActiveIndex -> ${picked.name}",
        )
        return picked
    }

    /** Cycles the given widget instance to the next group in the roster. */
    fun cycleNextGroup(context: Context, appWidgetId: Int): DuoWidgetGroup? {
        val groups = readGroups(context)
        if (groups.isEmpty()) return null
        val current = groupForWidget(context, appWidgetId)
        val currentIndex = groups.indexOfFirst { it.groupId == current?.groupId }
        val nextIndex = if (currentIndex < 0) 0 else (currentIndex + 1) % groups.size
        val indexMap = readSelectedIndexMap(context)
        indexMap.put(appWidgetId.toString(), nextIndex)
        writeSelectedIndexMap(context, indexMap)
        DuoWidgetLog.i(
            "S-20",
            "cycleNextGroup id=$appWidgetId ${current?.name} -> ${groups[nextIndex].name}",
        )
        return groups[nextIndex]
    }

    /** Cleans up the per-widget override when a widget instance is removed. */
    fun clearWidget(context: Context, appWidgetId: Int) {
        val indexMap = readSelectedIndexMap(context)
        indexMap.remove(appWidgetId.toString())
        writeSelectedIndexMap(context, indexMap)
    }
}
