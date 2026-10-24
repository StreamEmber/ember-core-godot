package com.streamember.account

import android.accounts.Account
import android.accounts.AccountManager
import android.util.Log
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONObject

/**
 * The StreamEmber sign-in shared by the StreamEmber games on this phone (one account, type com.streamember.account).
 *   Engine.get_singleton("StreamEmberAccount").get_account()  -> '{"email","token","customerUuid"}' or "" (none / no access)
 *   .set_account(email, token, customerUuid) -> bool   replaces any other StreamEmber account
 *   .clear_account() -> bool
 * Only apps signed with the same key as the app that owns the account type can read it (Android checks the signature),
 * so a debug build does not see the account of a store build.
 */
class StreamEmberAccount(godot: Godot) : GodotPlugin(godot) {
    private val manager: AccountManager? get() = activity?.let { AccountManager.get(it) }

    override fun getPluginName() = "StreamEmberAccount"

    @UsedByGodot
    fun get_account(): String = guard("") {
        val m = manager ?: return@guard ""
        val account = m.getAccountsByType(TYPE).firstOrNull() ?: return@guard ""
        val token = m.peekAuthToken(account, TOKEN_TYPE) ?: return@guard ""
        JSONObject()
            .put("email", account.name)
            .put("token", token)
            .put("customerUuid", m.getUserData(account, KEY_CUSTOMER) ?: "")
            .toString()
    }

    @UsedByGodot
    fun set_account(email: String, token: String, customerUuid: String): Boolean = guard(false) {
        val m = manager ?: return@guard false
        for (other in m.getAccountsByType(TYPE)) {
            if (other.name != email) m.removeAccountExplicitly(other)
        }
        val account = Account(email, TYPE)
        if (m.getAccountsByType(TYPE).none { it.name == email }) {
            if (!m.addAccountExplicitly(account, null, null)) return@guard false
        }
        m.setAuthToken(account, TOKEN_TYPE, token)
        m.setUserData(account, KEY_CUSTOMER, customerUuid)
        true
    }

    @UsedByGodot
    fun clear_account(): Boolean = guard(false) {
        val m = manager ?: return@guard false
        for (account in m.getAccountsByType(TYPE)) m.removeAccountExplicitly(account)
        true
    }

    /** A foreign-signed owner of the account type throws SecurityException: behave as "no shared account". */
    private inline fun <T> guard(fallback: T, block: () -> T): T = try {
        block()
    } catch (e: SecurityException) {
        Log.w(TAG, "No access to the StreamEmber account: ${e.message}")
        fallback
    } catch (e: Exception) {
        Log.w(TAG, "StreamEmber account error", e)
        fallback
    }

    private companion object {
        const val TYPE = "com.streamember.account"
        const val TOKEN_TYPE = "session"
        const val KEY_CUSTOMER = "customerUuid"
        const val TAG = "StreamEmberAccount"
    }
}
