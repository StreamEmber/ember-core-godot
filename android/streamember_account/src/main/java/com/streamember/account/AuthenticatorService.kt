package com.streamember.account

import android.accounts.AbstractAccountAuthenticator
import android.accounts.Account
import android.accounts.AccountAuthenticatorResponse
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.IBinder

/** Owner of the com.streamember.account type. Accounts are only added by the games (addAccountExplicitly). */
class AuthenticatorService : Service() {
    private val authenticator by lazy { Authenticator(this) }

    override fun onBind(intent: Intent?): IBinder? = authenticator.iBinder

    private class Authenticator(context: Context) : AbstractAccountAuthenticator(context) {
        // "Add account" in Android settings: sign-in happens inside a game, nothing to show here.
        override fun addAccount(r: AccountAuthenticatorResponse?, type: String?, tokenType: String?,
                                features: Array<out String>?, options: Bundle?): Bundle? = null
        override fun editProperties(r: AccountAuthenticatorResponse?, type: String?): Bundle? = null
        override fun confirmCredentials(r: AccountAuthenticatorResponse?, a: Account?, o: Bundle?): Bundle? = null
        override fun getAuthToken(r: AccountAuthenticatorResponse?, a: Account?, type: String?, o: Bundle?): Bundle? = null
        override fun getAuthTokenLabel(type: String?): String? = null
        override fun updateCredentials(r: AccountAuthenticatorResponse?, a: Account?, type: String?, o: Bundle?): Bundle? = null
        override fun hasFeatures(r: AccountAuthenticatorResponse?, a: Account?, f: Array<out String>?): Bundle =
            Bundle().apply { putBoolean(android.accounts.AccountManager.KEY_BOOLEAN_RESULT, false) }
    }
}
