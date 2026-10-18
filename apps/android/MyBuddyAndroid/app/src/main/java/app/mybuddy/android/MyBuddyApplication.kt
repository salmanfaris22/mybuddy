package app.mybuddy.android

import android.app.Application
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner

/**
 * Holds the app's single [AppViewModel] for the life of the process instead of the activity's, so the paired-Mac
 * link survives the screen being closed: notification mirroring runs from a system-bound listener service, and a
 * moving transfer runs under its foreground service, both possibly without any activity.
 */
class MyBuddyApplication : Application(), ViewModelStoreOwner {
    override val viewModelStore = ViewModelStore()

    val vm: AppViewModel by lazy {
        ViewModelProvider(this, ViewModelProvider.AndroidViewModelFactory.getInstance(this))[AppViewModel::class.java]
    }
}
